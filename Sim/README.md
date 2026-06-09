# Sim

本目录存放 Ez_QPSK 的 Vivado/XSim testbench，用于验证发送、接收搬运、顶层数字回环和 stage-2 RX 在线解调 loopback。

## 仿真入口

- `tb_tx_chain_min.v`：测试 `tx_test_pattern -> ad9762_driver` 最小 TX 链路。
- `tb_rx_chain_min.v`：测试 `ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt` RX 搬运链路。
- `tb_qpsk_tx_chain_min.v`：legacy QPSK I/Q 交织发射链验证。
- `tb_qpsk_tx_single_dac_min.v`：推荐单 DAC QPSK 发射链验证，可导出 `qpsk_single_dac_samples_gray.csv`。
- `tb_qpsk_rx_demod_loopback.v`：本地 TX loopback 到 PL 侧 QPSK 在线解调验证，检查 Gray 循环恢复与 lock。
- `tb_pl_comm_top_fixed_cfg_loopback.v`：顶层无板数字回环验证，检查 RX AXIS 数据、`tkeep`、`tlast` 和回压保持行为。

## 运行方式

当前批处理脚本：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_loopback_sim.tcl
```

这些脚本会打开工程根目录下的 `Ez_QPSK.xpr`，设置对应 testbench 为仿真顶层并运行到 testbench 结束。

如果是干净 Git checkout，先按根目录 `README.md` 中的“从 Git 节点恢复 Vivado 工程”运行 `scripts/rebuild_project_current.tcl`，生成 `Ez_QPSK.xpr` 后再运行仿真脚本。

## 通过判据

各 testbench 出现 `[PASS]` 日志并正常 `$finish` 即表示该入口通过。出现 `[FAIL]` 日志时，testbench 会打印失败原因并结束。

当前重点入口：

1. `tb_qpsk_tx_single_dac_min.v`：确认单 DAC QPSK 发射链持续输出有效采样、无 X/Z、输出范围合法，并生成离线解调 CSV。
2. `tb_qpsk_rx_demod_loopback.v`：确认新增 PL 侧 RX demod 支路能在本地 TX loopback 下锁定并连续恢复 Gray 符号。
3. `tb_rx_chain_min.v`：确认 RX 链路数据连续性和固定包长 `tlast` 节奏。
4. `tb_pl_comm_top_fixed_cfg_loopback.v`：确认顶层固定配置下 AXIS 数据、`tkeep`、`tlast` 和回压保持行为正确。

## 后处理

单 DAC 仿真导出的 CSV 可用：

```matlab
Tool/matlab/qpsk_single_dac_demod_demo.m
```

该脚本读取 XSim 输出目录中的 `qpsk_single_dac_samples_gray.csv` 或 `qpsk_single_dac_samples.csv`，做最小离线解调演示。
