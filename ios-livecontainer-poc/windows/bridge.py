"""Own-app video experiment. Python stdlib + external FFmpeg. No platform credentials."""
import argparse
import contextlib
import csv
import pathlib
import socket
import subprocess
import time
from wire import AnnexBParser, AccessUnits, PacketParser, packet

def encoder_command(a):
    cmd = [a.ffmpeg, '-hide_banner', '-loglevel', 'warning']
    if a.test_pattern:
        cmd += ['-re', '-f', 'lavfi', '-i', f'testsrc2=size={a.width}x{a.height}:rate={a.fps}']
    else:
        # RTMP input: OBS has already paced it. File input can use --realtime.
        if a.realtime:
            cmd += ['-re']
        cmd += ['-fflags', 'nobuffer', '-analyzeduration', '100000', '-probesize', '1000000', '-i', a.input]
    cmd += ['-map', '0:v:0', '-an', '-vf',
            f'scale={a.width}:{a.height}:force_original_aspect_ratio=decrease,pad={a.width}:{a.height}:(ow-iw)/2:(oh-ih)/2,setsar=1',
            '-r', str(a.fps), '-pix_fmt', 'yuv420p', '-c:v', 'libx264',
            '-preset', 'ultrafast', '-tune', 'zerolatency', '-profile:v', 'baseline',
            '-b:v', a.bitrate, '-maxrate', a.bitrate, '-bufsize', a.bitrate,
            '-g', str(a.fps), '-keyint_min', str(a.fps), '-bf', '0',
            '-x264-params', 'aud=1:repeat-headers=1:scenecut=0', '-flush_packets', '1', '-f', 'h264', 'pipe:1']
    return cmd

def listen(a):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((a.bind, a.port)); s.listen(1)
    print(f'Listening {a.bind}:{a.port}; Ctrl+C stops', flush=True)
    return s

def send(a):
    """One phone at a time; restart FFmpeg for each reconnect to start with an IDR."""
    with listen(a) as server:
        while True:
            conn, addr = server.accept()
            print('Phone connected', addr, flush=True)
            cmd = encoder_command(a)
            print('FFmpeg:', subprocess.list2cmdline(cmd), flush=True)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
            try:
                with conn:
                    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    conn.settimeout(1.0)
                    nals, aus, seq = AnnexBParser(), AccessUnits(), 0
                    deadline = time.monotonic()
                    def emit(items):
                        nonlocal seq, deadline
                        for payload, key in items:
                            # Do not send a backlog in a burst after a stalled input.
                            now = time.monotonic()
                            if deadline > now:
                                time.sleep(deadline-now)
                            else:
                                deadline = now
                            conn.sendall(packet(payload, seq, round(seq*1_000_000/a.fps), key))
                            seq += 1; deadline += 1/a.fps
                            if seq % a.fps == 0:
                                print(f'sent {seq} pictures', flush=True)
                            if a.frames and seq >= a.frames:
                                raise StopIteration
                    while chunk := proc.stdout.read1(65536):
                        for nal in nals.feed(chunk):
                            emit(aus.push(nal))
                    for nal in nals.feed(b'', final=True):
                        emit(aus.push(nal))
                    emit(aus.flush())
                    if proc.poll() not in (None, 0):
                        print('FFmpeg exited', proc.returncode, flush=True)
            except (OSError, StopIteration) as e:
                print('Session ended:', type(e).__name__, str(e), flush=True)
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait()
                proc.stdout.close()
            if a.once:
                return

def receive(a):
    path = pathlib.Path(a.output); path.parent.mkdir(parents=True, exist_ok=True)
    with listen(a) as server:
        while True:
            conn, addr = server.accept()
            print('Uplink connected', addr, flush=True)
            count = receive_connection(a, path, conn)
            if count:
                print('Completed', count, flush=True)
                return
            # Starting/restarting the phone encoder cancels its old connection.
            # An empty connection must not consume the single capture attempt.
            print('Empty uplink closed; still listening for a new connection', flush=True)


def receive_connection(a, path, conn):
    with conn:
        parser = PacketParser(); count = 0; last_pts = None
        # Optional own-server RTMP relay. The lab transport is video-only: assign
        # constant-rate timestamps here; production must mux the original A/V clock.
        relay = None
        if a.rtmp:
            relay = subprocess.Popen([a.ffmpeg, '-hide_banner', '-loglevel', 'warning',
                '-fflags', '+genpts', '-probesize', '100000', '-analyzeduration', '100000',
                '-r', str(a.fps), '-f', 'h264', '-i', 'pipe:0', '-map', '0:v:0',
                '-c:v', 'copy', '-an', '-flush_packets', '1', '-f', 'flv', a.rtmp], stdin=subprocess.PIPE)
        with contextlib.ExitStack() as stack:
            if relay:
                def finish_relay():
                    with contextlib.suppress(BrokenPipeError):
                        relay.stdin.close()
                    try:
                        relay.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        relay.terminate(); relay.wait(timeout=3)
                stack.callback(finish_relay)
            output = stack.enter_context(path.open('wb'))
            log = stack.enter_context(path.with_suffix('.csv').open('w', newline=''))
            writer = csv.writer(log)
            writer.writerow(['seq', 'pts_us', 'flags', 'bytes', 'arrival_monotonic_ns'])
            while data := conn.recv(65536):
                for seq, pts, flags, payload in parser.feed(data):
                    if last_pts is not None and pts <= last_pts:
                        raise ValueError('non-monotonic uplink PTS')
                    last_pts = pts
                    output.write(payload)
                    if relay:
                        relay.stdin.write(payload); relay.stdin.flush()
                    writer.writerow([seq, pts, flags, len(payload), time.monotonic_ns()])
                    output.flush(); log.flush(); count += 1
                    if count % 30 == 0:
                        print(f'received {count} encoded pictures', flush=True)
                    if a.frames and count >= a.frames:
                        return count
            if parser.buffer:
                raise ValueError('truncated final wire packet')
        return count

def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='mode', required=True)
    s = sub.add_parser('send')
    s.add_argument('--input', default='rtmp://127.0.0.1:1936/live/obs')
    s.add_argument('--test-pattern', action='store_true')
    s.add_argument('--realtime', action='store_true', help='Pace file input; omit for RTMP')
    s.add_argument('--width', type=int, default=720); s.add_argument('--height', type=int, default=1280)
    s.add_argument('--fps', type=int, default=30); s.add_argument('--bitrate', default='4M')
    s.add_argument('--ffmpeg', default='ffmpeg'); s.add_argument('--once', action='store_true')
    s.set_defaults(port=9000)
    r = sub.add_parser('receive'); r.add_argument('--output', default='capture/return.h264'); r.set_defaults(port=9001)
    r.add_argument('--rtmp', help='Optional video-only relay to an authorized RTMP server')
    r.add_argument('--ffmpeg', default='ffmpeg'); r.add_argument('--fps', type=int, default=30)
    for parser in (s,r):
        parser.add_argument('--bind', default='127.0.0.1', help='Set PC LAN IP explicitly for phone access')
        parser.add_argument('--port', type=int)
        parser.add_argument('--frames', type=int, default=0)
    a = p.parse_args()
    if a.mode == 'send' and (a.fps <= 0 or a.width <= 0 or a.height <= 0 or a.width%2 or a.height%2):
        p.error('positive fps and positive even width/height required')
    try:
        (send if a.mode == 'send' else receive)(a)
    except KeyboardInterrupt:
        pass

if __name__ == '__main__':
    main()
