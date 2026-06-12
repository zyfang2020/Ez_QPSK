# scripts 使用说明

本目录放 Vivado/Vitis/板级 bring-up 自动化脚本。除非只做离线分析，建议在工程根目录运行这些命令。

## 先看这几个入口

- `list_hw_targets.tcl`：只读列出 Vivado Hardware Manager 可见的 JTAG target/device/DNA/ILA，用来确认板子身份。
- `program_bitstream.tcl`：通用 bitstream 烧录入口，支持 `-target` / `-device`。
- `init_ps7_fclk.tcl`：通过 XSCT 初始化 Zynq PS7/FCLK，使由 PS `FCLK_CLK0` 驱动的 PL/debug_hub/ILA 有时钟。
- `download_ps_app.tcl`：通过 XSCT 运行 `ps7_init/ps7_post_config`，下载并启动裸机 ELF。
- `check_external_rx_board.ps1`：烧录、抓 ILA、解码 RX demod 的一键检查入口。
- `wait_external_rx_signal.ps1`：反复跑 `SignalOnly`，等 ADC 有外部输入后再进入完整 demod 检查。
- `run_two_board_external_link.ps1`：两板真实链路编排入口，要求显式给出 TX/RX 的 HW target 和 PS target。

## 常用流程

### 1. 枚举 JTAG 板子

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/list_hw_targets.tcl
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/init_ps7_fclk.tcl -list
```

两块 Zynq 板同时连接时，不要依赖默认第一个 target。先确认 serial/DNA/target，再把 `-target` 传给烧录和抓取脚本。

### 2. 本地仿真回归

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_loopback_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_sim.tcl
```

正/负频偏、宽频偏、锁后漂移分别有 `_neg`、`_wide`、`_drift` 命名的配套脚本。

### 3. 生成上板镜像

```powershell
# 当前板本地回环或 external_rx profile
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_external_rx_bitstream.tcl -tclargs loopback_prbs
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_external_rx_bitstream.tcl -tclargs external_rx

# 两板链路：板 A/原 AX7020 风格接口做 TX，板 B/新 HS 接口做 RX
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_original_interface_tx_bitstream.tcl -tclargs prbs
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_new_interface_rx_bitstream.tcl
```

`run_second_board_tx_bitstream.tcl` 已弃用并会报错，避免把新 HS 接口误当 TX。

当前板卡指纹：

- 板 A：原 AX7020 风格引脚/接口板，TX，FPGA DNA `3A1691221322147B`。
- 板 B：新 HS 引脚/接口板，RX，FPGA DNA `3A16927471382023`。
- Digilent cable serial `210512180081` 是下载器/线的身份，不能单独区分板卡。

### 4. 初始化 PS/FCLK

```powershell
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/init_ps7_fclk.tcl -target <xsct_target>
```

本工程 PL 主采样/debug 时钟依赖 PS `FCLK_CLK0`。只下载 PL bitstream 但 PS/FCLK 没运行时，Vivado 可能显示 FPGA DONE，但随后报：

- `debug hub core was not detected`
- `design has no supported debug core(s)`
- ILA count 为 `0`

如果还需要让 PS 端裸机程序实际运行，可下载 ELF：

```powershell
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/download_ps_app.tcl -target <xsct_target>
```

默认 ELF 是最新 external-RX smoke build 的 `baremetal_dma_rx_smoke.elf`；可用 `-elf <path>` 覆盖。若 `download_ps_app.tcl -list` 没有列出 APU/Cortex-A9 target，则还不能下载运行 PS 程序，需要先解决 PS JTAG target 可见性。

板 A 上更接近 Vitis GUI Debug 的 batch 入口是 Vitis 生成的脚本：

```powershell
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" -eval "source D:/Project/ProjectVivado/Ez_QPSK/Vitis_WS/Data_Transfer/_ide/scripts/debugger_dma_transfer-default.tcl"
```

这个脚本会执行 system reset、烧 `artifacts/original_tx_prbs/Ez_QPSK_original_tx_prbs.bit`、`loadhw`、`ps7_init/ps7_post_config`、下载 `Vitis_WS/dma_transfer/Debug/dma_transfer.elf`，并在 `main` 处设断点。若只用 Vivado 烧 PL 而不跑这一步，PS `FCLK_CLK0` 可能不会启动，ILA/debug_hub 也可能检测不到。

### 5. RX 输入预检与完整检查

```powershell
# 只看 ADC 是否有足够输入活动，不要求解调锁定
powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode new_interface_rx -Target <rx_target> -SignalOnly

# 输入存在后，做完整 lock/valid 检查
powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode new_interface_rx -Target <rx_target>
```

如果物理链路不确定，先用 `-SignalOnly -MinAdcAcRms 20 -MinAdcBandPowerRatio 0.5`。若 ADC span/RMS 仍只有个位数，优先查外部输入、RX 模拟链路、ADC 供电/偏置/连接。

## PS/FCLK 没跑起来的常见原因

当前症状若是 PL 下载成功但 XSCT `targets` 为空，常见原因包括：

- 板子 PS 侧没有上电、复位未释放，或电源时序异常。
- JTAG 链只看到 PL/FPGA device，没看到 ARM DAP/APU；可能是 JTAG 线、驱动、链路枚举或目标选择问题。
- 启动模式/BOOT 跳线让 PS 停在异常状态，或外部 boot 介质/FSBL 没启动。
- 没运行 FSBL/`ps7_init`，导致 `FCLK_CLK0` 没打开；这会直接让 ILA/debug_hub 无时钟。
- PS7 init 脚本和当前硬件平台不匹配，或 XSA/硬件平台不是这块板生成的。
- 多块板同时连接时选错了 XSCT target，实际初始化了另一块板或没有选中 APU。
- hw_server/cs_server 状态脏；可以关闭 Vivado/Vitis 后重新枚举，必要时重插 JTAG/重启板电源。

## Vivado/Vitis 权限提示

如果普通沙箱内运行 Vivado/Vitis 出现 `.hdi.isWriteableTest`、`rundef.js Access denied`、临时目录不可写等权限问题，用提升权限重跑同一条命令。此类错误通常不是 RTL 或脚本逻辑问题。

## 脚本分组

- 仿真：`run_qpsk_*_sim.tcl`、`run_pl_comm_top_external_rx*_sim.tcl`
- 综合/实现：`run_synth_check.tcl`、`run_impl_check.tcl`
- 模式/约束切换：`set_qpsk_rx_board_mode.tcl`、`select_qpsk_board_io_constraints.tcl`
- bitstream：`run_external_rx_bitstream.tcl`、`run_original_interface_tx_bitstream.tcl`、`run_new_interface_rx_bitstream.tcl`
- 烧录/抓取：`program_bitstream.tcl`、`program_external_rx_bitstream.tcl`、`capture_external_rx_ila.tcl`
- 板级检查：`check_external_rx_board.ps1`、`wait_external_rx_signal.ps1`、`run_two_board_external_link.ps1`
- PS/XSA/Vitis：`init_ps7_fclk.tcl`、`download_ps_app.tcl`、`export_current_xsa.tcl`、`test_vitis_xsa_build.tcl`
- 工程恢复：`rebuild_project_current.tcl`
