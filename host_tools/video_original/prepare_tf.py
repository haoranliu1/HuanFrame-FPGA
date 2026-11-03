"""Backed-up in-place RVF->RVA update. No format, no raw-sector writes."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OLD = 'CLAUDE_CHINESE_512X384_8FPS_HQ.RVF'
NEW = 'CLAUDE_512X384_8FPS_PCM24K.RVA'
OLD_SHA = '9ADB5CB5233EB95C93AFCEDDF5193E8A3821F669B0669298CD4E845C770FFC59'
NEW_SHA = '8CEFB6729A4CF592014F7B490E9636A06C2DEF8699357F6EB1F34326D3B6A622'
BMP = ['00_00_0.bmp', '01_01_1.bmp', '02_02_2.bmp', '03_03_3.bmp']


def sha(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda: f.read(4*1024*1024), b''):
            h.update(b)
    return h.hexdigest().upper()


def card():
    command = "$p=Get-Partition -DriveLetter F;$d=Get-Disk -Number $p.DiskNumber;$v=Get-Volume -DriveLetter F;[pscustomobject]@{Number=$d.Number;Bus=[string]$d.BusType;Size=$d.Size;IsBoot=$d.IsBoot;IsSystem=$d.IsSystem;Offset=$p.Offset;Label=$v.FileSystemLabel;FS=$v.FileSystem}|ConvertTo-Json -Compress"
    r = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command],
                       capture_output=True, text=True, check=True)
    info = json.loads(r.stdout)
    expected = dict(Number=2, Bus='USB', Size=15634268160, IsBoot=False,
                    IsSystem=False, Offset=1048576, Label='ANLOGIC', FS='FAT32')
    if info != expected:
        raise RuntimeError('Unexpected card identity: ' + repr(info))
    return info


def extents(path):
    r = subprocess.run(['fsutil.exe', 'file', 'queryextents', str(path)], capture_output=True, text=True)
    matches = re.findall(r'VCN:\s*(0x[0-9a-f]+)\s+Clusters:\s*(0x[0-9a-f]+)\s+LCN:\s*(0x[0-9a-f]+)',
                         r.stdout + r.stderr, re.I)
    values = [tuple(int(v, 16) for v in row) for row in matches]
    if len(values) != 1 or values[0][0] != 0 or values[0][1] != math.ceil(path.stat().st_size/8192):
        raise RuntimeError('Expected one contiguous FAT extent: ' + r.stdout + r.stderr)
    return dict(vcn=0, clusters=values[0][1], lcn=values[0][2])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--write', action='store_true')
    a = p.parse_args()
    info = card()
    backup = ROOT / 'tf_backup_before_audio'
    media = ROOT / 'media' / NEW
    if sha(media) != NEW_SHA or sha(backup / OLD) != OLD_SHA:
        raise RuntimeError('Local source/rollback hash failed')
    hashes = {}
    for name in BMP + [OLD]:
        actual = sha(Path('F:/') / name)
        if actual != sha(backup / name):
            raise RuntimeError('Card does not match backup: ' + name)
        hashes[name] = actual
    path = Path('F:/') / OLD
    before = extents(path)
    if before['lcn'] != 456 or set(f.name for f in Path('F:/').iterdir() if f.is_file()) != set(BMP + [OLD]):
        raise RuntimeError('Unexpected original card layout')
    report = dict(card=info, before=before, backup=str(backup), original_hashes=hashes, dry_run=not a.write)
    if a.write:
        if (Path('F:/') / NEW).exists():
            raise FileExistsError(NEW)
        # Preserve existing cluster allocation so the header stays inside the
        # FPGA's first 64 MiB scan window. Extend only after its old EOF.
        try:
            with path.open('r+b', buffering=0) as dest, media.open('rb') as src:
                for block in iter(lambda: src.read(4*1024*1024), b''):
                    dest.write(block)
                dest.truncate()
                os.fsync(dest.fileno())
            if sha(path) != NEW_SHA:
                raise RuntimeError('Full card media readback mismatch')
            after = extents(path)
            if after['lcn'] != before['lcn']:
                raise RuntimeError('Header allocation moved')
            path.rename(Path('F:/') / NEW)
            path = Path('F:/') / NEW
            for name in BMP:
                if sha(Path('F:/') / name) != hashes[name]:
                    raise RuntimeError('BMP changed unexpectedly: ' + name)
            report.update(dry_run=False, after=after, new_file=NEW, sha256=NEW_SHA,
                          complete_readback=True, physical_fat_audit=False)
        except Exception:
            with path.open('r+b', buffering=0) as dest, (backup / OLD).open('rb') as src:
                for block in iter(lambda: src.read(4*1024*1024), b''):
                    dest.write(block)
                dest.truncate()
                os.fsync(dest.fileno())
            if path.name != OLD:
                path.rename(Path('F:/') / OLD)
            raise
    out = ROOT / ('TF_PREPARED.json' if a.write else 'TF_DRY_RUN.json')
    out.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
