# baremetal_dma_rx

最小 Zynq 裸机示例，用于验证：

`pl_comm_top_fixed_cfg/m_axis_rx -> axi_dma(S2MM) -> PS DDR`

## 文件

- `main.c`
  - 最小 DMA S2MM 接收示例
  - 轮询方式等待 DMA 完成
  - 当前默认每帧按 `PKT_LEN=100000` 样本抓取
  - 当前默认配置下 `UART_EXPORT_SAMPLES == DMA_PKT_SAMPLES`，因此每帧发起 `1` 次 DMA simple transfer
  - `main.c` 会在 `while (1)` 中连续抓帧，并把每帧通过 UART 导出到 PC
  - 每帧采集前对 RX 区做一次 cache 准备
  - 导出前会把每个样本强制掩成低 `10` 位有效、高位清零
  - 通过当前 `stdout` 绑定的 UART 发送二进制帧到 PC

## 接入说明

该示例依赖 Xilinx BSP 头文件：

- `xparameters.h`
- `xaxidma.h`
- `xil_cache.h`
- `xil_printf.h`
- `sleep.h`

这些文件由 Vitis standalone 平台自动提供，不需要手工放进本仓库。

## 需要按板端核对的项目

1. `DMA_DEV_ID`
   - 默认示例使用 `XPAR_AXIDMA_0_DEVICE_ID`
   - 以实际 `xparameters.h` 为准
2. `RX_BUF_ADDR`
   - 必须落在可用 DDR 区域
   - 且避免覆盖程序、栈和 BSS
3. `RX_LEN_BYTES`
   - AXI DMA simple mode 下每次 transfer 长度必须与 PL 侧 `TLAST` 包长一致
   - 当前工程按 `PKT_LEN=100000` 样本接收一个 DMA 包
4. `stdout`
   - 需要在 Vitis standalone BSP 里绑定到 `ps7_uart_1`
   - 否则二进制帧会发到 JTAG DCC，而不是板载串口
5. `AXI DMA buffer length width`
   - `100000` 个 `u16` 样本等于 `200000` 字节
   - 当前 `scripts/rebuild_project_current.tcl` 中 `CONFIG.c_sg_length_width {23}` 足够覆盖这个长度

## 当前推荐流程

1. PL 侧保持 `PKT_LEN=100000`
2. PS 侧每帧接收 `1` 个 DMA 包，共 `100000` 个容器样本
3. `main.c` 会连续抓帧；初次验证时建议 PC 端只接收 `1` 帧
4. 抓包完成后把这一整帧导出到 PC 做离线解调
5. 在 PC 侧检查 `sample_count=100000`，且高 `6` 位应全部为 `0`
6. 如果只想做单次抓取，可让 PC 端脚本使用 `--frames 1`，或在 `main.c` 中临时把外层 `while (1)` 改为单次执行
7. 如果这样仍然错位，再去怀疑上板时序、ADC 采样边沿或更底层的数据稳定性

## 关于“乒乓缓冲”是否合适

- 对“边采边处理”来说，乒乓缓冲是对的方向
- 但当前工程里的 AXI DMA 是 `simple mode`，同一时刻只能挂一个 S2MM transfer
- 所以软件层面的乒乓只能帮助你在处理 `bufA` 时尽快重 arm `bufB`，不能消掉包与包之间天然存在的 re-arm gap
- 当前程序虽然会连续抓帧并持续 UART streaming，但每帧之间仍然存在 simple mode 重新 arm 的空窗
- 默认每帧只抓 `100000` 样本，至少能先把单包数据链路验证清楚；连续无缝采集不是当前程序的承诺
- 如果你的目标是连续、无缝抓流，真正有效的方案是：
  - AXI DMA 改 `SG mode` 并做 BD ring / cyclic
  - 或者在 PL 侧继续加深 FIFO，并补充停流/复位同步控制

## 初次上板建议

1. 先只接收一包固定长度数据
2. 串口打印前 16~32 个样本
3. 确认 DMA 不报错、传输完成、数据非全 0/全常数
4. 用 PC 端 `--frames 1` 接收一帧二进制数据并检查元信息
5. 再扩展为多包接收或连续采集

## UART 导出协议

- 帧头 magic：`QPSKDMA1`（8 字节 ASCII）
- 后续字段：4 个小端 `u32`
- 字段顺序：`version`、`sample_count`、`payload_bytes`、`checksum`
- 负载：`sample_count` 个小端 `u16` 原始样本
- `checksum`：所有 `u16` 样本按无符号求和后截断到 `u32`

## PC 端接收

- 配套脚本：`Tool/python/uart_capture_qpsk.py`
- 示例：
  - `python Tool/python/uart_capture_qpsk.py --port COM5`
  - `python Tool/python/uart_capture_qpsk.py --port /dev/ttyUSB0 --baud 115200`
  - `python Tool/python/uart_capture_qpsk.py --port COM5 --frames 1`
