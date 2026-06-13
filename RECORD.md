# Ez_QPSK 阶段记录

本文件保存阶段性调试、仿真、实现和硬件 bring-up 的时间线记录。它不是操作手册；日常使用请看 `README.md`、`scripts/README.md`、`Sim/README.md` 和 `Tool/README.md`。

## 2026-06-09

- 修复 `scripts/run_qpsk_tx_single_dac_sim.tcl` 相关 TX 单 DAC 仿真流程。
- `tb_qpsk_tx_single_dac_min` 改为按正确 negedge-to-posedge 对齐检查 `ad9762_driver` 输出。
- CSV dump 改为使用字符串字面量打开 `qpsk_single_dac_samples_gray.csv`，避免无效 file descriptor warning。
- Tcl 脚本扫描 `simulate.log`，出现 `[TB_QPSK_TX_DAC][FAIL]` 或缺失 `[TB_QPSK_TX_DAC][PASS]` 时返回非零。
- Vivado 批处理在托管沙箱里曾因 `.hdi.isWriteableTest*.tmp` 权限失败；提升权限后同类命令可正常控制 Vivado。

## 2026-06-10

- Stage-2 RX demod 初版打通：
  - 新增 PL 侧 `qpsk_rx_fixed_demod` online demod 支路。
  - 本地 TX loopback 仿真可恢复 Gray cycle `00 -> 01 -> 11 -> 10`。
  - 带相位偏移、`3 kHz` 残余频偏、符号相位偏移和 ADC DC 的扰动仿真通过。
- 上板本地 loopback：
  - `scripts/run_external_rx_bitstream.tcl -tclargs loopback` 生成 `artifacts/loopback/Ez_QPSK_loopback.bit/.ltx`。
  - 只烧 PL 时 Vivado 能到 DONE，但 PS/FCLK 未初始化导致 `dbg_hub` / ILA 不可见。
  - 初始化 PS/FCLK 后 Vivado 检测到 ILA，`Tool/python/decode_rx_demod_ila.py --check-gray-cycle` 通过，`lock_ratio=1`。
- 初始 `loopback_prbs` 硬件预检显示 ADC 与符号活动正常，但早期 blind-lock 尚未稳定，后续继续调参。

## 2026-06-11

- `loopback_prbs` 本地模拟回环稳定：
  - ADC rail 供电和 blind-lock 调整后，多次 ILA 抓取均通过 `--check-external-rx`。
  - `lock_ratio=1`，`lock_score=255`，符号熵接近随机 PRBS 预期。
  - 本地模拟链路 ADC 幅度接近满量程，后续若削顶需先降低模拟增益或发射幅度。
- external RX 仿真与实现推进：
  - 顶层 `external_rx` 正/负频偏仿真通过，确认 TX 关闭时 DAC 回零，外部 ADC PRBS 输入可被 demod 锁定。
  - 增加 Costas-like PI NCO 细调后，`+15 kHz/-15 kHz` 残余频偏随机 PRBS 和顶层 external RX 仿真通过。
  - 扩大 coarse acquisition sweep 到 `±8192` NCO correction，宽频偏 `+35 kHz/-35 kHz` 仿真通过。
  - 锁后载波漂移 `+15 kHz -> +35 kHz`、`-15 kHz -> -35 kHz` 仿真通过。
- implementation / artifacts：
  - `run_impl_check.tcl` 改为 reset 并重建 `synth_1` 后再跑 `impl_1`，避免用 stale synthesis netlist 检查 timing。
  - `external_rx`、`loopback_prbs` 等 profile 多次刷新 bit/.ltx/XSA，并通过 Vitis XSA smoke build。
- external RX 空输入诊断：
  - 在没有独立外部 QPSK 源输入时，external RX 抓取只看到 near-midscale noise，ADC span 约个位数，`lock_ratio=0`。
  - 新增 `check_external_rx_board.ps1 -SignalOnly` 和 `wait_external_rx_signal.ps1`，先判断 ADC 输入活动，再进入完整 demod 检查。

## 2026-06-12

- 两板角色确认：
  - 板 A：原 AX7020 风格接口板，作为 TX，FPGA DNA `3A1691221322147B`。
  - 板 B：新 HS 接口板，作为 RX，FPGA DNA `3A16927471382023`。
  - Digilent cable serial `210512180081` 随下载器移动，不能作为板卡身份依据。
- 新 HS 接口 RX bring-up：
  - 纯 Vivado 烧入 `new_interface_rx` 后 PL DONE，但 PS/FCLK 未运行时 ILA 不可见。
  - 用户通过 Vitis 选择接收端 bit 并初始化 PS/FCLK 后，使用 `check_external_rx_board.ps1 -Mode new_interface_rx -NoProgram` 抓取通过。
  - SignalOnly 和完整 demod check 均通过；Board B ADC 输入活跃，频谱集中在 7 MHz 附近，demod lock 稳定。
- 板 A TX / Vitis batch：
  - 发现早先 Vitis launch 曾指向旧 `zynq_dma` bit，导致 PS DMA 程序与当前 PL/BD 状态不匹配。
  - 改为匹配 `artifacts/original_tx_prbs/Ez_QPSK_original_tx_prbs.bit` 后，Vitis 生成的 debug Tcl batch flow 可复刻 GUI 行为，运行后 Vivado 能看到 ILA。
- 两板链路建议：
  - 板 A 跑 `original_tx_prbs`，板 B 跑 `new_interface_rx`。
  - 若 Vitis 已初始化 RX 端 PS/FCLK，后续抓 ILA 优先加 `-NoProgram`。
  - 如果 `-SignalOnly` 仍只有近中点小噪声，优先按物理输入/模拟链路问题处理。

## 2026-06-13

- `qpsk_rx_fixed_demod.v` re-acquisition cleanup：
  - 将原先依赖 16-bit `sym_count` 回绕的隐式重捕获，改为 `blind_delay_done` latch + `reacq_timeout_cnt` watchdog。
  - 完整 coarse sweep 应用最佳候选后，如果在 `REACQ_TIMEOUT_SYMS=1024` symbol 内未达到 blind lock，会重启整个 coarse sweep。
  - 清理 unreachable ternary arm、未使用 blind-quality wires、重复 reset body，并增加 `ADC_DW != 10` 仿真期 `$error` guard。
- 新增 late-start regression：
  - `scripts/run_qpsk_rx_demod_late_start_sim.tcl`
  - `QPSK_RX_RANDOM_LATE_START` 模式下前 600k samples 只有 DC+noise，首轮 blind sweep 必须在噪声上失败，再由 watchdog 重扫后锁定。
  - 本地运行通过，约 9.4 ms 取得 blind lock，最终 `[TB_QPSK_RX_RANDOM][PASS]`。
- 文档结构整理：
  - 根 `README.md` 精简为用户向项目入口。
  - `scripts/README.md` 承接脚本清单和 artifacts 产物说明。
  - `AGENTS.md` 精简为 AI 指令与避坑手册。
  - 新增本 `RECORD.md` 保存调试时间线。
