# baremetal_dma_rx

最小 Zynq 裸机示例，用于验证：

`pl_comm_top_fixed_cfg/m_axis_rx -> axi_dma(S2MM) -> PS DDR`

## 文件

- `main.c`
  - 最小 DMA S2MM 接收示例
  - 轮询方式等待 DMA 完成
  - 完成后打印前若干个 16-bit 样本

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
   - 先用一个固定长度做 bring-up
   - 应与 PL 侧一次 DMA 接收预期长度一致

## 初次上板建议

1. 先只接收一包固定长度数据
2. 串口打印前 16~32 个样本
3. 确认 DMA 不报错、传输完成、数据非全 0/全常数
4. 再扩展为多包接收或连续采集
