"""Prepare a self-contained PCM library; never opens or writes removable media."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import zlib

RATE = 48000
MAX_TRACKS = 16
HEADER = 512
FFMPEG = Path('D:/BBdown/ffmpeg-8.1-full_build/ffmpeg-8.1-full_build/bin/ffmpeg.exe')


def locate_ffmpeg():
    if FFMPEG.is_file():
        return FFMPEG
    located = shutil.which('ffmpeg')
    if located:
        return Path(located)
    raise FileNotFoundError('未找到FFmpeg，请在窗口中选择ffmpeg.exe')


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest().upper()


def read_library(path):
    """Validate the exact hardware header and independently check every PCM CRC."""
    path = Path(path)
    with path.open('rb') as stream:
        header = stream.read(HEADER)
        if len(header) != HEADER or header[:4] != b'BGM1':
            raise ValueError('BGM1 header missing')
        version, count, channels, bits = struct.unpack_from('<BBBB', header, 4)
        rate, header_bytes, library_bytes = struct.unpack_from('<III', header, 8)
        expected_sum = struct.unpack_from('<H', header, 28)[0]
        if (version, channels, bits, rate, header_bytes) != (1, 1, 16, RATE, HEADER):
            raise ValueError('Unsupported PCM geometry')
        if not 1 <= count <= MAX_TRACKS or library_bytes != path.stat().st_size:
            raise ValueError('Invalid count or library length')
        if sum(header[:28] + header[30:]) % 65536 != expected_sum:
            raise ValueError('Header checksum mismatch')
        tracks = []
        previous_end = HEADER
        for index in range(count):
            sector, samples, expected_crc, reserved = struct.unpack_from('<IIII', header, 32 + 16 * index)
            start = sector * 512
            size = samples * 2
            if samples < 1024 or start < previous_end or start + size > library_bytes or reserved:
                raise ValueError('Invalid/overlapping track bounds')
            stream.seek(start)
            crc = 0
            remaining = size
            while remaining:
                block = stream.read(min(remaining, 1024 * 1024))
                if not block:
                    raise ValueError('PCM truncated')
                crc = zlib.crc32(block, crc)
                remaining -= len(block)
            if crc != expected_crc:
                raise ValueError('PCM CRC mismatch')
            tracks.append({'index': index, 'sector': sector, 'samples': samples, 'crc32': crc})
            previous_end = (start + size + 511) // 512 * 512
    return tracks


def prepare(entries, output, ffmpeg=None, progress=print):
    if not 1 <= len(entries) <= MAX_TRACKS:
        raise ValueError('首版曲库支持1～16首，数量不可超限')
    sources = [Path(entry['source']).resolve(strict=True) for entry in entries]
    ffmpeg = Path(ffmpeg or locate_ffmpeg()).resolve(strict=True)
    output = Path(output).resolve()
    # Never target a card or overwrite an earlier preparation.
    if output.drive and output.drive.upper() not in {'C:', 'D:'}:
        raise ValueError('请先输出到电脑C/D盘目录，TF卡由独立备份校验流程更新')
    output.mkdir(parents=True, exist_ok=False)
    pcm_dir = output / 'pcm'
    pcm_dir.mkdir()
    rows = []
    for index, (source, entry) in enumerate(zip(sources, entries)):
        title = str(entry.get('title') or source.stem).strip()
        if not title or len(title) > 48 or any(ord(c) < 32 or c in '"\\' for c in title):
            raise ValueError('曲名需为1～48个可显示字符')
        progress(f'提取 {index + 1}/{len(entries)}：{title}')
        pcm = pcm_dir / f'{index:02d}.pcm'
        command = [str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-nostdin', '-n',
                   '-i', str(source), '-map', '0:a:0', '-vn', '-sn', '-dn',
                   '-map_metadata', '-1', '-ac', '1', '-ar', str(RATE),
                   '-af', 'aresample=48000:async=1:first_pts=0',
                   '-c:a', 'pcm_s16le', '-f', 's16le', str(pcm)]
        result = subprocess.run(command, capture_output=True, text=True,
                                encoding='utf8', errors='replace', timeout=1200,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if result.returncode:
            raise RuntimeError('音轨提取失败：' + result.stderr[-1500:])
        size = pcm.stat().st_size
        if size % 2 or size < 2048 or size > 512 * 1024 * 1024:
            raise ValueError('音频长度不支持或源文件没有有效音轨')
        crc = 0
        with pcm.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                crc = zlib.crc32(block, crc)
        rows.append({'index': index, 'title': title, 'source': str(source),
                     'source_sha256': file_hash(source), 'pcm': str(pcm),
                     'pcm_sha256': file_hash(pcm), 'samples': size // 2,
                     'duration_seconds': size / (RATE * 2), 'crc32': crc})
    cursor = HEADER
    header = bytearray(HEADER)
    struct.pack_into('<4sBBBBIII', header, 0, b'BGM1', 1, len(rows), 1, 16, RATE, HEADER, 0)
    for row in rows:
        row['sector_offset'] = cursor // 512
        struct.pack_into('<IIII', header, 32 + row['index'] * 16,
                         row['sector_offset'], row['samples'], row['crc32'], 0)
        cursor += (row['samples'] * 2 + 511) // 512 * 512
    if cursor > 512 * 1024 * 1024:
        raise ValueError('曲库总大小超过首版512MiB上限')
    struct.pack_into('<I', header, 16, cursor)
    # A content ID keeps the PC playlist and screen preparation paired.
    identity = hashlib.sha256(json.dumps([(r['title'], r['pcm_sha256']) for r in rows],
                                        ensure_ascii=False).encode('utf8')).hexdigest()[:8]
    struct.pack_into('<I', header, 20, int(identity, 16))
    struct.pack_into('<H', header, 28, sum(header[:28] + header[30:]) % 65536)
    library = output / 'BGM.LIB'
    with library.open('xb') as stream:
        stream.write(header)
        for row in rows:
            with Path(row['pcm']).open('rb') as pcm:
                shutil.copyfileobj(pcm, stream, 1024 * 1024)
            stream.write(bytes((-row['samples'] * 2) % 512))
    verified = read_library(library)
    manifest = {'format': 'BGM1', 'catalog_id': identity.upper(), 'sample_rate': RATE,
                'channels': 1, 'sample_bits': 16, 'track_limit': MAX_TRACKS,
                'library': str(library), 'library_bytes': library.stat().st_size,
                'library_sha256': file_hash(library), 'tracks': rows,
                'verified_track_count': len(verified), 'card_written': False,
                'installation': 'PC verifies contiguous FAT32 chain and full readback; paired HMI sends location/size/catalog ID. FPGA validates header and selected track bounds.',
                'touch_catalog': 'Generate and download the paired touch project when track titles/order change; no FPGA UART TX wire is currently present.'}
    (output / 'PLAYLIST.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', 'utf8')
    progress('曲库生成并逐曲校验通过；尚未写TF卡')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('sources', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ffmpeg', type=Path)
    args = parser.parse_args()
    prepare([{'source': str(p), 'title': p.stem} for p in args.sources], args.output, args.ffmpeg)
