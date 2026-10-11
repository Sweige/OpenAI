"""Two-client integration check for the own-app warm sender. Captures stay local."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
from wire import AnnexBParser, PacketParser


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',default='rtmp://127.0.0.1:1936/live/obs')
    parser.add_argument('--test-pattern',action='store_true')
    parser.add_argument('--frames',type=int,default=60)
    parser.add_argument('--ffmpeg',default='ffmpeg')
    parser.add_argument('--ffprobe',default='ffprobe')
    parser.add_argument('--output-dir',required=True,help='Local private captures and logs')
    parser.add_argument('--report',required=True,help='Numeric evidence only')
    args=parser.parse_args()
    output=Path(args.output_dir).resolve(); output.mkdir(parents=True,exist_ok=True)
    with socket.socket() as reserved:
        reserved.bind(('127.0.0.1',0)); port=reserved.getsockname()[1]
    command=[sys.executable,'-u',str(Path(__file__).with_name('warm_bridge.py')),
             '--bind','127.0.0.1','--port',str(port),'--input',args.input,
             '--ffmpeg',args.ffmpeg,'--width','1080','--height','1920',
             '--frames',str(args.frames),'--sessions','2']
    if args.test_pattern:command.append('--test-pattern')
    ready=threading.Event(); lines=[]
    process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    def read_log():
        with (output/'sender.log').open('w',encoding='utf-8') as log:
            for line in process.stdout:
                lines.append(line.rstrip()); log.write(line); log.flush()
                if 'Warm encoder ready after ' in line:ready.set()
    reader=threading.Thread(target=read_log,daemon=True);reader.start()
    results=[]
    try:
        assert ready.wait(45),'Sender did not become ready within45s; inspect sender.log'
        for index in range(2):
            begin=time.monotonic(); packets=[]; wire=PacketParser()
            with socket.create_connection(('127.0.0.1',port),timeout=3) as connection:
                connection.settimeout(3)
                first=None
                while data:=connection.recv(65536):
                    new=wire.feed(data)
                    if new and first is None:first=time.monotonic()-begin
                    packets.extend(new)
            assert len(packets)==args.frames,f'Client{index}: expected{args.frames} packets, got{len(packets)}'
            assert not wire.buffer,'Truncated packet'
            assert packets[0][0]==0 and packets[0][1]==0 and packets[0][2]&1
            assert [p[0] for p in packets]==list(range(args.frames))
            assert all(b[1]>a[1] for a,b in zip(packets,packets[1:]))
            nals=AnnexBParser().feed(packets[0][3],final=True)
            types=[n[0]&31 for n in nals]
            assert all(t in types for t in (7,8,5)),f'First IDR missing SPS/PPS: {types}'
            assert first<3,f'First complete AU took{first:.3f}s'
            video=output/f'client-{index+1}.h264'
            video.write_bytes(b''.join(p[3] for p in packets))
            probe=subprocess.run([args.ffprobe,'-v','error','-count_frames','-show_entries',
                'stream=codec_name,width,height,nb_read_frames,has_b_frames','-of','json',str(video)],
                capture_output=True,text=True,check=True)
            streams=json.loads(probe.stdout)['streams']
            assert len(streams)==1 and streams[0]['width']==1080 and streams[0]['height']==1920
            assert int(streams[0]['nb_read_frames'])==args.frames
            decode=subprocess.run([args.ffmpeg,'-v','error','-f','h264','-i',str(video),'-f','null','-'],
                                  capture_output=True,text=True)
            assert decode.returncode==0 and not decode.stderr.strip(),decode.stderr
            results.append({'client':index+1,'packets':args.frames,'first_complete_AU_seconds':first,
                'first_NAL_types':types,'starts_with_SPS_PPS_IDR':True,
                'sequence_consecutive':True,'pts_monotonic':True,'probe':streams,
                'full_decode_exit_code':decode.returncode,'full_decode_errors':decode.stderr.strip()})
        process.wait(timeout=10);reader.join(timeout=2)
        assert process.returncode==0,f'Sender exit{process.returncode}'
        starts=sum('Warm encoder process started #' in line for line in lines)
        assert starts==1,f'Encoder restarted{starts}times'
        report={'passed':True,'date':'2026-10-11','source':'synthetic testsrc2' if args.test_pattern else 'local authorized OBS RTMP stream',
            'test':'two sequential TCP clients join live1080 source after warm-ready; no encoder restart',
            'encoder_process_starts':starts,'clients':results,
            'limits':['PC loopback only; phone compatibility needs separate test',
                      'first-AU wait is not end-to-end video latency','raw captures and images excluded from report']}
        target=Path(args.report);target.parent.mkdir(parents=True,exist_ok=True)
        target.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print(json.dumps(report,ensure_ascii=False,indent=2))
    finally:
        if process.poll() is None:
            # Terminate only this integration check's own sender and its encoder.
            if os.name=='nt':subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],capture_output=True)
            else:process.terminate()
            process.wait(timeout=5)
        process.stdout.close()


if __name__=='__main__':main()
