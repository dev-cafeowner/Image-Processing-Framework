"""Record the monitor webcam without FPS resampling; decode PL identity stripes.

This is optical end-to-end observation, NOT a direct HDMI protocol analyzer.
FFmpeg dshow: https://ffmpeg.org/ffmpeg-devices.html#dshow
Requires numpy/Pillow and local imageio-ffmpeg executable (no global install).
"""
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FFMPEG = next((ROOT / 'tools/.deps/hdmi/imageio_ffmpeg/binaries').glob('ffmpeg-*.exe'))
W, H = 640, 480


def record(args):
    out = Path(args.output)
    if out.exists() or out.with_suffix('.capture.json').exists():
        raise RuntimeError('Capture exists; choose another output')
    out.parent.mkdir(parents=True, exist_ok=True)
    command = [str(FFMPEG), '-hide_banner', '-nostdin', '-n', '-f', 'dshow',
               '-rtbufsize', '64M', '-video_size', '640x480', '-framerate', '30',
               '-pixel_format', 'yuyv422', '-i', 'video=' + args.device,
               '-t', str(args.seconds), '-an', '-c:v', 'ffv1', '-level', '3',
               '-fps_mode', 'passthrough', str(out)]
    started = datetime.datetime.now().astimezone().isoformat()
    begin = time.monotonic()
    with out.with_suffix('.capture.log').open('x', encoding='utf-8') as log:
        subprocess.run(command, stdout=subprocess.DEVNULL, stderr=log, check=True,
                       timeout=args.seconds + 45)
    with out.open('rb') as stream:
        digest=hashlib.file_digest(stream, 'sha256').hexdigest()
    meta = dict(started=started, wall_seconds=time.monotonic()-begin, command=command,
                device=args.device, requested_fps=30, frames_resampled=False,
                observation='HDMI monitor photographed by USB webcam',
                sha256=digest)
    out.with_suffix('.capture.json').write_text(json.dumps(meta, indent=2), encoding='utf-8')
    print(json.dumps(meta, indent=2))


def unpack(samples):
    """Batch decode 48 MSB-first bits; reject low contrast or torn bit patterns."""
    samples = np.asarray(samples, dtype=float)
    lo, hi = samples.min(axis=-1), samples.max(axis=-1)
    threshold = (lo + hi) / 2
    bits = samples > threshold[..., None]
    weights = (1 << np.arange(7, -1, -1))
    values = (bits.reshape(*bits.shape[:-1], 6, 8) * weights).sum(axis=-1)
    pre = values[..., 0]
    ident = values[..., 1]*256 + values[..., 2]
    inverse = values[..., 3]*256 + values[..., 4]
    check = values[..., 1] ^ values[..., 2] ^ pre ^ 0x5a
    # At least 20 gray levels away from decision midpoint. Ambiguous exposure
    # mixtures are unreadable, never silently counted as repeats or drops.
    confidence = np.min(np.abs(samples-threshold[..., None]), axis=-1)
    valid = ((pre == 0xd3) | (pre == 0xa6)) & (ident ^ inverse == 65535)
    valid &= (check == values[..., 5]) & (hi-lo > 70) & (confidence > 20)
    return valid, ident, pre, confidence


def sample_line(gray, x, y, step, slope, curvature=0):
    xx = x + (np.arange(48)+0.5)*step
    dx = xx-x
    yy = y + dx*slope + curvature*dx*(dx-48*step)
    xi,yi=np.rint(xx).astype(int),np.rint(yy).astype(int)
    if np.any(xi<0) or np.any(xi>=W) or np.any(yi<0) or np.any(yi>=H):
        return np.full(48,125)  # reject, never extend edge pixels into a tag
    return gray[yi,xi]


def calibrate(gray, curvatures=(0,)):
    # No assumed screen homography: acquire a barcode on a slanted optical line.
    # Prefix prefilter prunes almost all search positions before inverse/check.
    candidates = []
    prefixes = {p: np.array([(p >> i) & 1 for i in range(7,-1,-1)])
                for p in (0xd3, 0xa6)}
    for step in np.arange(6.0, 13.21, 0.10):
        starts = np.arange(0, int(W-48*step))
        if not len(starts):
            continue
        xx = np.rint(starts[:, None] + (np.arange(8)+0.5)*step).astype(int)
        for curvature,slope in ((c,s) for c in curvatures for s in (-0.06,-0.03,0,0.03,0.06)):
            for y in range(30,H-4,4):
                dx=xx-starts[:,None]
                yy = np.rint(y + dx*slope + curvature*dx*(dx-48*step)).astype(int)
                if yy.min()<0 or yy.max()>=H:
                    continue
                values = gray[yy,xx].astype(float)
                lo,hi = values.min(axis=1),values.max(axis=1)
                bits = values > ((lo+hi)/2)[:,None]
                preok = (hi-lo > 70) & (np.all(bits==prefixes[0xd3],axis=1) |
                                                np.all(bits==prefixes[0xa6],axis=1))
                for x in starts[preok]:
                    endy = y + 48*step*slope
                    if not 1 <= endy < H-1:
                        continue
                    samples=sample_line(gray,x,y,step,slope,curvature)
                    valid,ident,pre,confidence=unpack(samples)
                    if valid:
                        candidates.append(dict(x=float(x),y=float(y),step=float(step),
                                               slope=slope,curvature=curvature,pre=int(pre),ident=int(ident),
                                               confidence=float(confidence)))
    if not candidates:
        raise RuntimeError('No readable frame tag; check webcam framing/focus/exposure')
    # Nearby solutions are the same physical band; retain its best centerline.
    groups=[]
    for c in sorted(candidates,key=lambda c:-c['confidence']):
        def mid_y(p):
            return p['y']+24*p['step']*p['slope']-p.get('curvature',0)*(24*p['step'])**2
        cy=mid_y(c)
        if any(g['pre']==c['pre'] and abs(mid_y(g)-cy)<22 for g in groups):
            continue
        groups.append(c)
    cameras=sorted([c for c in groups if c['pre']==0xd3],key=lambda c:c['y'])
    scans=[c for c in groups if c['pre']==0xa6]
    if len(cameras)!=2 or len(scans)!=1:
        raise RuntimeError(f'Need two camera bands and one scan band, found {groups}')
    return dict(camera_top=cameras[0],camera_bottom=cameras[1],scan=scans[0])


def decode_band(gray, c):
    found=[]
    for dy in (0,-2,2,-4,4):
        valid,ident,pre,confidence=unpack(sample_line(gray,c['x'],c['y']+dy,c['step'],c['slope'],c.get('curvature',0)))
        if valid and int(pre)==c['pre']:
            found.append((int(ident),float(confidence)))
    if not found:
        return None
    # Conflicting IDs within one band reflect optical refresh/rolling shutter.
    # Do not choose the most convenient ID or hide the ambiguity.
    identities={i for i,_ in found}
    return found[0][0] if len(identities)==1 else None


def frames(path):
    command=[str(FFMPEG),'-hide_banner','-nostdin','-i',str(path),'-an',
             '-vf','showinfo','-fps_mode','passthrough','-pix_fmt','gray','-f','rawvideo','pipe:1']
    p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    pts=[]; errors=[]
    def readlog():
        for raw in p.stderr:
            line=raw.decode('utf-8',errors='replace')
            m=re.search(r' n:\s*(\d+).*?pts_time:([\d.\-]+)',line)
            if m: pts.append((int(m[1]),float(m[2])))
            if 'Error' in line: errors.append(line.strip())
    t=threading.Thread(target=readlog);t.start()
    index=0
    try:
        while True:
            raw=bytearray()
            while len(raw)<W*H:
                chunk=p.stdout.read(W*H-len(raw))
                if not chunk:break
                raw.extend(chunk)
            if not raw:break
            if len(raw)!=W*H:raise RuntimeError('Truncated decoded frame')
            yield index,np.frombuffer(raw,dtype=np.uint8).reshape(H,W),pts
            index+=1
    finally:
        p.stdout.close();p.wait(timeout=30);t.join(timeout=5)
    if p.returncode or errors or len(pts)!=index:
        raise RuntimeError(f'PTS/decode mismatch {len(pts)} vs {index}; {errors}')


def analyze(args):
    source=Path(args.input); output=Path(args.output)
    if output.exists():raise RuntimeError('Analysis output exists')
    calibration=json.loads(Path(args.calibration).read_text()) if args.calibration else None
    rows=[];timestamps=None
    for index,gray,pts in frames(source):
        if calibration is None:
            Image.fromarray(gray).save(output.with_suffix('.first.png'))
            curves=(-0.0003,-0.0002,-0.0001,0,0.0001,0.0002,0.0003) if args.curved else (0,)
            calibration=calibrate(gray,curves)
            output.with_suffix('.calibration.json').write_text(json.dumps(calibration,indent=2))
            print('Calibration:',calibration,flush=True)
        rows.append(dict(index=index,**{k:decode_band(gray,c) for k,c in calibration.items()}))
        timestamps=pts
    if len(rows)<2:raise RuntimeError('Not enough frames')
    for row,(index,pts) in zip(rows,timestamps):
        if row['index']!=index:raise RuntimeError('Noncontiguous decoder indexes')
        row['pts']=pts
    dt=np.diff([r['pts'] for r in rows])
    if np.any(dt<=0):raise RuntimeError('Nonmonotonic capture PTS')
    result=dict(source=str(source),frames=len(rows),seconds=rows[-1]['pts']-rows[0]['pts'],
                observed_webcam_fps=(len(rows)-1)/(rows[-1]['pts']-rows[0]['pts']),
                capture_gap_ms_percentiles=dict(zip(('p50','p95','p99','max'),
                    np.percentile(dt*1000,[50,95,99,100]).tolist())),calibration=calibration)
    for key in calibration:
        valid=[r for r in rows if r[key] is not None]
        pairs=[(a,b) for a,b in zip(rows,rows[1:]) if a[key] is not None and b[key] is not None]
        delta=[(b[key]-a[key])%65536 for a,b in pairs]
        hist={str(d):delta.count(d) for d in sorted(set(delta))}
        result[key]=dict(readable=len(valid),unreadable=len(rows)-len(valid),
                         adjacent_valid_pairs=len(pairs),id_step_histogram=hist)
    both=[r for r in rows if r['camera_top'] is not None and r['camera_bottom'] is not None]
    result['camera_band_mismatches']=sum(r['camera_top']!=r['camera_bottom'] for r in both)
    result['camera_band_pairs']=len(both)
    result['note']=('Optical monitor/webcam observation at <=30fps, not direct HDMI. '
        'Missing/unreadable samples are excluded, never interpolated. A camera ID jump '
        'does not prove FPGA drop; an optical band mismatch does not alone prove VDMA tearing. '
        'Monitor refresh, exposure and rolling shutter can mix adjacent scanouts.')
    result['rows']=rows
    output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();subs=p.add_subparsers(dest='mode',required=True)
    c=subs.add_parser('record');c.add_argument('--output',required=True)
    c.add_argument('--seconds',type=int,default=60);c.add_argument('--device',default='USB 2.0 Camera')
    a=subs.add_parser('analyze');a.add_argument('--input',required=True)
    a.add_argument('--output',required=True);a.add_argument('--calibration')
    a.add_argument('--curved',action='store_true',help='Optical curved-band calibration; unchanged checksum/contrast rejection')
    args=p.parse_args();record(args) if args.mode=='record' else analyze(args)
