import sys,pathlib,socket,subprocess,time,json
root=pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root/'windows'))
from wire import AnnexBParser,AccessUnits,packet
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));return s.getsockname()[1]
rp,wp=port(),port();url=f'rtmp://127.0.0.1:{rp}/live/return'
dest=root/'validation/relay.flv'
server=subprocess.Popen(['ffmpeg','-y','-v','warning','-listen','1','-timeout','15','-i',url,'-map','0:v:0','-c','copy',str(dest)],stderr=(root/'validation/relay-server.log').open('w'))
time.sleep(.4)
bridge=subprocess.Popen([sys.executable,str(root/'windows/bridge.py'),'receive','--port',str(wp),'--frames','60','--output',str(root/'validation/relay-input.h264'),'--rtmp',url],stdout=(root/'validation/relay-bridge.log').open('w'),stderr=subprocess.STDOUT)
try:
    for attempt in range(60):
        try:s=socket.create_connection(('127.0.0.1',wp),timeout=5);break
        except ConnectionRefusedError:time.sleep(.1)
    else:raise RuntimeError('receiver did not start')
    n=AnnexBParser();a=AccessUnits();items=[]
    for nal in n.feed((root/'validation/720x1280.h264').read_bytes(),final=True):items.extend(a.push(nal))
    items.extend(a.flush())
    with s:
        for i,(payload,key) in enumerate(items):s.sendall(packet(payload,i,round(i*1e6/30),key))
    bridge.wait(timeout=15);server.wait(timeout=15)
    assert bridge.returncode==0 and server.returncode==0,(bridge.returncode,server.returncode)
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-select_streams','v:0','-show_entries','stream=width,height,nb_read_frames','-of','json',str(dest)]))
    assert int(probe['streams'][0]['nb_read_frames'])==60,probe
    (root/'validation/relay-results.json').write_text(json.dumps({'scope':'Windows TCP return -> FFmpeg RTMP -> FFmpeg listener; no iPhone','result':'pass',**probe},indent=2))
    print(probe)
finally:
    for p in (bridge,server):
        if p.poll() is None:p.kill();p.wait()
