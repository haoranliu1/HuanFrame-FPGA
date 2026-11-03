"""Verified, recoverable in-place RVA profile replacement. No raw writes/format."""
import argparse
import json
import os
from pathlib import Path
import shutil

from prepare_tf import card, extents, sha, BMP

ROOT = Path(__file__).resolve().parents[1]
OLD = 'SEVE_416X312_8FPS_PCM24K.RVA'
NEW = 'SEVE_416X312_10FPS_PCM24K.RVA'
# Two full repeatable reads and independent evidence backups, followed by the
# user's explicit permission to repair this TF and continue the same test.
OLD_SHA = '36DBA5002DA2127C174DA6D65A6131EDCF8B68A41E0F88427BBB8F7736D62B40'
KNOWN_GOOD_OLD_SHA = '0255DBB8A5BB8A7B9DBE109A3E7E5D34921CCE71ED73541EDE6CDD480C555EC5'
NEW_SHA = '9B931A48E88F6BD694BA8FD846F680348859D9C73EF101F9A315A8E3A1618287'
BAD_PICTURE = '02_02_2.bmp'
BAD_PICTURE_SHA = '65B86467FE16959EA8835FF8308D6F68A07C6227DDF6BA86B99EC51A46F82CF6'
GOOD_PICTURE_SHA = '864951F80DCE7924C469ED506328CCE029E0AF4675607799178C1E7EBF7DF7E3'


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
    source = ROOT / 'media/SEVE_416x312_10fps_SPISTREAM_20261024' / NEW
    backup = ROOT / 'tf_backup_before_spi_stream10_20261024'
    known_good_old = ROOT / 'media/SEVE_416x312_8fps_20261024' / OLD
    evidence = ROOT / 'tf_spi_stream_mismatch_20261024_192013'
    candidate = json.loads((ROOT / 'SPI_STREAM_10FPS_20261024.json').read_text(encoding='utf-8'))
    if not candidate['exact_307200_output_pixels_equal'] or len(candidate['tests']) != 15:
        raise RuntimeError('Candidate offline gate incomplete')
    if sha(evidence / (OLD + '.read1.bak')) != OLD_SHA or sha(evidence / (OLD + '.read2.bak')) != OLD_SHA:
        raise RuntimeError('Independent original anomaly evidence changed')
    if sha(known_good_old) != KNOWN_GOOD_OLD_SHA:
        raise RuntimeError('Known-good old video recovery source changed')
    if sha(source) != NEW_SHA:
        raise RuntimeError('Candidate media hash mismatch')
    if {f.name for f in drive.iterdir() if f.is_file()} != set(BMP + [OLD]):
        raise RuntimeError('Card root differs from the verified old five-file layout')
    hashes = {name: sha(drive / name) for name in BMP + [OLD]}
    if hashes[OLD] != OLD_SHA:
        raise RuntimeError('Card RVA differs from approved repeated anomaly evidence; no write performed')
    if sha(drive / OLD) != OLD_SHA:
        raise RuntimeError('Second independent file read differs; no write performed')
    healthy_pictures = {name: sha(ROOT / 'tf_backup_before_audio' / name) for name in BMP}
    if healthy_pictures[BAD_PICTURE] != GOOD_PICTURE_SHA or sha(evidence / BAD_PICTURE) != BAD_PICTURE_SHA:
        raise RuntimeError('Healthy/evidence picture source changed')
    for name in BMP:
        expected = BAD_PICTURE_SHA if name == BAD_PICTURE else healthy_pictures[name]
        if hashes[name] != expected or sha(evidence / name) != hashes[name]:
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
                  old_file_two_reads_match_approved_anomaly=True,
                  anomaly_evidence=str(evidence), healthy_picture_hashes=healthy_pictures,
                  repaired_bmp=[BAD_PICTURE],
                  known_good_old_video=str(known_good_old), known_good_old_sha256=KNOWN_GOOD_OLD_SHA,
                  user_authorized_shutdown_card_connected_for_10fps_test=True,
                  no_format=True, no_raw_sector_writes=True)
    path = drive / OLD
    if args.write:
        try:
            replace_payload(drive / BAD_PICTURE, ROOT / 'tf_backup_before_audio' / BAD_PICTURE)
            if sha(drive / BAD_PICTURE) != GOOD_PICTURE_SHA:
                raise RuntimeError('BMP repair readback failed')
            replace_payload(path, source)
            if sha(path) != NEW_SHA:
                raise RuntimeError('Full card readback hash mismatch')
            after = extents(path)
            if after['lcn'] != before[OLD]['lcn']:
                raise RuntimeError('RVA physical start moved')
            path = path.rename(drive / NEW)
            for name in BMP:
                if sha(drive / name) != healthy_pictures[name]:
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
                replace_payload(drive / BAD_PICTURE, backup / BAD_PICTURE)
                if sha(drive / BAD_PICTURE) != BAD_PICTURE_SHA:
                    raise RuntimeError('BMP rollback hash mismatch')
            except Exception as rollback_error:
                raise RuntimeError(f'Update failed: {error}; rollback failed: {rollback_error}; intact PC backup: {backup}') from error
            raise RuntimeError(f'Update failed and old card RVA restored: {error}') from error
    output = ROOT / ('TF_PREPARED_SPI_STREAM10.json' if args.write else 'TF_DRY_RUN_SPI_STREAM10.json')
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)


if __name__ == '__main__':
    main()


