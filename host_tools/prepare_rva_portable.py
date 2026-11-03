"""Prepare 320x240 RVA with 24 kHz PCM. No disk/card/programmer access.

python prepare_rva_portable.py --source own_clip.mp4 --output-dir NEW_FOLDER --ffmpeg PATH
Uses the published 512-byte format header, no commercial template media.
"""
from pathlib import Path
import argparse,subprocess,struct,wave,json,hashlib

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,required=True);ap.add_argument('--output-dir',type=Path,required=True);ap.add_argument('--ffmpeg',type=Path,required=True)
    a=ap.parse_args();source=a.source.resolve(strict=True);ff=a.ffmpeg.resolve(strict=True)
    a.output_dir.mkdir(parents=True,exist_ok=False)
    raw=a.output_dir/'frames.rgb565';wav=a.output_dir/'pcm.wav';out=a.output_dir/'VIDEO.RVA'
    template=json.loads(Path(__file__).with_name('rva_header_format.json').read_text(encoding='utf-8'))
    header=bytearray.fromhex(template['header_hex']);assert len(header)==512 and header[:4]==b'RVA1'
    filt='fps=24000/1714:start_time=0,scale=320:240:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos+accurate_rnd,unsharp=5:5:0.25:5:5:0,pad=320:240:(ow-iw)/2:(oh-ih)/2:black,setsar=1,vflip'
    base=[str(ff),'-v','error','-nostdin','-n','-i',str(source)]
    subprocess.run(base+['-map','0:v:0','-an','-sn','-dn','-vf',filt,'-pix_fmt','rgb565le','-f','rawvideo',str(raw)],check=True)
    frames,rest=divmod(raw.stat().st_size,153600)
    if rest or not 0<frames<2**32:raise ValueError('invalid frame data')
    samples=frames*1714
    af=f'aresample=24000:async=1:first_pts=0,apad=whole_len={samples},atrim=end_sample={samples},asetpts=N/SR/TB'
    subprocess.run(base+['-map','0:a:0','-vn','-ac','1','-ar','24000','-af',af,'-c:a','pcm_s16le',str(wav)],check=True)
    struct.pack_into('<HH',header,4,320,240);struct.pack_into('<I',header,12,frames)
    struct.pack_into('<H',header,16,312);struct.pack_into('<I',header,20,(frames-1)*312)
    struct.pack_into('<H',header,28,1714);header[32:64]=b'320x240 14FPS PCM24K MONO'.ljust(32,b'\0')
    with raw.open('rb') as v,wave.open(str(wav),'rb') as aud,out.open('xb') as dst:
        if (aud.getnchannels(),aud.getsampwidth(),aud.getframerate(),aud.getnframes())!=(1,2,24000,samples):raise ValueError('invalid PCM')
        dst.write(header)
        for i in range(frames):
            rgb=v.read(153600);pcm=aud.readframes(1714)
            if len(rgb)!=153600 or len(pcm)!=3428:raise ValueError('short media')
            dst.write(rgb);dst.write(pcm);dst.write(bytes(2716))
    if out.stat().st_size!=512+frames*312*512:raise ValueError('RVA size mismatch')
    result={'frames':frames,'fps':'24000/1714','width':320,'height':240,'samples_per_frame':1714,'frame_sectors':312,'bytes':out.stat().st_size,'sha256':hashlib.sha256(out.read_bytes()).hexdigest().upper(),'hardware_verified':False}
    (a.output_dir/'PREPARED.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result))
if __name__=='__main__':main()
