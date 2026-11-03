"""Create a new 416x312/8fps RVA from MP4; never touch TF or FPGA."""
import argparse
import json
import struct
import subprocess
import wave
from pathlib import Path

from prepare_tf import sha

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT, FPS, RATE, SAMPLES = 416, 312, 8, 24000, 3000
VIDEO_BYTES, STRIDE = WIDTH * HEIGHT * 2, 519


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--ffmpeg', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    ffmpeg = args.ffmpeg.resolve(strict=True)
    probe = subprocess.run([str(ffmpeg.with_name('ffprobe.exe')), '-v', 'error',
        '-show_streams', '-show_format', '-of', 'json', str(source)],
        check=True, capture_output=True, encoding='utf-8')
    info = json.loads(probe.stdout)
    if not any(s['codec_type'] == 'audio' for s in info['streams']):
        raise ValueError('Source has no audio stream')
    template = ROOT / 'media/416x312_8fps_20261024/CLAUDE_416X312_8FPS_PCM24K.RVA'
    if sha(template) != 'AB0DD05A69779C35098ABD9BCA0F9FDC8E872E49E58312BF7525EB0ABC79ACD7':
        raise ValueError('Verified template changed')
    with template.open('rb') as stream:
        header = bytearray(stream.read(512))
    if header[:4] != b'RVA1' or struct.unpack_from('<HHBB', header, 4) != (WIDTH, HEIGHT, 30, 1):
        raise ValueError('Incompatible template geometry/tag')
    args.output_dir.mkdir(parents=True, exist_ok=False)
    raw = args.output_dir / 'frames_416x312_8fps.rgb565'
    wav = args.output_dir / 'SEVE_PCM24K_MONO_S16.wav'
    output = args.output_dir / 'SEVE_416X312_8FPS_PCM24K.RVA'
    # Same complete-picture letterbox and legacy vertical row order as baseline.
    # Explicitly choose video0; this MP4 also contains an attached JPEG cover.
    video_filter = ('fps=fps=8:start_time=0,'
        'scale=416:312:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos+accurate_rnd,'
        'unsharp=5:5:0.25:5:5:0,'
        'pad=416:312:(ow-iw)/2:(oh-ih)/2:black,setsar=1,vflip')
    prefix = [str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin', '-n']
    video_command = prefix + ['-i', str(source), '-map', '0:v:0', '-an', '-sn', '-dn',
        '-vf', video_filter, '-pix_fmt', 'rgb565le', '-f', 'rawvideo', str(raw)]
    subprocess.run(video_command, check=True, timeout=600)
    frames, remainder = divmod(raw.stat().st_size, VIDEO_BYTES)
    if remainder or not 0 < frames <= 0xffffffff or (frames - 1) * STRIDE > 0xffffffff:
        raise ValueError('Invalid decoded frame geometry/count')
    total_samples = frames * SAMPLES
    audio_filter = (f'aresample=24000:async=1:first_pts=0,apad=whole_len={total_samples},'
        f'atrim=end_sample={total_samples},asetpts=N/SR/TB')
    audio_command = prefix + ['-i', str(source), '-map', '0:a:0', '-vn', '-sn', '-dn',
        '-map_metadata', '-1', '-ac', '1', '-ar', '24000', '-af', audio_filter,
        '-c:a', 'pcm_s16le', str(wav)]
    subprocess.run(audio_command, check=True, timeout=600)
    struct.pack_into('<I', header, 12, frames)
    struct.pack_into('<I', header, 20, (frames - 1) * STRIDE)
    header[32:64] = b'SEVE 416x312 8FPS PCM24K MONO'.ljust(32, b'\0')
    with raw.open('rb') as images, wave.open(str(wav), 'rb') as audio, output.open('xb') as packed:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()) != (1, 2, RATE, total_samples):
            raise ValueError('Audio geometry mismatch')
        packed.write(header)
        for frame in range(frames):
            rgb, pcm = images.read(VIDEO_BYTES), audio.readframes(SAMPLES)
            if len(rgb) != VIDEO_BYTES or len(pcm) != SAMPLES * 2:
                raise ValueError(f'Short source at frame {frame}')
            packed.write(rgb)
            packed.write(pcm)
            packed.write(bytes(144))
    # Independent complete pass comparing every frame/sample/padding byte.
    with raw.open('rb') as images, wave.open(str(wav), 'rb') as audio, output.open('rb') as packed:
        if packed.read(512) != header:
            raise ValueError('Header readback mismatch')
        for frame in range(frames):
            if packed.read(VIDEO_BYTES) != images.read(VIDEO_BYTES):
                raise ValueError(f'Video readback mismatch {frame}')
            if packed.read(6000) != audio.readframes(SAMPLES) or packed.read(144) != bytes(144):
                raise ValueError(f'Audio/padding readback mismatch {frame}')
        if packed.read(1) or images.read(1) or audio.readframes(1):
            raise ValueError('Trailing bytes/samples')
    if output.stat().st_size != 512 + frames * STRIDE * 512:
        raise ValueError('Unexpected RVA size')
    report = dict(status='OFFLINE_PASS_NOT_CARD_OR_HARDWARE_VERIFIED',
        media=str(output.resolve()), sha256=sha(output), source=str(source),
        source_sha256=sha(source), source_probe=info,
        width=WIDTH, height=HEIGHT, fps=FPS, frames=frames, duration_seconds=frames/FPS,
        header_fps_tag=30, header_tag_note='Legacy reader compatibility tag, NOT actual playback FPS',
        picture_sectors=507, pcm_sectors=12, frame_sectors=STRIDE,
        bytes_per_second=STRIDE*512*FPS, bytes=output.stat().st_size,
        audio_rate=RATE, samples_per_frame=SAMPLES, audio_channels=1, audio_bits=16,
        hdmi_audio_rate=48000, vertical_preflip=True, aspect='fit with black bars, no cropping',
        video_filter=video_filter, video_command=video_command, audio_command=audio_command,
        raw_sha256=sha(raw), wav_sha256=sha(wav), all_video_pcm_padding_bytes_verified=True,
        tf_modified=False, hardware_modified=False, hardware_verified=False)
    (args.output_dir / 'MEDIA_PREPARED.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'source_probe'}, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
