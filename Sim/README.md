# Sim

本目录存放 Ez_QPSK 的 Vivado/XSim testbench，用于验证发送、接收搬运、顶层数字回环和 stage-2 RX 在线解调。

## 仿真入口

- `tb_tx_chain_min.v`：测试 `tx_test_pattern -> ad9762_driver` 最小 TX 链路。
- `tb_rx_chain_min.v`：测试 `ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt` RX 搬运链路。
- `tb_qpsk_tx_chain_min.v`：legacy QPSK I/Q 交织发射链验证。
- `tb_qpsk_tx_single_dac_min.v`：推荐单 DAC QPSK 发射链验证，可导出 `qpsk_single_dac_samples_gray.csv`。
- `tb_qpsk_rx_demod_loopback.v`：本地 TX loopback 到 PL 侧 QPSK 在线解调验证，检查 Gray 循环恢复与 lock。
- `tb_qpsk_rx_demod_impairments.v`：直接生成带相位偏移、`3 kHz` 残余频偏、符号相位偏移和 ADC DC 的 QPSK 输入，验证进阶 RX 恢复余量。
- `tb_qpsk_rx_demod_external_drift.v`：直接生成独立 `2.010 Msym/s` 外部 QPSK 输入，按 TX 参考校验 RX 是否跟随符号钟漂移。
- `tb_qpsk_rx_demod_random_external.v`：直接生成独立符号率、带 `+15 kHz/-15 kHz`、宽压测 `+35 kHz/-35 kHz` 和锁后 `+15 kHz -> +35 kHz` / `-15 kHz -> -35 kHz` 漂移的残余载波偏差、慢幅度/DC 漂移和 ADC 采样噪声的 PRBS QPSK 输入，验证无 Gray 循环先验时的锁前频偏扫描、盲锁、锁后 NCO 频偏微调和符号恢复。
- `tb_pl_comm_top_external_rx.v`：顶层 external RX 模式验证，检查 `FIXED_TX_EN=0/FIXED_RX_EN=1` 下 TX 回零、J11 debug 输出、`+15 kHz/-15 kHz` 与宽压测 `+35 kHz/-35 kHz` NCO 频偏方向和外部 ADC 输入解调。
- `tb_pl_comm_top_fixed_cfg_loopback.v`：顶层无板数字回环验证，检查 RX AXIS 数据、`tkeep`、`tlast` 和回压保持行为。

## 运行方式

当前批处理脚本：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_loopback_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_impairments_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_external_drift_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_neg_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_wide_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_wide_neg_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_drift_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_drift_neg_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_neg_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_wide_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_wide_neg_sim.tcl
```

这些脚本会打开工程根目录下的 `Ez_QPSK.xpr`，设置对应 testbench 为仿真顶层并运行到 testbench 结束。

如果是干净 Git checkout，先按根目录 `README.md` 中的“从 Git 节点恢复 Vivado 工程”运行 `scripts/rebuild_project_current.tcl`，生成 `Ez_QPSK.xpr` 后再运行仿真脚本。

## 通过判据

各 testbench 出现 `[PASS]` 日志并正常 `$finish` 即表示该入口通过。出现 `[FAIL]` 日志时，testbench 会打印失败原因并结束。

当前重点入口：

1. `tb_qpsk_tx_single_dac_min.v`：确认单 DAC QPSK 发射链持续输出有效采样、无 X/Z、输出范围合法，并生成离线解调 CSV。
2. `tb_qpsk_rx_demod_loopback.v`：确认新增 PL 侧 RX demod 支路能在本地 TX loopback 下锁定并连续恢复 Gray 符号。
3. `tb_qpsk_rx_demod_impairments.v`：确认 RX demod 对固定相位偏移、`3 kHz` 残余频偏、符号采样相位偏移和 ADC DC 仍能锁定。
4. `tb_qpsk_rx_demod_external_drift.v`：确认 RX demod 对独立外部符号率漂移仍能跟随真实 TX Gray 序列。
5. `tb_qpsk_rx_demod_random_external.v`：确认 RX demod 不依赖本地 Gray 循环也能盲锁并恢复带 `+15 kHz/-15 kHz`、宽压测 `+35 kHz/-35 kHz` 和锁后 `+15 kHz -> +35 kHz` / `-15 kHz -> -35 kHz` 漂移的残余载波偏差、慢幅度/DC 漂移和 ADC 采样噪声的 PRBS QPSK 符号。
6. `tb_pl_comm_top_external_rx.v`：确认顶层固定配置在外部 RX 模式下关闭本地 TX，并通过 J11 debug 输出外部输入的 lock/bit；正负频偏和宽频偏脚本分别检查 NCO 校正方向。
7. `tb_rx_chain_min.v`：确认 RX 链路数据连续性和固定包长 `tlast` 节奏。
8. `tb_pl_comm_top_fixed_cfg_loopback.v`：确认顶层固定配置下 AXIS 数据、`tkeep`、`tlast` 和回压保持行为正确。

最近验证：

- 2026-06-11：新增顶层 external-RX 宽频偏回归，`run_pl_comm_top_external_rx_wide_sim.tcl` 和 `run_pl_comm_top_external_rx_wide_neg_sim.tcl` 均通过。正向 `+35 kHz`：`locked_symbols=260`，`valid_symbols=9557`，最终 `nco_corr=5773`；负向 `-35 kHz`：`locked_symbols=260`，`valid_symbols=9491`，最终 `nco_corr=-5767`。
- 2026-06-11：新增正/负锁后载波漂移回归，在随机 PRBS 外部输入已锁后把残余载波从 `+15 kHz` 漂到 `+35 kHz`、从 `-15 kHz` 漂到 `-35 kHz`；仿真均通过。正向：`locked_symbols=3200`，`valid_symbols=12589`，最终 `nco_corr=5715`；负向：`locked_symbols=3200`，`valid_symbols=12976`，最终 `nco_corr=-5797`。
- 2026-06-11：扩大锁前扫描范围到 `±8192` NCO correction，并把候选评分改为“跳变机会中 fine 相位质量加分、坏跳变扣分”后，`run_qpsk_rx_demod_random_external_wide_sim.tcl` 和 `run_qpsk_rx_demod_random_external_wide_neg_sim.tcl` 均通过，覆盖 `+35 kHz/-35 kHz` 残余载波偏差。宽正频偏：`locked_symbols=360`，`valid_symbols=9847`，`nco_corr=6007`；宽负频偏：`locked_symbols=360`，`valid_symbols=9628`，`nco_corr=-5768`。
- 2026-06-11：随机外部和顶层 external-RX checker 增加 lock 后 settle 窗口和 32 符号 PRBS 校准，避免刚到 lock 阈值时环路尚未完全稳定造成校准误判。最新 `run_qpsk_rx_demod_random_external_sim.tcl` / `_neg_sim.tcl` 均通过；最新 `run_pl_comm_top_external_rx_sim.tcl` / `_neg_sim.tcl` 均通过。
- 2026-06-11：锁后 Costas-like PI 载波细调加入后，`run_qpsk_rx_demod_loopback_sim.tcl`、`run_qpsk_rx_demod_random_external_sim.tcl`、`run_qpsk_rx_demod_random_external_neg_sim.tcl`、`run_pl_comm_top_external_rx_sim.tcl` 和 `run_pl_comm_top_external_rx_neg_sim.tcl` 均通过。顶层正频偏：`locked_symbols=260`，`valid_symbols=7621`，`nco_corr=2487`；顶层负频偏：`locked_symbols=260`，`valid_symbols=7863`，`nco_corr=-2502`。
- 2026-06-11：`run_pl_comm_top_external_rx_sim.tcl` 和 `run_pl_comm_top_external_rx_neg_sim.tcl` 在 acquisition transition-gating 调整后均通过。正频偏：`locked_symbols=260`，`valid_symbols=7621`，`nco_corr=2560`；负频偏：`locked_symbols=260`，`valid_symbols=7863`，`nco_corr=-2560`。
- 2026-06-10：`run_qpsk_rx_demod_random_external_sim.tcl` 和 `run_qpsk_rx_demod_random_external_neg_sim.tcl` 均通过，覆盖 PRBS QPSK、`+15 kHz/-15 kHz` 残余载波偏差、慢幅度/DC 漂移、噪声和独立符号率漂移。
- 2026-06-10：`run_qpsk_rx_demod_loopback_sim.tcl` 回归通过，确认本地 Gray loopback 未受 PRBS 盲锁调参影响。
- 2026-06-10：`run_pl_comm_top_external_rx_sim.tcl` 通过，确认顶层 `external_rx` 模式下 DAC 保持关闭，外部 ADC PRBS 输入可经 J11/debug 路径观察到稳定 lock。

## 后处理

单 DAC 仿真导出的 CSV 可用：

```matlab
Tool/matlab/qpsk_single_dac_demod_demo.m
```

该脚本读取 XSim 输出目录中的 `qpsk_single_dac_samples_gray.csv` 或 `qpsk_single_dac_samples.csv`，做最小离线解调演示。
