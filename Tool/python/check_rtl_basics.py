#!/usr/bin/env python3
"""No-Vivado sanity checks for fixed QPSK constants and source invariants."""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
FS_HZ = 100_000_000
CARRIER_HZ = 7_000_000
PHASE_W = 24
COEF_Q = 14


def round_shift_q14(value: int) -> int:
    """Mirror RTL round-to-nearest with ties away from zero."""
    half = 1 << (COEF_Q - 1)
    return (value + half - (1 if value < 0 else 0)) >> COEF_Q


def active_lines(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    shaper = (REPO_ROOT / "RTL/modem/iq_pulse_shaper.v").read_text(encoding="utf-8")
    rx = (REPO_ROOT / "RTL/modem/qpsk_rx_fixed_demod.v").read_text(encoding="utf-8")
    top = (REPO_ROOT / "RTL/top/pl_comm_top.v").read_text(encoding="utf-8")
    tx_tb = (REPO_ROOT / "Sim/tb_qpsk_tx_single_dac_min.v").read_text(encoding="utf-8")
    rebuild = (REPO_ROOT / "scripts/rebuild_project_current.tcl").read_text(encoding="utf-8")
    sys_xdc = (REPO_ROOT / "Constraints/sys_clk_ax7020.xdc").read_text(encoding="utf-8")

    phase_match = re.search(
        r"QPSK_PHASE_INC_DEFAULT\s*=\s*24'h([0-9a-fA-F]+)", top
    )
    require(phase_match is not None, "could not locate QPSK phase increment")
    phase_word = int(phase_match.group(1), 16)
    expected_word = round(CARRIER_HZ * (1 << PHASE_W) / FS_HZ)
    actual_hz = phase_word * FS_HZ / (1 << PHASE_W)
    require(phase_word == expected_word, "7 MHz NCO phase word is inconsistent")
    require(abs(actual_hz - CARRIER_HZ) < 1.0, "7 MHz NCO error exceeds 1 Hz")

    scale = 1 << COEF_Q
    for value in range(0, 8 * scale + 1):
        require(
            round_shift_q14(-value) == -round_shift_q14(value),
            f"rounding lost sign symmetry at {value}",
        )
    require("xr = xr - {{(ACC_W-1){1'b0}}, 1'b1};" in shaper, "RTL rounding fix missing")

    lock_expr = "m_valid <= track_locked || pattern_lock_now ||"
    require(lock_expr in rx, "RX m_valid is not lock-qualified")
    require(
        "tx_ready <= (ready_cycle_cnt % 11 != 0);" in tx_tb,
        "TX backpressure stimulus is disabled",
    )
    require("ERR_RRC_ROUNDING_BOUNDARY" in tx_tb, "RTL rounding boundary test is missing")

    rebuild_active = active_lines(rebuild)
    require(
        "D:/Project/ProjectVivado/Ez_QPSK" not in rebuild_active,
        "Vivado rebuild script still has executable machine-specific paths",
    )
    require("set validate_required 1" in rebuild_active, "required-file validation is disabled")
    require(
        "set origin_dir [file dirname [info script]]" in rebuild_active,
        "Vivado source root still depends on the caller's working directory",
    )
    require(
        '"--validate-only" { set validate_only 1 }' in rebuild_active,
        "Vivado rebuild script has no no-tool validation entry",
    )
    require("create_bd_port -dir I -type clk -freq_hz 50000000 clk_50M" not in rebuild_active,
            "unused clk_50M BD port is still present")

    require("get_ports userrst" not in active_lines(sys_xdc), "stale userrst constraint remains")

    print(
        "[PASS] RTL basics: phase_word=0x%06X actual_carrier=%.6f Hz "
        "rounding=symmetric paths=portable" % (phase_word, actual_hz)
    )


if __name__ == "__main__":
    main()
