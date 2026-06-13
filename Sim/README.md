# Sim

本目录存放 Ez_QPSK 的 Vivado/XSim testbench，用于验证 TX、RX 原始搬运、顶层数字回环和 stage-2 RX 在线解调。

## Testbench 入口

- `tb_tx_chain_min.v`：验证 `tx_test_pattern -> ad9762_driver` 最小 TX 链路。
- `tb_rx_chain_min.v`：验证 `ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt` RX 搬运链路。
- `tb_qpsk_tx_single_dac_min.v`：推荐单 DAC QPSK 发射链验证，可导出 `qpsk_single_dac_samples_gray.csv`。
- `tb_qpsk_rx_demod_loopback.v`：本地 TX loopback 到 PL 侧 QPSK 在线解调，检查 Gray 循环恢复与 lock。
- `tb_qpsk_rx_demod_impairments.v`：直接生成带相位偏移、`3 kHz` 残余频偏、符号相位偏移和 ADC DC 的 QPSK 输入，验证 RX 恢复余量。
- `tb_qpsk_rx_demod_external_drift.v`：直接生成独立 `2.010 Msym/s` 外部 QPSK 输入，按 TX 参考校验 RX 是否跟随符号钟漂移。
- `tb_qpsk_rx_demod_random_external.v`：直接生成 PRBS QPSK 外部输入，覆盖独立符号率、`+15 kHz/-15 kHz`、宽频偏、锁后载波漂移、慢幅度/DC 漂移和 ADC 采样噪声；`QPSK_RX_RANDOM_LATE_START` 宏用于信号延迟出现的重捕获回归。
- `tb_pl_comm_top_external_rx.v`：顶层 external RX 模式验证，检查 `FIXED_TX_EN=0/FIXED_RX_EN=1` 下 TX 回零、J11 debug 输出、外部 ADC 输入解调和 NCO 校正方向。
- `tb_pl_comm_top_fixed_cfg_loopback.v`：顶层无板数字回环验证，检查 RX AXIS 数据、`tkeep`、`tlast` 和回压保持行为。

## 运行方式

推荐通过 `scripts/` 下的批处理脚本运行仿真；脚本清单见 `scripts/README.md`。

常用 smoke 入口：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_loopback_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_sim.tcl
```

这些脚本会打开工程根目录下的 `Ez_QPSK.xpr`，设置对应 testbench 为仿真顶层，并运行到 testbench 结束。干净 checkout 后应先按根目录 `README.md` 的工程恢复说明生成 `Ez_QPSK.xpr`。

## 通过判据

- testbench 打印 `[PASS]` 并正常 `$finish` 表示该入口通过。
- testbench 打印 `[FAIL]` 时会给出失败原因；对应批处理脚本应返回非零退出码。
- XSim timescale warnings 目前属于已知噪声，不单独作为失败依据。

## 后处理

单 DAC 仿真导出的 CSV 可用以下 Matlab 脚本做最小离线解调演示：

```matlab
Tool/matlab/qpsk_single_dac_demod_demo.m
```
