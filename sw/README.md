# PS Software Layout

`sw/` 用于存放 PS 端或配套软件源码，和 `RTL/`、`Sim/` 等硬件/仿真目录分开管理。

当前阶段 PL 在线解调和两板外部输入已通过 ILA 路径验证。PS 侧软件目前主要承担三类辅助作用：

1. 初始化 PS7/FCLK，让 PL 主时钟、debug hub 和 ILA 正常运行。
2. 保留最小 DMA 接收示例，后续用于把 ADC 原始样本或统计数据搬到 DDR/串口/上位机。
3. 后续生成可上电自启动的 FSBL + bitstream + keepalive app，减少每次手动用 Vitis 拉起 PS 的步骤。

`sw/baremetal_dma_rx/` 仍作为“板端最小 DMA 接收验证”示例保留，目标是：

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

## 命令行 XSA / BSP / 编译冒烟测试

当前仓库提供一个不依赖 Vitis GUI app 模板的 smoke test。默认使用当前 external RX 带 bitstream XSA：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/export_current_xsa.tcl -tclargs -include-bit -out artifacts\xsa\Ez_QPSK_external_rx_with_bit.xsa
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/test_vitis_xsa_build.tcl artifacts\xsa\Ez_QPSK_external_rx_with_bit.xsa Vitis_WS\codex_xsa_smoke_external_rx_latest
```

该流程会：

1. 从当前 Vivado 工程导出 XSA。
2. 在被 Git 忽略的 `Vitis_WS/` 下创建临时 platform/BSP。
3. 从 XSA 重新生成 standalone BSP 和 FSBL。
4. 使用生成的 BSP 头文件/`libxil.a` 编译并链接 `sw/baremetal_dma_rx/main.c`。

`sw/baremetal_dma_rx/lscript.ld` 是用于命令行 smoke build 的 Zynq DDR linker script；如果后续 PS DDR map 变化，应从 Vitis 重新生成并同步更新。

Vitis GUI/Debug 流程中要确认 `Program FPGA` 使用当前阶段匹配的 bitstream。板 A 发射用 `artifacts/original_tx_prbs/Ez_QPSK_original_tx_prbs.bit`；板 B 接收用 `artifacts/new_interface_rx/Ez_QPSK_new_interface_rx.bit`。不要继续使用早期 `zynq_dma` bitstream，否则 PS DMA 程序可能和当前 PL/BD 状态不匹配。

若只是为了让 PL/ILA 可工作，PS 应用可以是最小 keepalive 程序：运行 `ps7_init`/FSBL 后进入空循环即可。更省事的上板流程是为板 A 和板 B 分别生成包含匹配 bitstream 的 `BOOT.BIN`，先用 SD 卡启动验证；稳定后再考虑 QSPI flash 固化。每次 PL bitstream 更新后，都要重新生成对应 `BOOT.BIN`。

## Vitis 版本管理口径

- 当前建议 Vivado 和 Vitis 使用同一版本：`2020.2`。
- `Vitis_WS/` 是本机工作区和生成物目录，不作为源码入库。
- Git 中保留 `sw/` 下的手写应用源码和说明文件；standalone platform、BSP、FSBL、`.elf` 等由 Vitis 根据 Vivado 导出的 XSA 重新生成。
- 如果切回历史 Git 节点，应先用该节点的 Vivado 重建脚本恢复硬件工程并重新导出 XSA，再在 Vitis 中刷新或重建 platform / application。

## 当前边界

- 这里先只做“最小裸机 DMA 接收”
- PL 侧在线解调已通过 J11/ILA 可观测；当前 PS 裸机示例还不读取或统计在线解调结果
- 暂不引入 Linux / PetaLinux
- 暂不引入网口发送

后续 PS 侧可继续加：

1. 连续采集
2. 数据导出
3. 网口发送
4. PS 侧读取在线解调状态、符号或误码统计
