# AGENTS.md

## Project Context

- Project: Ez_QPSK on AX7020 / Zynq-7020.
- Current branch: `Part2`.
- Current stage-1 baseline:
  - TX path exists in PL: `qpsk_test_gen -> qpsk_tx_single_dac -> ad9762_driver -> DAC`.
  - RX path currently captures raw ADC samples and sends them toward AXI DMA.
  - Current sample clock plan is unchanged: PS `FCLK_CLK0` drives both `clk_axi` and `clk_io`; `pl_comm_top` forwards `clk_io` to `clk_adc` and `clk_dac`.
- User preference for stage 2:
  - Do not rework the BD for now.
  - Do not focus on PS-side software or DMA for this stage.
  - Add a separate PL-side online demod path from the ADC capture side.
  - First acceptance target is simulation: local TX loopback can be demodulated in RTL simulation.
  - Later target is external QPSK input at a fixed carrier frequency.

## Git / Branch Discipline

- Work only on the current branch `Part2` unless the user explicitly asks for a branch change.
- Do not switch to, merge into, rebase, reset, or otherwise modify `main` during this stage.
- It is OK for Codex to create local commits on `Part2` at verified stage milestones when the user asks for checkpoint commits or when a coherent milestone is complete.
- Before committing:
  - Re-check `git status --short --branch` and confirm the branch is `Part2`.
  - Keep generated Vivado/Vitis artifacts out of Git unless the user explicitly asks for release artifacts.
  - Prefer committing source, constraints, scripts, and documentation needed to reproduce the milestone.
- Keep commit messages concise and stage-focused, for example `stage2: add qpsk rx demod debug flow`.

## Stage-2 Goal

Implement a PL-side QPSK demodulation path while preserving the current TX and BD structure.

Recommended first milestone:

1. Tap the RX sample stream after `ad9215_capture`.
2. Convert ADC unsigned samples to signed centered samples.
3. Run fixed-frequency DDC using the current carrier NCO increment `24'h11EB85` at 100 MHz.
4. Add basic recovery/quality logic, not only a same-clock toy decoder:
   - DC removal or slow average subtraction.
   - Coarse symbol timing phase selection across `SPS=50`.
   - Residual phase/decision tracking suitable for fixed-frequency local tests.
   - Hard QPSK decisions.
   - Lock/quality metric based on symbol stability or known Gray pattern for the local test mode.
5. Verify in simulation against the local Gray cycle `00 -> 01 -> 11 -> 10`.
6. Export two debug pins on J11 later if needed. Tentative mapping:
   - `rx_demod_bit` on J11 PIN3 / FPGA F17.
   - `rx_demod_lock` or `rx_demod_valid` on J11 PIN4 / FPGA F16.

Important design note: a fixed external carrier frequency does not remove the need for recovery. For external transmitters, residual carrier offset, phase offset, sample-clock drift, amplitude variation, and symbol timing offset still require at least a basic carrier/phase loop and timing recovery. Structure the first demod core so it can be upgraded toward a Costas/decision-directed phase loop and Gardner/early-late timing recovery.

## Likely Files To Add Or Touch

- Add RX demod RTL under `RTL/modem/`, for example:
  - `qpsk_rx_fixed_demod.v`
  - small helper modules if useful, but keep the first version simple and reviewable.
- Touch top-level integration:
  - `RTL/top/pl_comm_top.v`
  - `RTL/top/pl_comm_top_fixed_cfg.v`
- Add simulation:
  - `Sim/tb_qpsk_rx_demod_loopback.v` or a similarly named stage-2 testbench.
- Add or update Vivado batch scripts under `scripts/`.
- Add a J11 constraints file only when pin export is actually integrated.

## Vivado Batch Notes

Vivado version and path:

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl
```

Preflight result on 2026-06-09:

- Running the existing batch simulation inside the normal managed sandbox failed during `open_project`.
- Failure symptom:
  - `boost::filesystem::remove: 拒绝访问。: "D:\Project\ProjectVivado\Ez_QPSK\.\.hdi.isWriteableTest.<pid>.tmp"`
  - It left ignored `.hdi.isWriteableTest*.tmp` files in the repo root.
- Running the same command with escalated/sandbox-external execution succeeded in controlling Vivado:
  - Vivado opened `Ez_QPSK.xpr`.
  - IP repositories refreshed.
  - `sim_1` top was set.
  - XSim compile/elaborate/simulate launched.

For future automated work, run Vivado batch commands with escalation if the same `.hdi.isWriteableTest` permission failure appears. The command is not a code problem.

## PS / XSA / Vitis Notes

- Because the PL sample clock path depends on PS `FCLK_CLK0`, board bring-up needs PS initialization, not only raw PL bitstream download.
- A JTAG helper is available to initialize PS clocks before ILA capture:

```powershell
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/init_ps7_fclk.tcl
```

- Run this after programming PL, or run an equivalent FSBL/application flow, before trying to refresh Vivado ILA/debug hub. If PS `FCLK_CLK0` is not active, Vivado can program the FPGA but may report that the design has no supported debug core or that `dbg_hub` is not detected.
- After a PL milestone that affects the exported hardware, refresh the PS-side hardware platform:
  1. Set the intended board mode. For local analog loopback, use `loopback` (`FIXED_TX_EN=1`, `FIXED_RX_EN=1`, Gray TX). For local PRBS stress testing, use `loopback_prbs` (`FIXED_TX_EN=1`, `FIXED_RX_EN=1`, PRBS7 TX). For a purely external ADC source, use `external_rx` (`FIXED_TX_EN=0`, `FIXED_RX_EN=1`).
  2. Generate the matching bitstream when the PL image changed.
  3. Export/update XSA with `scripts/export_current_xsa.tcl`; use `-include-bit` only after the matching implementation bitstream is available.
  4. Rebuild or refresh the Vitis platform/application from that XSA.
- A command-line smoke test is available:

```powershell
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/test_vitis_xsa_build.tcl artifacts\xsa\Ez_QPSK_current.xsa Vitis_WS\codex_xsa_smoke_current
```

- The smoke test intentionally writes under ignored `Vitis_WS/`, regenerates standalone BSP/FSBL from the XSA, and links `sw/baremetal_dma_rx/main.c` into a temporary ELF.
- Vitis 2020.2 command-line `app create` / app-template discovery can hang in this environment; the smoke script avoids that path and uses the generated BSP plus ARM GCC directly.
- The generated standalone BSP should use `ps7_uart_1` for stdin/stdout when UART export is needed.
- A one-command board check is available for external-RX ILA capture plus decode thresholds:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1
```

- By default it programs `artifacts/external_rx/Ez_QPSK_external_rx.bit`, captures three ILA CSV files, and runs `Tool/python/decode_rx_demod_ila.py --check-external-rx` on each.
- For local analog PRBS loopback smoke, use `-Mode loopback_prbs`.
- The board check writes per-capture `*_summary.json` files and a multi-capture aggregate JSON, defaulting to `Tool/data/<mode>_board_check_aggregate_summary.json`; override with `-AggregateSummaryJson`.
- The decoder and board check now include coarse ADC spectral diagnostics. Defaults are centered at `7 MHz` with `4 MHz` width; override with Python `--adc-band-center-hz/--adc-band-width-hz` or PowerShell `-AdcBandCenterHz/-AdcBandWidthHz`.
- Optional ADC spectral gates are available for real external-source checks:
  - PowerShell: `-MinAdcAcRms <lsb> -MinAdcBandPowerRatio <ratio> -MinAdcPeakHz <hz> -MaxAdcPeakHz <hz>`
  - Python: `--min-adc-ac-rms <lsb> --min-adc-band-power-ratio <ratio> --min-adc-peak-hz <hz> --max-adc-peak-hz <hz>`
- For a real external source with known residual carrier direction, the board check and decoder now accept optional NCO gates:
  - PowerShell: `-ExpectNcoSign positive|negative|nonzero -MinNcoAbs <lsb> -MaxNcoAbs <lsb>`
  - Python: `--expect-nco-sign positive|negative|nonzero --min-nco-abs <lsb> --max-nco-abs <lsb>`
  - Do not enable these NCO gates by default for same-clock local loopback; its NCO correction can legitimately stay at zero.

## Board Bring-up Preference

- For the next hardware validation step, prefer local analog loopback first:
  `PL TX -> DAC -> external filter/analog path -> ADC -> PL RX demod`.
- This requires both DA and AD paths to be working and uses `loopback` mode with TX and RX enabled.
- Use `loopback_prbs` as the preferred random-symbol stress mode after Gray loopback. Current hardware evidence shows stable PRBS lock on the local analog path.
- After local analog loopback is stable, switch to `external_rx` mode for a separate external QPSK transmitter feeding the ADC.

Hardware result on 2026-06-10:

- JTAG detected one Digilent target and `xc7z020_1`.
- `scripts/run_external_rx_bitstream.tcl -tclargs loopback` generated `artifacts/loopback/Ez_QPSK_loopback.bit` and `.ltx`.
- Loopback implementation passed timing with setup slack `0.120 ns` and hold slack `0.027 ns`.
- Programming PL without PS clock initialization reached DONE but Vivado could not detect `dbg_hub`.
- After running `scripts/init_ps7_fclk.tcl`, Vivado detected one ILA core and captured `Tool/data/loopback_ila.csv`.
- `Tool/python/decode_rx_demod_ila.py Tool/data/loopback_ila.csv --check-gray-cycle` passed:
  - `lock_ratio=1`
  - `valid_count=20`
  - Gray-cycle best match ratio `1`
  - `adc_raw_span=794`
- `scripts/run_external_rx_bitstream.tcl -tclargs loopback_prbs` generated `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.bit` and `.ltx`.
- `loopback_prbs` implementation passed timing with setup slack `0.150 ns` and hold slack `0.060 ns`.
- Early PRBS board capture `Tool/data/local_prbs_loopback_ila_00..02.csv` showed ADC span about `886..971`, symbol entropy about `1.87..1.95` bits, and active hard decisions across all symbols, but `lock_ratio=0`; this was useful activity evidence before blind-lock tuning.
- After blind-lock tuning and powering the ADC rail, `loopback_prbs` was rebuilt:
  - `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.bit`
  - `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.ltx`
  - implementation timing passed with setup slack `0.297 ns` and hold slack `0.041 ns`
- Board captures `Tool/data/local_prbs_loopback_after_adc_power_ila_00..02.csv` decoded with `--check-external-rx` all passed:
  - `lock_ratio=1`
  - `lock_score=255`
  - `valid_count=20/20/21`
  - symbol entropy `1.88/1.95/1.88` bits
  - `adc_raw_span=907/892/909`
  - Gray-cycle match ratio stayed low (`0.40/0.40/0.43`), as expected for PRBS rather than the fixed Gray cycle
- After timing-pipeline cleanup in `qpsk_rx_fixed_demod.v`, `scripts/run_impl_check.tcl` now resets and rebuilds `synth_1` before `impl_1` so timing is checked against the current RTL, not a stale synthesis netlist.
- Latest `loopback_prbs` build on 2026-06-11 passed implementation timing with setup slack `0.199 ns` and hold slack `0.042 ns`, and refreshed:
  - `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.bit`
  - `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.ltx`
- Latest board captures after ADC power and the timing-clean bitstream also passed:
  - `Tool/data/local_prbs_loopback_latest_ila_00..02.csv`
  - `--check-external-rx` PASS for all three captures
  - `lock_ratio=1`, `lock_score=255`
  - `valid_count=20/21/20`
  - `symbol_entropy_when_valid_bits=1.97095/1.9699/1.95272`
  - `adc_raw_span=948/909/948`
- Post acquisition transition-gating `loopback_prbs` rebuild on 2026-06-11 also passed implementation timing with setup slack `0.151 ns` and hold slack `0.052 ns`, and refreshed:
  - `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.bit`
  - `artifacts/loopback_prbs/Ez_QPSK_loopback_prbs.ltx`
- Post-fix local analog PRBS board captures also passed:
  - `Tool/data/local_prbs_loopback_post_fix_ila_00..02.csv`
  - `--check-external-rx` PASS for all three captures
  - `lock_ratio=1`, `lock_score=255`
  - `valid_count=21/20/21`
  - `symbol_entropy_when_valid_bits=1.88417/1.98548/1.93871`
  - `adc_raw_span=964/1000/976`
  - ADC amplitude is close to full scale; if later captures show clipping, reduce analog gain before evaluating demod failures.
- `scripts/run_external_rx_bitstream.tcl -tclargs external_rx` generated `artifacts/external_rx/Ez_QPSK_external_rx.bit` and `.ltx`.
- `external_rx` implementation passed timing with setup slack `0.007 ns` and hold slack `0.048 ns`; setup is positive but very tight, so later carrier/timing-loop additions need timing attention.
- `scripts/export_current_xsa.tcl -tclargs -include-bit -out artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa` exported an XSA carrying the matching external-RX bitstream.
- `scripts/test_vitis_xsa_build.tcl artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa Vitis_WS/codex_xsa_smoke_external_rx` passed: Vitis regenerated the standalone BSP/FSBL and linked `sw/baremetal_dma_rx/main.c` into a smoke ELF.
- Latest `external_rx` rebuild on 2026-06-11 after acquisition transition-gating cleanup passed implementation timing with setup slack `0.169 ns` and hold slack `0.047 ns`, and refreshed:
  - `artifacts/external_rx/Ez_QPSK_external_rx.bit`
  - `artifacts/external_rx/Ez_QPSK_external_rx.ltx`
  - `artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa`
- `scripts/test_vitis_xsa_build.tcl artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa Vitis_WS/codex_xsa_smoke_external_rx_latest` passed for the refreshed XSA after the transition-gating rebuild.
- After adding lock-after Costas-like PI carrier trim on 2026-06-11, `scripts/run_impl_check.tcl` passed routed timing with setup slack `0.097 ns` and hold slack `0.047 ns`.
- The matching `external_rx` board image was refreshed with `scripts/run_external_rx_bitstream.tcl -tclargs external_rx`:
  - implementation/write_bitstream passed with setup slack `0.129 ns` and hold slack `0.047 ns`
  - refreshed `artifacts/external_rx/Ez_QPSK_external_rx.bit`
  - refreshed `artifacts/external_rx/Ez_QPSK_external_rx.ltx`
- The matching XSA was refreshed with `scripts/export_current_xsa.tcl -tclargs -include-bit -out artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa`.
- `scripts/test_vitis_xsa_build.tcl artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa Vitis_WS/codex_xsa_smoke_external_rx_costas` passed for the Costas-like PI external-RX XSA.
- Latest wide-acquisition `external_rx` rebuild on 2026-06-11 passed implementation/write_bitstream timing with setup slack `0.219 ns` and hold slack `0.042 ns`, and refreshed:
  - `artifacts/external_rx/Ez_QPSK_external_rx.bit`
  - `artifacts/external_rx/Ez_QPSK_external_rx.ltx`
  - `artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa`
- `scripts/test_vitis_xsa_build.tcl artifacts/xsa/Ez_QPSK_external_rx_with_bit.xsa Vitis_WS/codex_xsa_smoke_external_rx_wide_acq` passed for the refreshed wide-acquisition external-RX XSA.
- Programming the refreshed `external_rx` image and capturing ILA succeeded, but the current ADC input was only near-midscale noise:
  - `Tool/data/external_rx_latest_ila_00..02.csv`
  - `adc_raw_span=3/2/2`
  - `lock_ratio=0`
  - `i_mean_abs_when_valid` and `q_mean_abs_when_valid` were about `1`
  - This is expected if no separate external QPSK source is feeding the ADC, because `external_rx` disables local DAC TX.
- The new one-command board check reproduced the same current external-RX condition:
  - `scripts/check_external_rx_board.ps1 -Repeat 1`
  - `Tool/data/external_rx_board_check.csv`
  - `adc_raw_span=3`
  - `lock_ratio=0`
  - check failures: `lock_ratio 0 < 0.5`, `adc_raw_span 3 < 16`
  - This confirms the current blocker for true `external_rx` validation is missing/insufficient independent ADC input signal, not the capture/decode flow.
- `scripts/init_ps7_fclk.tcl` reported no APU/Cortex-A9 target during this run (`AHB AP transaction error`), but Vivado still captured ILA successfully, so the active FCLK/debug path was sufficient for the capture. If this repeats after a board reset, check PS power/reset/boot mode before relying on XSCT PS initialization.

## Simulation Status

`scripts/run_qpsk_tx_single_dac_sim.tcl` was repaired on 2026-06-09:

- `tb_qpsk_tx_single_dac_min` now checks `ad9762_driver` output on the correct negedge-to-posedge alignment.
- The CSV dump opens `qpsk_single_dac_samples_gray.csv` with a string literal, avoiding the prior invalid file descriptor warning.
- Failure messages are ASCII error IDs, avoiding garbled fixed-width UTF-8 display.
- The Tcl script scans `simulate.log`; `[TB_QPSK_TX_DAC][FAIL]` or missing `[TB_QPSK_TX_DAC][PASS]` exits nonzero.
- Verified command completed with `[TB_QPSK_TX_DAC][PASS]` at beat 50000.

Remaining note: the RTL modules still emit XSim timescale warnings because several source files do not declare a timescale. This is noisy but did not block the repaired simulation.

Stage-2 RX demod status on 2026-06-10/11:

- Random PRBS external-like simulation passed for `+15 kHz` residual carrier offset:
  - `scripts/run_qpsk_rx_demod_random_external_sim.tcl`
  - after lock-after Costas-like PI trim, lock near `nco_corr=2560`, final `nco_corr=2450`
  - `locked_symbols=360`
- Random PRBS external-like simulation passed for `-15 kHz` residual carrier offset:
  - `scripts/run_qpsk_rx_demod_random_external_neg_sim.tcl`
  - after lock-after Costas-like PI trim, lock near `nco_corr=-2560`, final `nco_corr=-2491`
  - `locked_symbols=360`
- Gray local loopback regression still passed:
  - `scripts/run_qpsk_rx_demod_loopback_sim.tcl`
  - `locked_symbols=160`
- Top-level external-RX simulation passed:
  - `scripts/run_pl_comm_top_external_rx_sim.tcl`
  - `FIXED_TX_EN=0`, `FIXED_RX_EN=1`
  - local DAC output stayed zero while external ADC PRBS samples demodulated
  - `locked_symbols=260`, `nco_corr=2560`
- Re-run on 2026-06-11 after timing-pipeline cleanup also passed:
  - `locked_symbols=260`, `valid_symbols=7621`, `nco_corr=2560`
- Re-run on 2026-06-11 after lock-after Costas-like PI carrier trim also passed:
  - positive offset: `locked_symbols=260`, `valid_symbols=7621`, `nco_corr=2487`
  - negative offset: `locked_symbols=260`, `valid_symbols=7863`, `nco_corr=-2502`
- Top-level external-RX negative-offset simulation now passes after requiring acquisition candidates to include stable adjacent-symbol transitions:
  - `scripts/run_pl_comm_top_external_rx_neg_sim.tcl`
  - `locked_symbols=260`, `valid_symbols=7863`, `nco_corr=-2560`
- Latest wide-offset random PRBS simulations passed after expanding the coarse acquisition sweep to `±8192` NCO correction units and changing acquisition scoring to reward fine-quality symbol transitions while penalizing bad transitions:
  - `scripts/run_qpsk_rx_demod_random_external_wide_sim.tcl`
  - `+35 kHz`: `locked_symbols=360`, `valid_symbols=9847`, final `nco_corr=6007`
  - `scripts/run_qpsk_rx_demod_random_external_wide_neg_sim.tcl`
  - `-35 kHz`: `locked_symbols=360`, `valid_symbols=9628`, final `nco_corr=-5768`
- Latest post-lock carrier-drift random PRBS simulations passed:
  - `scripts/run_qpsk_rx_demod_random_external_drift_sim.tcl`
  - residual carrier drifts from `+15 kHz` to `+35 kHz` after lock
  - `locked_symbols=3200`, `valid_symbols=12589`, final `nco_corr=5715`
  - `scripts/run_qpsk_rx_demod_random_external_drift_neg_sim.tcl`
  - residual carrier drifts from `-15 kHz` to `-35 kHz` after lock
  - `locked_symbols=3200`, `valid_symbols=12976`, final `nco_corr=-5797`
- Latest standard random PRBS simulations passed with lock-settle checker hardening:
  - `scripts/run_qpsk_rx_demod_random_external_sim.tcl`
  - `+15 kHz`: `locked_symbols=360`, `valid_symbols=9749`, final `nco_corr=2552`
  - `scripts/run_qpsk_rx_demod_random_external_neg_sim.tcl`
  - `-15 kHz`: `locked_symbols=360`, `valid_symbols=10136`, final `nco_corr=-2316`
- Latest top-level external-RX simulations passed with the same lock-settle checker hardening:
  - `scripts/run_pl_comm_top_external_rx_sim.tcl`
  - `+15 kHz`: `locked_symbols=260`, `valid_symbols=9413`, final `nco_corr=2515`
  - `scripts/run_pl_comm_top_external_rx_neg_sim.tcl`
  - `-15 kHz`: `locked_symbols=260`, `valid_symbols=9807`, final `nco_corr=-2307`
- Latest top-level external-RX wide-offset simulations passed:
  - `scripts/run_pl_comm_top_external_rx_wide_sim.tcl`
  - `+35 kHz`: `locked_symbols=260`, `valid_symbols=9557`, final `nco_corr=5773`
  - `scripts/run_pl_comm_top_external_rx_wide_neg_sim.tcl`
  - `-35 kHz`: `locked_symbols=260`, `valid_symbols=9491`, final `nco_corr=-5767`
- Latest top-level external-RX post-lock carrier-drift simulations passed:
  - `scripts/run_pl_comm_top_external_rx_drift_sim.tcl`
  - residual carrier drifts from `+15 kHz` to `+35 kHz` after lock
  - `locked_symbols=3200`, `valid_symbols=12353`, final `nco_corr=5708`
  - `scripts/run_pl_comm_top_external_rx_drift_neg_sim.tcl`
  - residual carrier drifts from `-15 kHz` to `-35 kHz` after lock
  - `locked_symbols=3200`, `valid_symbols=12747`, final `nco_corr=-5803`
- The current blind-lock logic is intentionally conservative: it waits longer before blind acquisition, scans coarse NCO correction candidates, suppresses blind score accumulation immediately after phase-bin movement, avoids first-round lock on small coarse-frequency candidates, scores acquisition candidates by transition quality rather than raw transition count, and uses a stricter post-scan fine-quality path before blind lock. This prevents the observed early false lock in random/PRBS tests while preserving the known Gray-cycle path.
- Open carrier-recovery note: the latest fixed-frequency positive/negative PRBS simulations now include lock-after Costas-like PI NCO fine trim and pass the `±35 kHz` plus post-lock `+15 kHz -> +35 kHz` / `-15 kHz -> -35 kHz` drift simulation stress cases, but this is still not a full Costas/Gardner synchronizer. A future non-data-aided or stronger lock-before frequency estimator plus stronger timing recovery should replace the current coarse acquisition path before claiming broad arbitrary external-transmitter tolerance.

## Suggested Goal-Mode Execution Plan

1. Re-check `git status --short --branch`.
2. Run a Vivado batch smoke test with escalation if needed.
3. Use the repaired TX simulation script as a smoke test before adding RX demodulation.
4. Design the RX demod module with fixed 100 MHz / 7 MHz / `SPS=50` parameters and basic recovery hooks.
5. Add a focused loopback testbench that validates recovered QPSK symbols.
6. Run the new simulation in Vivado batch and make the script fail nonzero on `[FAIL]`.
7. Run synthesis, then implementation/timing if simulation passes.
8. Export/update XSA and run the Vitis smoke test when the milestone will be used on board.
9. Update README/Sim/sw docs only with concise stage-2 usage notes.
