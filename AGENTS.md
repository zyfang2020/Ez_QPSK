# AGENTS.md

本文件面向 AI/自动化协作者，保存“怎么安全接手这个工程”的规则、当前上下文和避坑经验。项目用户向说明见 `README.md`；脚本用法见 `scripts/README.md`；仿真入口见 `Sim/README.md`；阶段调试时间线见 `RECORD.md`。

## 工作边界

- 当前工程：Ez_QPSK on AX7020 / Zynq-7020。
- 当前分支：`Part2`。除非用户明确要求，不要切换、合并、rebase、reset 或修改 `main`。
- 默认不重画 BD；当前阶段优先保持 PS/BD/DMA 主结构稳定。
- 当前阶段不把重点放在 PS 侧软件或 DMA 改造上；PL 侧 RX online demod 是并联 debug/验证支路。
- 生成物默认不入库，除非用户明确要求发布产物。源码、约束、脚本和文档优先。
- 提交前必须重新确认：
  - `git status --short --branch`
  - 分支仍为 `Part2`
  - 没有把 Vivado/Vitis 生成目录、bitstream、XSA、ILA CSV 等误加进 Git。

## 当前工程状态

- TX path：`qpsk_test_gen -> qpsk_tx_single_dac -> ad9762_driver -> DAC`。
- RX raw path：`AD9215 -> ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt -> AXI DMA S2MM`。
- RX demod path：`ad9215_capture -> qpsk_rx_fixed_demod -> rx_demod_sym/valid/lock/debug`。
- sample clock：PS `FCLK_CLK0` 同时驱动 `clk_axi` 和 `clk_io`；`pl_comm_top` 把 `clk_io` 转发到 `clk_adc` / `clk_dac`。
- 当前 stage-2 状态：本地 online QPSK 调制解调、PRBS 本地模拟回环、随机外部输入仿真、顶层 external-RX 仿真和两板外部输入 bring-up 均已打通。
- 当前 demod RTL 已包含：
  - unsigned ADC centered + DC removal
  - fixed-frequency DDC
  - coarse SPS=50 timing phase selection
  - Gray pattern lock path
  - blind/random-data lock path
  - bounded decision-directed Costas-like NCO trim
  - re-acquisition watchdog for late/missing signal restart

## 关键设计约束

- 当前 `qpsk_rx_fixed_demod.v` 验证参数为 `ADC_DW=10`、`SPS=50`、`NCO_W=12`；不要随手泛化这些参数。
- 固定外部载波频率不等于不需要恢复。真实外部源仍可能有残余频偏、相位偏移、采样钟漂移、幅度变化和符号定时偏移。
- `external_rx` profile 会关闭本地 TX，只保留外部 ADC 输入与 RX demod。
- `loopback_prbs` 是本地随机符号压力测试；PRBS 下 Gray-cycle 匹配率低是正常现象。
- 在线 demod 支路不替代 ADC raw DMA 搬运；后续仍应保留离线交叉验证能力。

## 板卡与角色

- 板 A：原 AX7020 风格接口板，作为两板链路 TX。Vivado 观测 FPGA DNA：`3A1691221322147B`。
- 板 B：新 HS 接口板，作为两板链路 RX。Vivado 观测 FPGA DNA：`3A16927471382023`。
- Digilent cable serial `210512180081` 是下载器/线缆身份，可能随线移动，不能单独区分板卡。
- 两板模式角色固定为：板 A `original_tx_prbs` / `original_tx_gray` 发射，板 B `new_interface_rx` 接收。
- `scripts/run_second_board_tx_bitstream.tcl` 已故意弃用并报错，避免把新 HS 接口误当 TX。
- 两块板同时接 JTAG 时必须显式选择 target/device，不要依赖默认第一个 target。

## 常用入口

仿真：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_loopback_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_sim.tcl
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_sim.tcl
```

bitstream：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_external_rx_bitstream.tcl -tclargs loopback_prbs
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_original_interface_tx_bitstream.tcl -tclargs prbs
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_new_interface_rx_bitstream.tcl
```

JTAG/PS/FCLK：

```powershell
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/list_hw_targets.tcl
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/init_ps7_fclk.tcl -list
& "D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat" scripts/init_ps7_fclk.tcl -target <xsct_target>
```

RX board check：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode new_interface_rx -Target <rx_target> -SignalOnly
powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode new_interface_rx -Target <rx_target> -NoProgram
```

详细脚本清单和参数说明放在 `scripts/README.md`。

## 避坑记录

- Vivado 2020.2 在普通托管沙箱里可能因 `.hdi.isWriteableTest*.tmp`、`rundef.js Access denied` 或临时目录权限失败。若命令本身重要且症状明显是权限问题，按执行环境规则用提升权限重跑同一条命令；这通常不是 RTL 或 Tcl 逻辑错误。
- PL 下载成功不代表 ILA 可用。ILA/debug_hub 时钟来自 PS `FCLK_CLK0`；PS/FCLK 未初始化时可能出现 FPGA DONE 但 `debug_hub` 检测不到。
- 如果 Vitis 已经烧入 RX bit 并初始化 PS/FCLK，后续 board check 优先加 `-NoProgram`，避免重烧 PL 后丢失当前 PS/FCLK 状态。
- `download_ps_app.tcl -list` 或 XSCT/XSDB `targets` 为空时，不能假设 PS ELF 已下载或 PS/FCLK 已启动；需要先解决 System Debugger 目标可见性。
- 板 A 上复刻 Vitis GUI Debug 行为时，Vitis 生成的 `_ide/scripts/debugger_dma_transfer-default.tcl` 可能比独立 XSCT helper 更接近 GUI 流程。注意它必须指向当前匹配的 bitstream。
- 外部输入链路不确定时，先跑 `-SignalOnly`。若 ADC span/RMS 仍接近空输入，优先查外部源、连接、RX 模拟链路、ADC 供电/偏置，不要先怀疑 demod RTL。
- 本地模拟回环可能接近 ADC 满量程。若看到 clipping 或 raw span 过大，先降低模拟增益或发射幅度。
- NCO sign/幅度门限适合真实外部源残余频偏检查；同钟本地 loopback 的 NCO correction 可以合法接近 0，不要默认加 NCO 门限。
- 如果后续启用新 HS 板非 HS `clk_50M`、reset 或 debug 管脚，需要先确认约束和 Bank VCCO。

## 文档职责

- `README.md`：用户向项目入口，保持简洁。
- `scripts/README.md`：脚本入口、参数和常用流程。
- `Sim/README.md`：testbench 列表、运行方式和通过判据。
- `Tool/README.md`：后处理/解码工具说明。
- `RECORD.md`：阶段性仿真、实现、硬件 bring-up 的时间线记录。
- `AGENTS.md`：AI 接手规则、当前状态和避坑经验；不要继续写成流水账。
