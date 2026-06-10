#!/usr/bin/env python3
"""Decode the external-RX ILA rx_demod_dbg_bus CSV export."""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path
from typing import Iterable


BUS_WIDTH = 96
DEFAULT_SAMPLE_RATE_HZ = 100_000_000.0
DEFAULT_PHASE_WIDTH = 24
DEFAULT_FREQ_CORR_LIMIT = 8192


def sign_extend(value: int, width: int) -> int:
    sign_bit = 1 << (width - 1)
    mask = (1 << width) - 1
    value &= mask
    return value - (1 << width) if value & sign_bit else value


def bits(value: int, hi: int, lo: int) -> int:
    return (value >> lo) & ((1 << (hi - lo + 1)) - 1)


def parse_int_cell(text: str, default_base: int | None = None) -> tuple[int, bool]:
    raw = text.strip().strip('"').replace("_", "")
    raw = raw.replace(" ", "")
    if not raw:
        return 0, True

    lower_raw = raw.lower()
    prefix_len = 2 if lower_raw.startswith("0x") else 1 if lower_raw.startswith(("h", "b")) else 0
    unknown = any(ch in lower_raw[prefix_len:] for ch in "xz?")
    clean = raw[:prefix_len] + re.sub(r"[xXzZ?]", "0", raw[prefix_len:])
    lower = clean.lower()

    if lower.startswith(("0x", "h")):
        token = lower[2:] if lower.startswith("0x") else lower[1:]
        return int(token or "0", 16), unknown
    if lower.startswith(("0b", "b")):
        token = lower[2:] if lower.startswith("0b") else lower[1:]
        return int(token or "0", 2), unknown
    if default_base == 16:
        return int(lower or "0", 16), unknown
    if default_base == 2:
        return int(lower or "0", 2), unknown
    if default_base == 10:
        return int(lower or "0", 10), unknown
    if re.fullmatch(r"[01]+", lower) and len(lower) > 1:
        return int(lower, 2), unknown
    return int(lower, 10), unknown


def find_header(rows: list[list[str]]) -> tuple[int, list[str]]:
    for idx, row in enumerate(rows):
        lowered = [cell.strip().lower() for cell in row]
        if any(("rx_demod_dbg_bus" in cell) or ("probe2" in cell) for cell in lowered):
            return idx, row
    raise ValueError("Could not find a CSV header containing rx_demod_dbg_bus or probe2")


def choose_vector_column(header: list[str], requested: str | None) -> int | None:
    if requested:
        for idx, name in enumerate(header):
            if name.strip() == requested:
                return idx
        raise ValueError(f"Requested bus column not found: {requested}")

    candidates: list[tuple[int, int]] = []
    for idx, name in enumerate(header):
        lower = name.lower()
        if "rx_demod_dbg_bus" not in lower and "probe2" not in lower:
            continue
        if re.search(r"\[\d+\]$", lower):
            continue
        score = 0
        if "rx_demod_dbg_bus" in lower:
            score += 10
        if "[95:0]" in lower or "[0:95]" in lower:
            score += 5
        candidates.append((score, idx))
    if not candidates:
        return None
    return max(candidates)[1]


def find_bit_columns(header: list[str]) -> dict[int, int]:
    found: dict[int, int] = {}
    for idx, name in enumerate(header):
        lower = name.lower()
        match = re.search(r"(?:rx_demod_dbg_bus|probe2)\[(\d+)\]\s*$", lower)
        if match:
            found[int(match.group(1))] = idx
    return found


def decode_bus(value: int) -> dict[str, int]:
    return {
        "nco_freq_corr": sign_extend(bits(value, 95, 80), 16),
        "i": sign_extend(bits(value, 79, 64), 16),
        "q": sign_extend(bits(value, 63, 48), 16),
        "lock_score": bits(value, 47, 40),
        "best_phase": bits(value, 39, 34),
        "phase_bin": bits(value, 33, 30),
        "lock": bits(value, 29, 29),
        "valid": bits(value, 28, 28),
        "symbol": bits(value, 27, 26),
        "adc_raw": bits(value, 25, 16),
        "adc_sample": bits(value, 15, 0),
    }


def is_radix_row(row: list[str]) -> bool:
    return bool(row) and row[0].strip().lower().startswith("radix")


def parse_radix_row(row: list[str]) -> dict[int, int]:
    bases: dict[int, int] = {}
    for idx, cell in enumerate(row):
        token = cell.strip().upper()
        if token == "HEX":
            bases[idx] = 16
        elif token in {"BIN", "BINARY"}:
            bases[idx] = 2
        elif token in {"UNSIGNED", "SIGNED", "DEC", "DECIMAL"}:
            bases[idx] = 10
    return bases


def read_rows(path: Path) -> tuple[list[str], dict[int, int], list[list[str]]]:
    with path.open("r", newline="", encoding="utf-8-sig") as fh:
        raw_rows = list(csv.reader(fh))
    header_idx, header = find_header(raw_rows)
    rows = raw_rows[header_idx + 1 :]
    radix_bases: dict[int, int] = {}
    if rows and is_radix_row(rows[0]):
        radix_bases = parse_radix_row(rows[0])
        rows = rows[1:]
    return header, radix_bases, rows


def iter_decoded(path: Path, bus_column: str | None = None) -> tuple[list[dict[str, int]], int]:
    header, radix_bases, rows = read_rows(path)
    vector_idx = choose_vector_column(header, bus_column)
    bit_columns = find_bit_columns(header)
    unknown_count = 0
    decoded: list[dict[str, int]] = []

    if vector_idx is None and len(bit_columns) < BUS_WIDTH:
        raise ValueError(
            "Could not find a full bus vector column or all rx_demod_dbg_bus/probe2 bit columns"
        )

    for sample_idx, row in enumerate(rows):
        if not row or all(not cell.strip() for cell in row):
            continue
        if vector_idx is not None:
            if vector_idx >= len(row):
                continue
            value, unknown = parse_int_cell(row[vector_idx], radix_bases.get(vector_idx))
            unknown_count += int(unknown)
        else:
            value = 0
            unknown = False
            for bit_idx, col_idx in bit_columns.items():
                if col_idx >= len(row):
                    continue
                bit_value, bit_unknown = parse_int_cell(row[col_idx], radix_bases.get(col_idx))
                unknown |= bit_unknown
                value |= (bit_value & 1) << bit_idx
            unknown_count += int(unknown)

        item = {"sample": sample_idx, "bus": value}
        item.update(decode_bus(value))
        decoded.append(item)

    return decoded, unknown_count


def longest_true_run(values: Iterable[int]) -> int:
    best = 0
    cur = 0
    for value in values:
        if value:
            cur += 1
            best = max(best, cur)
        else:
            cur = 0
    return best


def mean_abs(values: list[int]) -> float:
    if not values:
        return 0.0
    return sum(abs(v) for v in values) / len(values)


def rms_iq(items: list[dict[str, int]]) -> float:
    if not items:
        return 0.0
    energy = [(item["i"] * item["i"] + item["q"] * item["q"]) for item in items]
    return math.sqrt(sum(energy) / len(energy))


def count_by(values: Iterable[int]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for value in values:
        key = str(value)
        counts[key] = counts.get(key, 0) + 1
    return counts


def entropy(values: list[int]) -> float:
    if not values:
        return 0.0
    counts = count_by(values)
    total = float(len(values))
    return -sum((count / total) * math.log2(count / total) for count in counts.values())


def transition_count(values: list[int]) -> int:
    if len(values) < 2:
        return 0
    return sum(1 for prev, cur in zip(values, values[1:]) if cur != prev)


def gray_cycle_metrics(symbols: list[int]) -> dict[str, object]:
    cycle = [0, 1, 3, 2]
    if not symbols:
        return {
            "gray_cycle_valid_symbols": 0,
            "gray_cycle_best_match_ratio": 0.0,
            "gray_cycle_best_match_count": 0,
            "gray_cycle_best_offset": None,
            "gray_cycle_best_direction": None,
        }

    best_matches = -1
    best_offset = 0
    best_direction = 1
    for direction in (1, -1):
        for offset in range(len(cycle)):
            matches = 0
            for idx, sym in enumerate(symbols):
                expected = cycle[(offset + direction * idx) % len(cycle)]
                if sym == expected:
                    matches += 1
            if matches > best_matches:
                best_matches = matches
                best_offset = offset
                best_direction = direction

    return {
        "gray_cycle_valid_symbols": len(symbols),
        "gray_cycle_best_match_ratio": best_matches / len(symbols),
        "gray_cycle_best_match_count": best_matches,
        "gray_cycle_best_offset": best_offset,
        "gray_cycle_best_direction": best_direction,
    }


def make_hints(
    *,
    unknown_count: int,
    adc_span: int,
    lock_ratio: float,
    valid_ratio: float,
    nco_abs_max: int,
    freq_corr_limit: int,
    valid_symbols: list[int],
    iq_rms_valid: float,
    gray_match_ratio: float,
) -> list[str]:
    hints: list[str] = []
    if unknown_count:
        hints.append("CSV contains X/Z/? values; those bits were decoded as zero.")
    if adc_span < 8:
        hints.append("ADC span is very small; check the external source, ADC clock, and input bias.")
    elif adc_span > 950:
        hints.append("ADC span is near full scale; check for clipping at the ADC input.")
    if valid_ratio < 0.01:
        hints.append("Very few valid symbols were observed; confirm RX enable and ILA clock/probes.")
    if lock_ratio < 0.10:
        hints.append("Lock ratio is low; check carrier frequency, symbol rate, polarity, and input amplitude.")
    if valid_symbols and len(set(valid_symbols)) < 2:
        hints.append("Valid symbols barely change; check whether the source is static or badly clipped.")
    if len(valid_symbols) >= 16 and gray_match_ratio >= 0.85:
        hints.append("Valid symbols closely match the 00-01-11-10 Gray cycle.")
    if freq_corr_limit > 0 and nco_abs_max >= int(freq_corr_limit * 0.90):
        hints.append("NCO correction is near its limit; the carrier offset may be outside the current capture range.")
    if lock_ratio >= 0.80 and iq_rms_valid > 0:
        hints.append("Lock and I/Q activity look plausible; inspect decoded symbols or run a BER-oriented check next.")
    return hints


def summarize(
    items: list[dict[str, int]],
    unknown_count: int,
    sample_rate_hz: float = DEFAULT_SAMPLE_RATE_HZ,
    phase_width: int = DEFAULT_PHASE_WIDTH,
    freq_corr_limit: int = DEFAULT_FREQ_CORR_LIMIT,
) -> dict[str, object]:
    if not items:
        return {"samples": 0, "unknown_rows": unknown_count}

    lock_values = [item["lock"] for item in items]
    valid_values = [item["valid"] for item in items]
    locked = [item for item in items if item["lock"]]
    valid = [item for item in items if item["valid"]]
    first_lock = next((item["sample"] for item in items if item["lock"]), None)

    scores = [item["lock_score"] for item in items]
    nco = [item["nco_freq_corr"] for item in items]
    phases = [item["best_phase"] for item in items]
    adc_raw = [item["adc_raw"] for item in items]
    valid_symbols = [item["symbol"] for item in valid]
    gray_metrics = gray_cycle_metrics(valid_symbols)
    adc_span = max(adc_raw) - min(adc_raw)
    nco_lsb_hz = sample_rate_hz / float(1 << phase_width)
    iq_rms_valid = rms_iq(valid)
    lock_count = sum(lock_values)
    valid_count = sum(valid_values)
    nco_abs_max = max(abs(value) for value in nco)
    nco_last_hz = nco[-1] * nco_lsb_hz
    nco_min_hz = min(nco) * nco_lsb_hz
    nco_max_hz = max(nco) * nco_lsb_hz
    lock_ratio = lock_count / len(items)
    valid_ratio = valid_count / len(items)

    return {
        "samples": len(items),
        "unknown_rows": unknown_count,
        "lock_count": lock_count,
        "lock_ratio": lock_ratio,
        "valid_count": valid_count,
        "valid_ratio": valid_ratio,
        "lock_count_when_valid": sum(item["lock"] for item in valid),
        "lock_ratio_when_valid": (sum(item["lock"] for item in valid) / valid_count)
        if valid_count
        else 0.0,
        "first_lock_sample": first_lock,
        "longest_lock_run": longest_true_run(lock_values),
        "lock_score_min": min(scores),
        "lock_score_max": max(scores),
        "lock_score_mean": statistics.fmean(scores),
        "sample_rate_hz": sample_rate_hz,
        "phase_width": phase_width,
        "nco_freq_corr_lsb_hz": nco_lsb_hz,
        "nco_freq_corr_min": min(nco),
        "nco_freq_corr_max": max(nco),
        "nco_freq_corr_last": nco[-1],
        "nco_freq_corr_min_hz": nco_min_hz,
        "nco_freq_corr_max_hz": nco_max_hz,
        "nco_freq_corr_last_hz": nco_last_hz,
        "best_phase_counts": count_by(phases),
        "symbol_counts_when_valid": count_by(valid_symbols),
        "symbol_entropy_when_valid_bits": entropy(valid_symbols),
        "symbol_transition_count_when_valid": transition_count(valid_symbols),
        **gray_metrics,
        "i_mean_abs_when_valid": mean_abs([item["i"] for item in valid]),
        "q_mean_abs_when_valid": mean_abs([item["q"] for item in valid]),
        "iq_rms_when_valid": iq_rms_valid,
        "adc_raw_min": min(adc_raw),
        "adc_raw_max": max(adc_raw),
        "adc_raw_mean": statistics.fmean(adc_raw),
        "adc_raw_span": adc_span,
        "locked_sample_count": len(locked),
        "hints": make_hints(
            unknown_count=unknown_count,
            adc_span=adc_span,
            lock_ratio=lock_ratio,
            valid_ratio=valid_ratio,
            nco_abs_max=nco_abs_max,
            freq_corr_limit=freq_corr_limit,
            valid_symbols=valid_symbols,
            iq_rms_valid=iq_rms_valid,
            gray_match_ratio=float(gray_metrics["gray_cycle_best_match_ratio"]),
        ),
    }


def write_decoded_csv(path: Path, items: list[dict[str, int]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "sample",
        "bus",
        "nco_freq_corr",
        "i",
        "q",
        "lock_score",
        "best_phase",
        "phase_bin",
        "lock",
        "valid",
        "symbol",
        "adc_raw",
        "adc_sample",
    ]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        for item in items:
            row = dict(item)
            row["bus"] = f"0x{item['bus']:024X}"
            writer.writerow({field: row[field] for field in fields})


def print_summary(summary: dict[str, object]) -> None:
    for key, value in summary.items():
        if isinstance(value, float):
            print(f"{key}: {value:.6g}")
        else:
            print(f"{key}: {value}")


def check_expectations(
    summary: dict[str, object],
    *,
    min_lock_ratio: float | None,
    min_valid_ratio: float | None,
    min_adc_span: int | None,
    min_gray_cycle_ratio: float | None,
) -> list[str]:
    failures: list[str] = []
    samples = int(summary.get("samples", 0))
    if samples <= 0:
        return ["No decoded samples were found."]

    lock_ratio = float(summary.get("lock_ratio", 0.0))
    valid_ratio = float(summary.get("valid_ratio", 0.0))
    adc_span = int(summary.get("adc_raw_span", 0))
    gray_cycle_ratio = float(summary.get("gray_cycle_best_match_ratio", 0.0))

    if min_lock_ratio is not None and lock_ratio < min_lock_ratio:
        failures.append(f"lock_ratio {lock_ratio:.6g} < {min_lock_ratio:.6g}")
    if min_valid_ratio is not None and valid_ratio < min_valid_ratio:
        failures.append(f"valid_ratio {valid_ratio:.6g} < {min_valid_ratio:.6g}")
    if min_adc_span is not None and adc_span < min_adc_span:
        failures.append(f"adc_raw_span {adc_span} < {min_adc_span}")
    if min_gray_cycle_ratio is not None and gray_cycle_ratio < min_gray_cycle_ratio:
        failures.append(
            f"gray_cycle_best_match_ratio {gray_cycle_ratio:.6g} < {min_gray_cycle_ratio:.6g}"
        )

    return failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Decode Vivado ILA CSV data for rx_demod_dbg_bus[95:0]."
    )
    parser.add_argument("csv_file", type=Path, help="Vivado ILA CSV export")
    parser.add_argument(
        "--bus-column",
        help="Exact CSV column name for the 96-bit bus, if auto-detection is ambiguous",
    )
    parser.add_argument(
        "--decoded-csv",
        type=Path,
        help="Optional decoded per-sample CSV output",
    )
    parser.add_argument(
        "--summary-json",
        type=Path,
        help="Optional JSON summary output",
    )
    parser.add_argument(
        "--sample-rate-hz",
        type=float,
        default=DEFAULT_SAMPLE_RATE_HZ,
        help="Sample/NCO clock rate used for nco_freq_corr Hz conversion",
    )
    parser.add_argument(
        "--phase-width",
        type=int,
        default=DEFAULT_PHASE_WIDTH,
        help="NCO phase accumulator width used for nco_freq_corr Hz conversion",
    )
    parser.add_argument(
        "--freq-corr-limit",
        type=int,
        default=DEFAULT_FREQ_CORR_LIMIT,
        help="Absolute qpsk_rx_fixed_demod nco_freq_corr limit for diagnostics",
    )
    parser.add_argument(
        "--check-external-rx",
        action="store_true",
        help="Return nonzero if basic external-RX capture thresholds are not met",
    )
    parser.add_argument(
        "--min-lock-ratio",
        type=float,
        help="Minimum lock_ratio required for a passing check",
    )
    parser.add_argument(
        "--min-valid-ratio",
        type=float,
        help="Minimum valid_ratio required for a passing check",
    )
    parser.add_argument(
        "--min-adc-span",
        type=int,
        help="Minimum adc_raw_span required for a passing check",
    )
    parser.add_argument(
        "--check-gray-cycle",
        action="store_true",
        help="Require valid symbols to match the 00-01-11-10 Gray cycle, allowing phase/direction ambiguity",
    )
    parser.add_argument(
        "--min-gray-cycle-ratio",
        type=float,
        help="Minimum Gray-cycle match ratio required for a passing check",
    )
    args = parser.parse_args()

    items, unknown_count = iter_decoded(args.csv_file, args.bus_column)
    summary = summarize(
        items,
        unknown_count,
        sample_rate_hz=args.sample_rate_hz,
        phase_width=args.phase_width,
        freq_corr_limit=args.freq_corr_limit,
    )

    min_lock_ratio = args.min_lock_ratio
    min_valid_ratio = args.min_valid_ratio
    min_adc_span = args.min_adc_span
    min_gray_cycle_ratio = args.min_gray_cycle_ratio
    if args.check_external_rx:
        if min_lock_ratio is None:
            min_lock_ratio = 0.50
        if min_valid_ratio is None:
            min_valid_ratio = 0.005
        if min_adc_span is None:
            min_adc_span = 16
    if args.check_gray_cycle and min_gray_cycle_ratio is None:
        min_gray_cycle_ratio = 0.85

    checks_requested = args.check_external_rx or args.check_gray_cycle or any(
        value is not None
        for value in (min_lock_ratio, min_valid_ratio, min_adc_span, min_gray_cycle_ratio)
    )
    check_failures = (
        check_expectations(
            summary,
            min_lock_ratio=min_lock_ratio,
            min_valid_ratio=min_valid_ratio,
            min_adc_span=min_adc_span,
            min_gray_cycle_ratio=min_gray_cycle_ratio,
        )
        if checks_requested
        else []
    )
    if checks_requested:
        summary["check_failures"] = check_failures

    print_summary(summary)

    if args.decoded_csv:
        write_decoded_csv(args.decoded_csv, items)
        print(f"decoded_csv: {args.decoded_csv}")
    if args.summary_json:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(f"summary_json: {args.summary_json}")

    if check_failures:
        print("check_result: FAIL")
        for failure in check_failures:
            print(f"check_failure: {failure}")
        return 2
    if checks_requested:
        print("check_result: PASS")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
