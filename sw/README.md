# PS Software Layout

`sw/` 用于存放 PS 端或配套软件源码，和 `RTL/`、`Sim/` 等硬件/仿真目录分开管理。

当前阶段建议把“板端最小 DMA 接收验证”作为第一优先级，先完成：

1. PS 初始化 AXI DMA S2MM
2. DDR 缓冲区接收一包 PL 侧 RX AXIS 数据
3. 串口打印前若干个样本，确认包长、数据和 `tlast` 对齐关系

## 当前目录规划

- `sw/baremetal_dma_rx/`
  - Zynq PS 裸机最小接收示例
  - 用于板卡到手后的第一阶段 bring-up
  - 目标是验证 `PL RX AXIS -> AXI DMA S2MM -> PS DDR`

## 推荐使用方式

1. 在 Vivado 中完成 bitstream / hardware export
2. 在 Vitis 中创建 standalone 平台工程
3. 将本目录下的 `main.c` 作为应用入口拷入或直接加入工程
4. 根据导出的 `xparameters.h` 核对 DMA 设备号、DDR 地址范围和 UART 输出
5. 下载运行，观察串口输出

## 当前边界

- 这里先只做“最小裸机 DMA 接收”
- 暂不引入在线解调
- 暂不引入 Linux / PetaLinux
- 暂不引入网口发送

等板端最小接收验证稳定后，再继续加：

1. 连续采集
2. 数据导出
3. 网口发送
4. 在线解调
