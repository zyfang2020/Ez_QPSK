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

## 命令行 XSA / BSP / 编译冒烟测试

当前仓库提供一个不依赖 Vitis GUI app 模板的 smoke test：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/export_current_xsa.tcl -tclargs -out artifacts\xsa\Ez_QPSK_current.xsa
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/test_vitis_xsa_build.tcl artifacts\xsa\Ez_QPSK_current.xsa Vitis_WS\codex_xsa_smoke_current
```

该流程会：

1. 从当前 Vivado 工程导出 XSA。
2. 在被 Git 忽略的 `Vitis_WS/` 下创建临时 platform/BSP。
3. 从 XSA 重新生成 standalone BSP 和 FSBL。
4. 使用生成的 BSP 头文件/`libxil.a` 编译并链接 `sw/baremetal_dma_rx/main.c`。

`sw/baremetal_dma_rx/lscript.ld` 是用于命令行 smoke build 的 Zynq DDR linker script；如果后续 PS DDR map 变化，应从 Vitis 重新生成并同步更新。

## Vitis 版本管理口径

- 当前建议 Vivado 和 Vitis 使用同一版本：`2020.2`。
- `Vitis_WS/` 是本机工作区和生成物目录，不作为源码入库。
- Git 中保留 `sw/` 下的手写应用源码和说明文件；standalone platform、BSP、FSBL、`.elf` 等由 Vitis 根据 Vivado 导出的 XSA 重新生成。
- 如果切回历史 Git 节点，应先用该节点的 Vivado 重建脚本恢复硬件工程并重新导出 XSA，再在 Vitis 中刷新或重建 platform / application。

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
