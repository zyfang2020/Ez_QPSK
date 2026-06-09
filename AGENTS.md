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
- After a PL milestone that affects the exported hardware, refresh the PS-side hardware platform:
  1. Set the intended board mode. For local analog loopback, use `loopback` (`FIXED_TX_EN=1`, `FIXED_RX_EN=1`). For a purely external ADC source, use `external_rx` (`FIXED_TX_EN=0`, `FIXED_RX_EN=1`).
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

## Board Bring-up Preference

- For the next hardware validation step, prefer local analog loopback first:
  `PL TX -> DAC -> external filter/analog path -> ADC -> PL RX demod`.
- This requires both DA and AD paths to be working and uses `loopback` mode with TX and RX enabled.
- After local analog loopback is stable, switch to `external_rx` mode for a separate external QPSK transmitter feeding the ADC.

## Simulation Status

`scripts/run_qpsk_tx_single_dac_sim.tcl` was repaired on 2026-06-09:

- `tb_qpsk_tx_single_dac_min` now checks `ad9762_driver` output on the correct negedge-to-posedge alignment.
- The CSV dump opens `qpsk_single_dac_samples_gray.csv` with a string literal, avoiding the prior invalid file descriptor warning.
- Failure messages are ASCII error IDs, avoiding garbled fixed-width UTF-8 display.
- The Tcl script scans `simulate.log`; `[TB_QPSK_TX_DAC][FAIL]` or missing `[TB_QPSK_TX_DAC][PASS]` exits nonzero.
- Verified command completed with `[TB_QPSK_TX_DAC][PASS]` at beat 50000.

Remaining note: the RTL modules still emit XSim timescale warnings because several source files do not declare a timescale. This is noisy but did not block the repaired simulation.

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
