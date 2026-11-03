"""Verified, recoverable in-place RVA profile replacement. No raw writes/format."""
import argparse
import json
import os
from pathlib import Path
import shutil

from prepare_tf import card, extents, sha, BMP

ROOT = Path(__file__).resolve().parents[1]
OLD = 'CLAUDE_416X312_8FPS_PCM24K.RVA'
NEW = 'SEVE_416X312_8FPS_PCM24K.RVA'
# Exact discrepant old bytes independently re-read before the user explicitly
# authorized preserving them as evidence and replacing only this RVA.
OLD_SHA = '025C84470DFDB78E245208B07EC588826FBC5CC414F91F561A72235F9864BADD'
EARLIER_DISCREPANT_SHA = '1A860A06E544FBB4990854D99D14E4FF2733A3B1D69F577F1E1D3EC73E714841'
KNOWN_GOOD_OLD_SHA = 'AB0DD05A69779C35098ABD9BCA0F9FDC8E872E49E58312BF7525EB0ABC79ACD7'
NEW_SHA = '0255DBB8A5BB8A7B9DBE109A3E7E5D34921CCE71ED73541EDE6CDD480C555EC5'


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
    source = ROOT / 'media/SEVE_416x312_8fps_20261024' / NEW
    backup = ROOT / 'tf_backup_before_seve_20261024'
    known_good_old = ROOT / 'media/416x312_8fps_20261024' / OLD
    if sha(known_good_old) != KNOWN_GOOD_OLD_SHA:
        raise RuntimeError('Known-good old video recovery source changed')
    if sha(source) != NEW_SHA:
        raise RuntimeError('Candidate media hash mismatch')
    if {f.name for f in drive.iterdir() if f.is_file()} != set(BMP + [OLD]):
        raise RuntimeError('Card root differs from the verified old five-file layout')
    hashes = {name: sha(drive / name) for name in BMP + [OLD]}
    if hashes[OLD] != OLD_SHA:
        raise RuntimeError('Old RVA differs from the explicitly authorized evidence bytes; no write performed')
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
                  original_content_differs_from_known_good=True,
                  earlier_discrepant_sha256=EARLIER_DISCREPANT_SHA,
                  old_read_variation_observed=True,
                  old_read_variation_note='Before any card writes, the initial repeated hash was1A860A06 and later three consecutive reads were025C8447. Cause unknown; current backup must match025C8447 exactly. Do not attribute to FPGA/card hardware without further evidence.',
                  known_good_old_video=str(known_good_old), known_good_old_sha256=KNOWN_GOOD_OLD_SHA,
                  user_authorized_backup_discrepant_old_and_replace_only_RVA=True,
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
    output = ROOT / ('TF_PREPARED_SEVE.json' if args.write else 'TF_DRY_RUN_SEVE.json')
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()


