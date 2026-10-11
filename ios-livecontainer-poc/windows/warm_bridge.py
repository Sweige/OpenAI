"""Persistent own-lab OBS encoder: new TCP clients join at the next live IDR.

The phone has a3s read timeout. Starting FFmpeg after accept can exceed it.
Warm once before accepting; bound each client to8 pending access units.
No recorded-video replay, unlimited backlog, platform credentials, or audio.
"""
import argparse
import contextlib
import queue
import socket
import subprocess
import threading
import time
from bridge import encoder_command,listen
from wire import AnnexBParser,AccessUnits,packet


class Subscriber:
    def __init__(self):
        self.frames=queue.Queue(maxsize=8)
        self.waiting_key=True
        self.failure=None


class WarmEncoder:
    def __init__(self,args):
        self.args=args
        self.lock=threading.Lock()
        self.stop_event=threading.Event()
        self.ready=threading.Event()
        self.subscriber=None
        self.process=None
        self.starts=0
        self.thread=threading.Thread(target=self.run,name='lab-warm-encoder',daemon=True)

    def subscribe(self):
        subscriber=Subscriber()
        with self.lock:self.subscriber=subscriber
        return subscriber

    def unsubscribe(self,subscriber):
        with self.lock:
            if self.subscriber is subscriber:self.subscriber=None

    def fail(self,reason):
        with self.lock:
            if self.subscriber:self.subscriber.failure=reason
            self.subscriber=None

    def run(self):
        while not self.stop_event.is_set():
            self.ready.clear()
            start=time.monotonic()
            with self.lock:
                if self.stop_event.is_set():return
                self.process=subprocess.Popen(encoder_command(self.args),stdout=subprocess.PIPE)
                process=self.process;self.starts+=1
            print(f'Warm encoder process started #{self.starts}',flush=True)
            sequence=0;deadline=time.monotonic()
            def emit(items):
                nonlocal sequence,deadline
                for payload,key in items:
                    now=time.monotonic()
                    if deadline>now:
                        if self.stop_event.wait(deadline-now):return
                    else:deadline=now
                    deadline+=1/self.args.fps
                    if not self.ready.is_set():
                        print(f'Warm encoder ready after {time.monotonic()-start:.3f}s; new clients start at next IDR',flush=True)
                        self.ready.set()
                    with self.lock:
                        subscriber=self.subscriber
                        if subscriber:
                            if subscriber.waiting_key and not key:
                                sequence+=1;continue
                            subscriber.waiting_key=False
                            try:subscriber.frames.put_nowait((sequence,payload,key))
                            except queue.Full:
                                subscriber.failure='client backlog exceeded8 access units'
                                self.subscriber=None
                    sequence+=1
            try:
                nals,aus=AnnexBParser(),AccessUnits()
                while not self.stop_event.is_set():
                    data=process.stdout.read1(65536)
                    if not data:break
                    for nal in nals.feed(data):emit(aus.push(nal))
                # Restart rather than replay buffered content after a source EOF.
            except (OSError,ValueError) as error:
                print('Warm encoder error:',type(error).__name__,str(error),flush=True)
            finally:
                self.ready.clear();self.fail('source encoder ended')
                process.terminate()
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:process.kill();process.wait()
                process.stdout.close()
                with self.lock:
                    if self.process is process:self.process=None
            if not self.stop_event.wait(1):print('Restarting warm source encoder',flush=True)

    def close(self):
        self.stop_event.set()
        with self.lock:
            if self.process:
                with contextlib.suppress(OSError):self.process.terminate()
        self.thread.join(timeout=5)


def serve(args):
    encoder=WarmEncoder(args)
    try:
        with listen(args) as server:
            encoder.thread.start()
            sessions=0
            while True:
                # A client is not accepted for video until FFmpeg is producing.
                # Caller should wait for the ready log before connecting a phone.
                while not encoder.ready.wait(.2):
                    if not encoder.thread.is_alive():raise RuntimeError('encoder thread ended')
                connection,address=server.accept()
                print('Phone connected to warm source',address,flush=True)
                subscriber=encoder.subscribe();sent=0;first_sequence=None;connected=time.monotonic()
                try:
                    with connection:
                        connection.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
                        connection.settimeout(1)
                        while True:
                            if subscriber.failure:raise OSError(subscriber.failure)
                            try:source_sequence,payload,key=subscriber.frames.get(timeout=.2)
                            except queue.Empty:continue
                            if first_sequence is None:
                                if not key:raise ValueError('new client must begin at IDR')
                                first_sequence=source_sequence
                            pts=round((source_sequence-first_sequence)*1_000_000/args.fps)
                            connection.sendall(packet(payload,sent,pts,key));sent+=1
                            if sent==1:print(f'First IDR sent {time.monotonic()-connected:.3f}s after accept',flush=True)
                            if sent%args.fps==0:print(f'sent {sent} pictures (warm source, encoder starts={encoder.starts})',flush=True)
                            if args.frames and sent>=args.frames:break
                except (OSError,ValueError) as error:
                    print('Warm client ended:',type(error).__name__,str(error),flush=True)
                finally:encoder.unsubscribe(subscriber)
                sessions+=1
                if args.once or (args.sessions and sessions>=args.sessions):return
    finally:encoder.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',default='rtmp://127.0.0.1:1936/live/obs')
    parser.add_argument('--test-pattern',action='store_true')
    parser.add_argument('--realtime',action='store_true')
    parser.add_argument('--bind',default='127.0.0.1')
    parser.add_argument('--port',type=int,default=9002)
    parser.add_argument('--width',type=int,default=1080)
    parser.add_argument('--height',type=int,default=1920)
    parser.add_argument('--fps',type=int,default=30)
    parser.add_argument('--bitrate',default='6M')
    parser.add_argument('--ffmpeg',default='ffmpeg')
    parser.add_argument('--frames',type=int,default=0)
    parser.add_argument('--once',action='store_true')
    parser.add_argument('--sessions',type=int,default=0,help='Exit after this many clients; 0 keeps serving')
    args=parser.parse_args()
    if args.width<=0 or args.height<=0 or args.width%2 or args.height%2 or args.fps<=0:parser.error('positive even dimensions / positive fps required')
    try:serve(args)
    except KeyboardInterrupt:pass


if __name__=='__main__':main()
