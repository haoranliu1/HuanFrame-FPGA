"""Verified, recoverable in-place RVA profile replacement. No raw writes/format."""
import argparse
import json
import os
from pathlib import Path
import shutil

from prepare_tf import card, extents, sha, BMP

ROOT = Path(__file__).resolve().parents[1]
OLD = 'CLAUDE_512X384_8FPS_PCM24K.RVA'
NEW = 'CLAUDE_416X312_8FPS_PCM24K.RVA'
OLD_SHA = '8CEFB6729A4CF592014F7B490E9636A06C2DEF8699357F6EB1F34326D3B6A622'
NEW_SHA = 'AB0DD05A69779C35098ABD9BCA0F9FDC8E872E49E58312BF7525EB0ABC79ACD7'


def replace_payload(destination, source):
    with destination.open('r+b', buffering=0) as dst, source.open('rb') as src:
        for block in iter(lambda: src.read(4194304), b''):
            if dst.write(block) != len(block):
                raise RuntimeError('Short card write')
        dst.truncate()
        os.fsync(dst.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    identity = card()  # Exact disk/size/bus/partition/label guard, not letter alone.
    drive = Path('F:/')
    source = ROOT / 'media/416x312_8fps_20261024' / NEW
    backup = ROOT / 'tf_backup_before_416x312_20261024'
    if sha(source) != NEW_SHA:
        raise RuntimeError('Candidate media hash mismatch')
    if {f.name for f in drive.iterdir() if f.is_file()} != set(BMP + [OLD]):
        raise RuntimeError('Card root differs from the verified old five-file layout')
    hashes = {name: sha(drive / name) for name in BMP + [OLD]}
    if hashes[OLD] != OLD_SHA:
        raise RuntimeError('Old RVA is damaged or unexpected; no write performed')
    for name in BMP:
        if hashes[name] != sha(ROOT / 'tf_backup_before_audio' / name):
            raise RuntimeError('Unexpected BMP: ' + name)
    before = {name: extents(drive / name) for name in BMP + [OLD]}
    if before[OLD]['lcn'] != 456:
        raise RuntimeError('Old RVA moved outside expected physical layout')
    backup.mkdir(exist_ok=True)
    for name in BMP + [OLD]:
        destination = backup / name
        if not destination.exists():
            shutil.copy2(drive / name, destination)
        if sha(destination) != hashes[name]:
            raise RuntimeError('Backup hash mismatch; write refused: ' + name)
    report = dict(card=identity, backup=str(backup), original_hashes=hashes,
                  before=before, dry_run=not args.write, new_file=NEW,
                  expected_new_sha256=NEW_SHA, source=str(source),
                  no_format=True, no_raw_sector_writes=True)
    path = drive / OLD
    if args.write:
        try:
            replace_payload(path, source)
            if sha(path) != NEW_SHA:
                raise RuntimeError('Full card readback hash mismatch')
            after = extents(path)
            if after['lcn'] != before[OLD]['lcn']:
                raise RuntimeError('RVA physical start moved')
            path = path.rename(drive / NEW)
            for name in BMP:
                if sha(drive / name) != hashes[name]:
                    raise RuntimeError('BMP changed unexpectedly: ' + name)
            files = {name: dict(**extents(drive / name), bytes=(drive / name).stat().st_size)
                     for name in BMP + [NEW]}
            report.update(complete_readback=True, sha256=NEW_SHA,
                          new_bytes=path.stat().st_size, after=files)
        except Exception as error:
            try:
                replace_payload(path, backup / OLD)
                if sha(path) != OLD_SHA:
                    raise RuntimeError('Rollback readback hash mismatch')
                if path.name != OLD:
                    path.rename(drive / OLD)
            except Exception as rollback_error:
                raise RuntimeError(f'Update failed: {error}; rollback failed: {rollback_error}; intact PC backup: {backup}') from error
            raise RuntimeError(f'Update failed and old card RVA restored: {error}') from error
    output = ROOT / ('TF_PREPARED_416X312.json' if args.write else 'TF_DRY_RUN_416X312.json')
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
