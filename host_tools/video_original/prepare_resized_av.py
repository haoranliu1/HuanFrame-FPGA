"""Prepare a matched lower-bandwidth 8fps RVA, without touching TF or hardware."""
import argparse
import hashlib
import json
import struct
import subprocess
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            result.update(block)
    return result.hexdigest().upper()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--width', type=int, default=416)
    parser.add_argument('--height', type=int, default=312)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    width, height = args.width, args.height
    if width <= 0 or height <= 0 or width > 512 or height > 384 or (width * height) % 256:
        raise ValueError('Geometry must fit the reader and have whole picture sectors')
    source = root / 'tf_backup_before_audio/CLAUDE_CHINESE_512X384_8FPS_HQ.RVF'
    wav = root / 'media/CLAUDE_512X384_8FPS_PCM24K.24k.wav'
    ffmpeg = Path('D:/BBdown/ffmpeg-8.1-full_build/ffmpeg-8.1-full_build/bin/ffmpeg.exe')
    # Pin the exact frozen image source; preserve its already-correct row order.
    if sha256(source) != '9ADB5CB5233EB95C93AFCEDDF5193E8A3821F669B0669298CD4E845C770FFC59':
        raise ValueError('Frozen RVF source hash mismatch')
    with source.open('rb') as stream:
        header = bytearray(stream.read(512))
    if header[:4] != b'RVF1' or struct.unpack_from('<HH', header, 4) != (512, 384):
        raise ValueError('Unexpected RVF source geometry')
    frames = struct.unpack_from('<I', header, 12)[0]
    if source.stat().st_size != 512 + frames * 512 * 384 * 2:
        raise ValueError('Source frame count/length mismatch')
    with wave.open(str(wav), 'rb') as audio:
        if (audio.getframerate(), audio.getsampwidth(), audio.getnchannels(), audio.getnframes()) != (24000, 2, 1, frames * 3000):
            raise ValueError('Source audio geometry mismatch')
    args.output_dir.mkdir(parents=True, exist_ok=False)
    raw = args.output_dir / f'frames_{width}x{height}_8fps.rgb565'
    output = args.output_dir / f'CLAUDE_{width}X{height}_8FPS_PCM24K.RVA'
    # Input frame order and vertical order are unchanged; spatial Lanczos only.
    command = [str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin', '-n',
               '-f', 'rawvideo', '-pixel_format', 'rgb565le', '-video_size', '512x384',
               '-framerate', '8', '-skip_initial_bytes', '512', '-i', str(source),
               '-vf', f'scale={width}:{height}:flags=lanczos+accurate_rnd',
               '-frames:v', str(frames), '-pix_fmt', 'rgb565le', '-f', 'rawvideo', str(raw)]
    subprocess.run(command, check=True, timeout=240)
    video_bytes = width * height * 2
    if raw.stat().st_size != frames * video_bytes:
        raise ValueError('Resized RGB565 frame count/length mismatch')
    picture_sectors = video_bytes // 512
    stride = picture_sectors + 12
    header[:4] = b'RVA1'
    struct.pack_into('<HH', header, 4, width, height)
    struct.pack_into('<H', header, 16, stride)
    struct.pack_into('<I', header, 20, (frames - 1) * stride)
    struct.pack_into('<IHH', header, 24, 24000, 3000, 1)
    header[32:64] = f'RVA1 {width}x{height} PCM24K 8FPS'.encode('ascii').ljust(32, b'\0')
    with raw.open('rb') as images, wave.open(str(wav), 'rb') as audio, output.open('xb') as packed:
        packed.write(header)
        for frame in range(frames):
            rgb = images.read(video_bytes)
            pcm = audio.readframes(3000)
            if len(rgb) != video_bytes or len(pcm) != 6000:
                raise ValueError(f'Short source at frame {frame}')
            packed.write(rgb)
            packed.write(pcm)
            packed.write(bytes(144))
    # Independent full readback: every image byte, PCM sample and padding byte.
    with raw.open('rb') as images, wave.open(str(wav), 'rb') as audio, output.open('rb') as packed:
        if packed.read(512) != header:
            raise ValueError('Packed header mismatch')
        for frame in range(frames):
            if packed.read(video_bytes) != images.read(video_bytes):
                raise ValueError(f'Image payload mismatch at frame {frame}')
            if packed.read(6000) != audio.readframes(3000) or packed.read(144) != bytes(144):
                raise ValueError(f'PCM/padding mismatch at frame {frame}')
        if packed.read(1) or images.read(1):
            raise ValueError('Trailing media bytes')
    report = {
        'profile': f'{width}x{height}_8fps_PCM24K',
        'width': width, 'height': height, 'fps': 8, 'frames': frames,
        'duration_seconds': frames / 8, 'picture_sectors': picture_sectors,
        'pcm_sectors': 12, 'frame_sectors': stride,
        'bytes_per_second_with_padding': stride * 512 * 8,
        'source_rvf': str(source), 'source_rvf_sha256': sha256(source),
        'source_audio': str(wav), 'source_audio_sha256': sha256(wav),
        'pcm_samples_identical': True, 'all_resized_video_payloads_verified': True,
        'spatial_filter': 'Lanczos, existing row order preserved',
        'media': str(output.resolve()), 'bytes': output.stat().st_size,
        'sha256': sha256(output), 'hardware_verified': False, 'tf_modified': False,
    }
    (args.output_dir / 'MEDIA_PREPARED.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
