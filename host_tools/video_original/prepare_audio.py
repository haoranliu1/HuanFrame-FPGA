"""Export the source soundtrack without changing verified RVF media or hardware."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import wave
from fractions import Fraction
from pathlib import Path


SAMPLE_RATE = 48_000
SAMPLE_BYTES = 2


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def probe(ffprobe: Path, path: Path) -> dict:
    result = subprocess.run(
        [str(ffprobe), "-v", "error", "-show_streams", "-show_format",
         "-of", "json", str(path)],
        check=True, capture_output=True, encoding="utf-8",
    )
    return json.loads(result.stdout)


def prepare(args: argparse.Namespace) -> None:
    source = args.source.resolve(strict=True)
    rvf = args.rvf.resolve(strict=True)
    ffmpeg = args.ffmpeg.resolve(strict=True)
    ffprobe = ffmpeg.with_name("ffprobe.exe").resolve(strict=True)
    with rvf.open("rb") as stream:
        header = stream.read(512)
    if len(header) != 512 or header[:4] != b"RVF1":
        raise ValueError("Expected the verified RVF1 media file")
    width, height, compatibility_fps, pixel_format = struct.unpack_from("<HHBB", header, 4)
    frames = struct.unpack_from("<I", header, 12)[0]
    frame_sectors = struct.unpack_from("<H", header, 16)[0]
    if pixel_format != 1 or width * height * 2 != frame_sectors * 512:
        raise ValueError("Unsupported RVF1 geometry or pixel format")
    if rvf.stat().st_size != 512 + frames * frame_sectors * 512:
        raise ValueError("RVF1 file length disagrees with its header")
    fps = Fraction(args.fps)
    samples_per_frame = Fraction(SAMPLE_RATE, 1) / fps
    if fps <= 0 or samples_per_frame.denominator != 1:
        raise ValueError("FPS must divide 48000 into an integer sample count")
    total_samples = frames * int(samples_per_frame)
    duration = Fraction(total_samples, SAMPLE_RATE)
    source_info = probe(ffprobe, source)
    if not any(s["codec_type"] == "audio" for s in source_info["streams"]):
        raise ValueError("Source has no audio stream")

    output = args.output.resolve()
    # Never overwrite a previous extraction or a frozen media directory.
    output.mkdir(parents=True, exist_ok=False)
    original = output / "source_soundtrack_aac.m4a"
    wav_path = output / "soundtrack_48k_mono_s16.wav"
    pcm_path = output / "soundtrack_48k_mono_s16le.pcm"
    prefix = [str(ffmpeg), "-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
    run(prefix + ["-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn",
                  "-map_metadata", "-1", "-c:a", "copy", str(original)])
    audio_filter = (
        f"aresample={SAMPLE_RATE}:async=1:first_pts=0,"
        f"apad=whole_len={total_samples},atrim=end_sample={total_samples},"
        "asetpts=N/SR/TB"
    )
    run(prefix + ["-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn",
                  "-map_metadata", "-1", "-ac", "1", "-ar", str(SAMPLE_RATE),
                  "-af", audio_filter, "-c:a", "pcm_s16le", str(wav_path)])
    run(prefix + ["-i", str(wav_path), "-map", "0:a:0", "-c:a", "copy",
                  "-f", "s16le", str(pcm_path)])
    with wave.open(str(wav_path), "rb") as wav_stream:
        if (wav_stream.getnchannels(), wav_stream.getsampwidth(),
                wav_stream.getframerate(), wav_stream.getnframes()) != (
                    1, SAMPLE_BYTES, SAMPLE_RATE, total_samples):
            raise ValueError("Unexpected WAV geometry or length")
        with pcm_path.open("rb") as pcm_stream:
            while True:
                block = wav_stream.readframes(65536)
                if pcm_stream.read(len(block)) != block:
                    raise ValueError("Raw PCM differs from WAV samples")
                if not block:
                    if pcm_stream.read(1):
                        raise ValueError("Trailing raw PCM bytes")
                    break
    if pcm_path.stat().st_size != total_samples * SAMPLE_BYTES:
        raise ValueError("Raw PCM length mismatch")

    artifacts = [original, wav_path, pcm_path]
    if args.preview:
        preview_source = args.preview.resolve(strict=True)
        preview = output / "video_8fps_with_source_audio_preview.mp4"
        run(prefix + ["-i", str(preview_source), "-i", str(wav_path),
                      "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
                      "-c:a", "aac", "-b:a", "96k", "-t", f"{float(duration):.9f}",
                      "-movflags", "+faststart", str(preview)])
        preview_info = probe(ffprobe, preview)
        if not all(any(s["codec_type"] == kind for s in preview_info["streams"])
                   for kind in ("audio", "video")):
            raise ValueError("Preview must contain audio and video")
        artifacts.append(preview)

    manifest = {
        "status": "MEDIA_PREPARED_ONLY_NOT_FPGA_PLAYBACK",
        "source": str(source), "source_sha256": sha256(source),
        "source_probe": source_info,
        "rvf": str(rvf), "rvf_sha256": sha256(rvf),
        "video_width": width, "video_height": height, "video_frames": frames,
        "rvf_header_compatibility_fps": compatibility_fps,
        "actual_playback_fps": str(fps),
        "sample_rate": SAMPLE_RATE, "channels": 1,
        "sample_format": "signed 16-bit little-endian PCM",
        "samples_per_video_frame": int(samples_per_frame),
        "pcm_bytes_per_video_frame": int(samples_per_frame) * SAMPLE_BYTES,
        "total_samples": total_samples, "duration_seconds": float(duration),
        "pcm_bytes_per_second": SAMPLE_RATE * SAMPLE_BYTES,
        "wav_raw_sample_comparison_pass": True,
        "hardware_modified": False,
        "sync_note": (
            "Aligned to the nominal RVF1 timeline; FPGA must share pause, "
            "buffer-underflow recovery, frame step and loop state. "
            "Independent wall-clock playback is not synchronized playback."
        ),
        "artifacts": [{"name": p.name, "bytes": p.stat().st_size,
                       "sha256": sha256(p)} for p in artifacts],
    }
    manifest_path = output / "AUDIO_PREPARATION.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                             encoding="utf-8")
    print(json.dumps({key: manifest[key] for key in (
        "status", "video_frames", "duration_seconds", "total_samples",
        "samples_per_video_frame", "pcm_bytes_per_second",
        "wav_raw_sample_comparison_pass", "hardware_modified",
    )}, ensure_ascii=False, indent=2))
    print(f"output={output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--rvf", required=True, type=Path)
    parser.add_argument("--fps", default="8", help="Actual FPGA rate, not RVF compatibility field")
    parser.add_argument("--preview", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    prepare(parser.parse_args())
