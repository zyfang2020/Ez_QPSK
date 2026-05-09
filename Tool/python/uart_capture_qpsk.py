#!/usr/bin/env python3
"""Receive one or more QPSK UART capture frames from the board and save them to disk."""
# python Tool/python/uart_capture_qpsk.py --port COM5

from __future__ import annotations

import argparse
import csv
import json
import struct
import sys
import time
from pathlib import Path

try:
    import serial
except ModuleNotFoundError as exc:
    print("pyserial is required: pip install pyserial", file=sys.stderr)
    raise SystemExit(1) from exc


MAGIC = b"QPSKDMA1"
HEADER_FMT = "<IIII"
HEADER_SIZE = struct.calcsize(HEADER_FMT)


def format_preview(data: bytes, limit: int = 96) -> str:
    if not data:
        return "<no data>"

    shown = data[:limit]
    ascii_preview = "".join(chr(b) if 32 <= b <= 126 else "." for b in shown)
    hex_preview = shown.hex(" ")
    if len(data) > limit:
        ascii_preview += "..."
        hex_preview += " ..."
    return f"ascii='{ascii_preview}' hex={hex_preview}"


def wait_for_magic(port: "serial.Serial", timeout_s: float, prefix: bytes = b"") -> bytes:
    deadline = time.monotonic() + timeout_s
    window = bytearray(prefix)
    captured = bytearray(prefix)

    idx = window.find(MAGIC)
    if idx != -1:
        return bytes(window[idx + len(MAGIC):])

    while time.monotonic() < deadline:
        chunk = port.read(256)
        if not chunk:
            continue

        window.extend(chunk)
        captured.extend(chunk)
        idx = window.find(MAGIC)
        if idx != -1:
            return bytes(window[idx + len(MAGIC):])

        if len(window) > len(MAGIC) * 4:
            del window[:-len(MAGIC)]

    raise TimeoutError(
        "Timed out waiting for UART frame magic. "
        f"Received {len(captured)} byte(s). Preview: {format_preview(bytes(captured))}"
    )


def read_exact(
    port: "serial.Serial",
    size: int,
    timeout_s: float,
    prefix: bytes = b"",
) -> tuple[bytes, bytes]:
    deadline = time.monotonic() + timeout_s
    data = bytearray()
    remaining_prefix = prefix

    if remaining_prefix:
        take = min(len(remaining_prefix), size)
        data.extend(remaining_prefix[:take])
        remaining_prefix = remaining_prefix[take:]

    while len(data) < size and time.monotonic() < deadline:
        chunk = port.read(size - len(data))
        if chunk:
            data.extend(chunk)

    if len(data) != size:
        raise TimeoutError(f"Expected {size} bytes, got {len(data)}")

    return bytes(data), remaining_prefix


def checksum_u16_le(payload: bytes) -> int:
    if len(payload) % 2 != 0:
        raise ValueError("Payload byte count must be even")

    checksum = 0
    for (sample,) in struct.iter_unpack("<H", payload):
        checksum = (checksum + sample) & 0xFFFFFFFF
    return checksum


def build_default_prefix() -> Path:
    stamp = time.strftime("%Y%m%d_%H%M%S")
    return Path("Tool/data") / f"uart_capture_{stamp}"


def resolve_frame_paths(output_prefix: Path, frame_idx: int, multi_frame: bool) -> tuple[Path, Path, Path]:
    if multi_frame:
        frame_prefix = output_prefix.parent / f"{output_prefix.name}_{frame_idx:04d}"
    else:
        frame_prefix = output_prefix
    return (
        frame_prefix.with_suffix(".bin"),
        frame_prefix.with_suffix(".csv"),
        frame_prefix.with_suffix(".json"),
    )


def save_csv(csv_path: Path, payload: bytes) -> None:
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["idx", "sample_u16"])
        for idx, (sample,) in enumerate(struct.iter_unpack("<H", payload)):
            writer.writerow([idx, sample])


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Receive one or more UART capture frames from Ez_QPSK."
    )
    parser.add_argument("--port", required=True, help="Serial port, e.g. COM5 or /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument(
        "--output-prefix",
        default=str(build_default_prefix()),
        help="Output prefix without suffix; .bin/.csv/.json will be appended",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=40.0,
        help="Timeout in seconds for frame sync and reads",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=1,
        help="Number of frames to capture; default 1, 0 means run continuously until Ctrl+C",
    )
    args = parser.parse_args()

    if args.frames < 0:
        raise ValueError("--frames must be >= 0")

    output_prefix = Path(args.output_prefix)
    output_prefix.parent.mkdir(parents=True, exist_ok=True)

    print(f"Opening {args.port} @ {args.baud} baud")
    frame_limit = args.frames
    multi_frame = (frame_limit == 0) or (frame_limit > 1)
    trailing = b""
    frame_idx = 0
    with serial.Serial(args.port, args.baud, timeout=0.2) as port:
        port.reset_input_buffer()
        print("Waiting for frame magic; start or reset the board now...")
        while frame_limit == 0 or frame_idx < frame_limit:
            trailing = wait_for_magic(port, args.timeout, trailing)
            header_bytes, trailing = read_exact(port, HEADER_SIZE, args.timeout, trailing)
            version, sample_count, payload_bytes, expected_checksum = struct.unpack(
                HEADER_FMT, header_bytes
            )
            payload, trailing = read_exact(port, payload_bytes, args.timeout, trailing)

            actual_checksum = checksum_u16_le(payload)
            if actual_checksum != expected_checksum:
                raise ValueError(
                    f"Checksum mismatch: expected 0x{expected_checksum:08X}, got 0x{actual_checksum:08X}"
                )

            if payload_bytes != sample_count * 2:
                raise ValueError(
                    f"Header mismatch: payload_bytes={payload_bytes}, sample_count={sample_count}"
                )

            bin_path, csv_path, json_path = resolve_frame_paths(
                output_prefix, frame_idx, multi_frame
            )
            bin_path.write_bytes(payload)
            save_csv(csv_path, payload)

            metadata = {
                "magic": MAGIC.decode("ascii"),
                "version": version,
                "sample_count": sample_count,
                "payload_bytes": payload_bytes,
                "checksum_expected": expected_checksum,
                "checksum_actual": actual_checksum,
                "port": args.port,
                "baud": args.baud,
                "timestamp_local": time.strftime("%Y-%m-%d %H:%M:%S"),
                "frame_index": frame_idx,
                "bin_file": str(bin_path),
                "csv_file": str(csv_path),
            }
            json_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

            first_samples = [sample for sample, in struct.iter_unpack("<H", payload[:16])]
            print(
                f"Frame {frame_idx + 1} received: version={version}, "
                f"samples={sample_count}, bytes={payload_bytes}, checksum=0x{actual_checksum:08X}"
            )
            print(f"Saved binary: {bin_path}")
            print(f"Saved csv   : {csv_path}")
            print(f"Saved meta  : {json_path}")
            print(f"First samples: {first_samples}")

            if trailing:
                print(f"INFO: carrying {len(trailing)} buffered byte(s) into next frame search")

            frame_idx += 1

    print(f"Capture complete: {frame_idx} frame(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
