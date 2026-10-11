"""Verify externally generated VCAM pattern in the phone's encoded return.

Use this only for the Pattern capture, with the host held in Real camera.
Numeric report contains no captured images. Python stdlib + FFmpeg/FFprobe.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('video',type=Path)
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--ffmpeg',default='ffmpeg')
    parser.add_argument('--ffprobe',default='ffprobe')
    args=parser.parse_args()
    meta=json.loads(subprocess.run([args.ffprobe,'-v','error','-count_frames','-show_entries',
        'stream=width,height,nb_read_frames','-of','json',str(args.video)],capture_output=True,text=True,check=True).stdout)['streams'][0]
    w,h=int(meta['width']),int(meta['height']);count=int(meta['nb_read_frames'])
    assert w%2==0 and h%2==0 and count>=60
    selected=sorted(set(min(count-1,n) for n in (30,180,330,480,630,780)))
    expression='+'.join(f'eq(n\\,{n})' for n in selected)
    raw=subprocess.run([args.ffmpeg,'-v','error','-i',str(args.video),'-vf',f'select={expression}',
        '-fps_mode','passthrough','-frames:v',str(len(selected)),'-pix_fmt','yuv420p','-f','rawvideo','pipe:1'],
        capture_output=True,check=True).stdout
    frame_bytes=w*h*3//2;assert len(raw)==frame_bytes*len(selected)
    observations=[];expected=[32,64,96,128,160,192,224]
    for index,number in enumerate(selected):
        y=memoryview(raw)[index*frame_bytes:index*frame_bytes+w*h]
        # Median over rows avoids the moving bright band; sample bar centers.
        columns=[statistics.median(y[(h*row//10)*w+w*(2*bar+1)//14] for row in range(1,8)) for bar in range(7)]
        cells=[y[(h*29//32)*w+w*(2*cell+1)//34] for cell in range(17)]
        counter=sum((value>128)<<(cell-1) for cell,value in enumerate(cells) if cell>0)
        bars_match=all(abs(a-b)<=10 for a,b in zip(columns,expected))
        # Color management may transform intermediate gray levels. Check the
        # seven flat columns separately from preservation of raw source luma.
        flatness=[]
        for bar in range(7):
            x0=w*bar//7;x1=w*(bar+1)//7
            levels=[statistics.median(y[(h*row//10)*w+x0+(x1-x0)*part//6] for row in range(1,8)) for part in range(1,6)]
            flatness.append(max(levels)-min(levels))
        geometry=all(b-a>=8 for a,b in zip(columns,columns[1:])) and columns[-1]-columns[0]>=100 and max(flatness)<=8
        stamp_levels=all(min(abs(v-16),abs(v-235))<=20 for v in cells)
        observations.append({'decoded_frame':number,'luma_columns':columns,'raw_generator_luma_match':bars_match,
                             'flat_column_spread':flatness,'seven_column_geometry_match':geometry,
                             'binary_cells':cells,'marker_bright':cells[0]>200,
                             'stamp_levels_match':stamp_levels,'source_counter_low16':counter})
    # Decode a narrow strip for EVERY encoded frame. This bounds memory to
    # roughly two MB at720/900frames and verifies the evolving source stamp.
    strip_y=(h*29//32)//2*2
    strip=subprocess.run([args.ffmpeg,'-v','error','-i',str(args.video),'-vf',f'crop={w}:2:0:{strip_y}',
        '-fps_mode','passthrough','-pix_fmt','yuv420p','-f','rawvideo','pipe:1'],capture_output=True,check=True).stdout
    assert len(strip)==w*3*count
    counters=[];invalid=[]
    for frame in range(count):
        cells=[strip[frame*w*3+w*(2*cell+1)//34] for cell in range(17)]
        if cells[0]<=200 or not all(min(abs(v-16),abs(v-235))<=20 for v in cells):invalid.append(frame)
        counters.append(sum((v>128)<<(cell-1) for cell,v in enumerate(cells) if cell>0))
    delta=[(b-a)&65535 for a,b in zip(counters,counters[1:])]
    progression=not invalid and max(delta)<=5 and 0.9*(count-1)<=sum(delta)<=1.1*(count-1) and len(set(counters))>=0.9*count
    passed=all(x['seven_column_geometry_match'] and x['marker_bright'] and x['stamp_levels_match'] for x in observations) and progression
    result={'pattern_content_verified':passed,'file_sha256':hashlib.sha256(args.video.read_bytes()).hexdigest(),
            'width':w,'height':h,'decoded_frames':count,'observations':observations,
            'raw_generator_luma_preserved':all(x['raw_generator_luma_match'] for x in observations),
            'source_luma_levels':expected,
            'all_frame_counter_check':{'passed':progression,'frames_checked':count,'invalid_marker_frames':invalid,
                'first_counter':counters[0],'last_counter':counters[-1],'unique_counter_values':len(set(counters)),
                'counter_delta_min':min(delta),'counter_delta_max':max(delta),'total_counter_progression':sum(delta),
                'duplicate_counter_intervals':delta.count(0),'skipped_source_counter_values':sum(max(0,d-1) for d in delta)},
            'scope':'Content matches own external dylib generator; host Real camera / external load require separate operator evidence',
            'limits':['Raw gray levels may differ: this is reported separately, not counted as color fidelity success',
                      'Counter uniqueness applies to this sample only','Does not measure end-to-end latency','No audio validation']}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,indent=2))
    if not passed:raise SystemExit(2)


if __name__=='__main__':main()
