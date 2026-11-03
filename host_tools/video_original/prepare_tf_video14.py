"""Guarded 10fps->14fps TF replacement; default Dry Run, no raw writes/format."""
import argparse
import json
import os
from pathlib import Path
import shutil
from prepare_tf import card, extents, sha, BMP

ROOT = Path(__file__).resolve().parents[1]
OLD = 'SEVE_416X312_10FPS_PCM24K.RVA'
NEW = 'SEVE_320X240_14FPS_PCM24K.RVA'
OLD_SHA = '9B931A48E88F6BD694BA8FD846F680348859D9C73EF101F9A315A8E3A1618287'
NEW_SHA = '0657D13668D17AF04571D0B4CF329638D3E88A2563177D91FCEE43B1E725CEFC'


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
    identity = card()
    candidate = json.loads((ROOT / 'VIDEO14_CANDIDATE.json').read_text(encoding='utf-8'))
    if candidate['status'] != 'OFFLINE_PASS_NOT_JTAG_OR_HARDWARE_VERIFIED' or not candidate['actual_1714_sample_continuity_verified']:
        raise RuntimeError('Offline gate failed')
    source = Path(candidate['media'])
    old_source = ROOT / 'media/SEVE_416x312_10fps_SPISTREAM_20261024' / OLD
    if sha(source) != NEW_SHA or sha(old_source) != OLD_SHA or sha(Path(candidate['bit'])) != candidate['sha256']:
        raise RuntimeError('Source/bit/rollback hash mismatch')
    drive = Path('F:/')
    if {p.name for p in drive.iterdir() if p.is_file()} != set(BMP + [OLD]):
        raise RuntimeError('Unexpected card root')
    expected = json.loads((ROOT / 'TF_PREPARED_SPI_STREAM10.json').read_text(encoding='utf-8'))['healthy_picture_hashes']
    expected[OLD] = OLD_SHA
    hashes = {name: sha(drive / name) for name in BMP + [OLD]}
    if hashes != expected or sha(drive / OLD) != OLD_SHA:
        raise RuntimeError('Card content mismatch/repeated read disagreement; no writes')
    before = {name: extents(drive / name) for name in BMP + [OLD]}
    if before[OLD]['lcn'] != 456:
        raise RuntimeError('Unexpected RVA start')
    backup = ROOT / 'tf_backup_before_video14_20261024'
    backup.mkdir(exist_ok=True)
    for name in BMP + [OLD]:
        target = backup / name
        if not target.exists():
            shutil.copy2(drive / name, target)
        if sha(target) != hashes[name]:
            raise RuntimeError('Backup hash mismatch: ' + name)
    report = dict(card=identity, backup=str(backup), original_hashes=hashes,
        before=before, source=str(source), expected_new_sha256=NEW_SHA,
        healthy_picture_hashes={name: hashes[name] for name in BMP},
        dry_run=not args.write, no_format=True, no_raw_sector_writes=True,
        user_confirmed_board_off_card_connected=True)
    path = drive / OLD
    if args.write:
        try:
            replace_payload(path, source)
            if sha(path) != NEW_SHA or extents(path)['lcn'] != before[OLD]['lcn']:
                raise RuntimeError('Video readback/layout mismatch')
            path = path.rename(drive / NEW)
            for name in BMP:
                if sha(drive / name) != hashes[name] or extents(drive / name) != before[name]:
                    raise RuntimeError('BMP content/layout changed: ' + name)
            after = {name: dict(**extents(drive / name), bytes=(drive / name).stat().st_size)
                     for name in BMP + [NEW]}
            report.update(complete_readback=True, new_file=NEW, sha256=NEW_SHA, after=after)
        except Exception as error:
            try:
                replace_payload(path, backup / OLD)
                if sha(path) != OLD_SHA:
                    raise RuntimeError('Rollback hash mismatch')
                if path.name != OLD:
                    path.rename(drive / OLD)
            except Exception as rollback:
                raise RuntimeError(f'Update failed:{error}; rollback failed:{rollback}; PC backup:{backup}') from error
            raise RuntimeError(f'Update failed; original RVA restored:{error}') from error
    output = ROOT / ('TF_PREPARED_VIDEO14.json' if args.write else 'TF_DRY_RUN_VIDEO14.json')
    with output.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()
