"""Real TCP + FFmpeg smoke test. Does NOT test Swift/iPhone/VideoToolbox."""
import argparse, json, pathlib, socket, subprocess, sys, time
from wire import PacketParser, packet

ROOT=pathlib.Path(__file__).resolve().parent

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]

def connect(port,proc):
    for _ in range(100):
        try: return socket.create_connection(('127.0.0.1',port),timeout=10)
        except ConnectionRefusedError:
            if proc.poll() is not None: raise RuntimeError('bridge exited before accept')
            time.sleep(.05)
    raise RuntimeError('bridge did not listen')

def check(output,width,height):
    port=free_port(); raw=output/f'{width}x{height}.h264'
    log=output/f'{width}x{height}.log'
    packets=[]
    with log.open('w') as logs:
        proc=subprocess.Popen([sys.executable,str(ROOT/'bridge.py'),'send','--test-pattern','--once','--frames','60',
            '--port',str(port),'--width',str(width),'--height',str(height)],stdout=logs,stderr=logs)
        try:
            with connect(port,proc) as s,raw.open('wb') as f:
                parser=PacketParser()
                while chunk:=s.recv(65536):
                    for p in parser.feed(chunk): packets.append(p); f.write(p[3])
                if parser.buffer: raise RuntimeError('truncated packet')
            proc.wait(timeout=10)
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()
    assert len(packets)==60,len(packets)
    assert all(p[0]==i and p[1]==round(i*1_000_000/30) for i,p in enumerate(packets))
    subprocess.run(['ffmpeg','-v','error','-i',str(raw),'-f','null','-'],check=True)
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-select_streams','v:0',
        '-show_entries','stream=width,height,nb_read_frames,has_b_frames','-of','json',str(raw)]))['streams'][0]
    assert (probe['width'],probe['height'],int(probe['nb_read_frames']),probe['has_b_frames'])==(width,height,60,0),probe
    # Exercise the delivered return receiver with the actual encoded payloads.
    port=free_port(); returned=output/f'{width}x{height}-return.h264'
    with (output/f'{width}x{height}-return.log').open('w') as logs:
        proc=subprocess.Popen([sys.executable,str(ROOT/'bridge.py'),'receive','--port',str(port),'--frames','60','--output',str(returned)],stdout=logs,stderr=logs)
        try:
            # Reproduce a phone encoder restart before its first encoded frame.
            with connect(port,proc):
                pass
            with connect(port,proc) as s:
                for seq,pts,flags,payload in packets: s.sendall(packet(payload,seq,pts,bool(flags&1)))
            proc.wait(timeout=10)
            assert proc.returncode==0
        finally:
            if proc.poll() is None: proc.kill(); proc.wait()
    assert raw.read_bytes()==returned.read_bytes()
    return {'width':width,'height':height,'pictures':60,'B_frames':0,'first_key':bool(packets[0][2]&1),
        'tcp_sender':'pass','ffmpeg_decode':'pass','tcp_return_receiver':'pass',
        'empty_uplink_reconnect':'pass','iOS_build':'not_run','iPhone':'not_run'}

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--output',default='validation'); a=p.parse_args()
    out=pathlib.Path(a.output).resolve(); out.mkdir(parents=True,exist_ok=True)
    result={'time_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'scope':'Windows loopback, no iPhone',
        'ffmpeg':subprocess.check_output(['ffmpeg','-version'],text=True).splitlines()[0],
        'runs':[check(out,720,1280),check(out,1080,1920)]}
    (out/'results.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result,indent=2))
