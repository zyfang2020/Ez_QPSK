# Ez_QPSK 项目说明（AX7020 / Zynq-7020）

## 1. 项目目标与当前状态

### 1.1 最终目标

- 在 AX7020 / Zynq-7020 平台上实现 QPSK 调制与解调完整链路。
- 目标符号率：约 `2 Msym/s`。
- 当前采样/发射工作点：`clk_dac = 100 MHz`，`SHAPER_SPS = 50`。
- 当前载波规划：目标信道约 `6~9 MHz`，默认中心频率 `7 MHz`。

### 1.2 分阶段路线

1. 阶段 1：固定数据发送 + 离线解调。
   目标是打通“可控发送、可复现采集、PC 离线验证”闭环。
2. 阶段 2：固定数据发送 + 在线解调。
   目标是在 PL 侧完成实时解调链，形成在线观测与判决能力。
3. 阶段 3：协议化数据输入。
   目标是确定链路协议，从上位机获取数据包并驱动调制发送。

### 1.3 当前状态

- 阶段 2 在线调制解调已打通：本地 TX loopback、随机外部输入、正/负残余频偏、宽频偏、锁后载波漂移，以及顶层 `external_rx` 模式仿真均已通过。
- 上板路径已验证：本地模拟回环 `loopback_prbs` 通过；两板外部输入模式也已通过，板 A 原 AX7020 风格接口发射 `original_tx_prbs`，板 B 新 HS 接口接收 `new_interface_rx`，在 PS/FCLK 初始化后 ILA 抓取可稳定看到 RX demod lock。
- 后续重点是长时间稳定性、误码/帧级统计、不同衰减/增益/频偏条件下的回归，以及协议化上位机数据输入。

### 1.4 阶段 1 验收口径

- 发送侧：固定符号流可稳定生成并输出可解调波形。
- 接收侧：ADC 原始数据可稳定搬运至 AXI DMA/DDR，包长与 `tlast` 行为正确。
- 离线侧：导出数据可在 Matlab / Python 脚本中完成离线解调与频谱、星座验证。

## 2. 当前工程说明

### 2.1 链路结构

- TX 链路：
  `qpsk_test_gen 或外部 qpsk_sym_* -> qpsk_tx_single_dac -> ad9762_driver -> DAC`
- RX 原始采样链路：
  `AD9215 -> ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt -> AXI DMA S2MM -> PS DDR`
- RX 在线解调支路：
  `ad9215_capture -> qpsk_rx_fixed_demod -> rx_demod_sym/valid/lock`

在线解调支路并联在 ADC capture 后，不替代原始 ADC 样本 DMA 搬运；后续仍可用离线脚本交叉验证在线判决。

### 2.2 时钟与复位

- 主采样/调制链路由 PS `FCLK_CLK0` 驱动，Vivado BD 中同时连接到 `clk_axi` 和 `clk_io`。
- `pl_comm_top` 内部把 `clk_io` 转发为板外 `clk_adc` / `clk_dac`。
- 复位统一使用低有效 `rst_n`，各时钟域通过 `RTL/utils/reset_sync.v` 同步释放。
- 上板抓 ILA 前必须保证 PS/FCLK 已运行；仅下载 PL bitstream 但 PS/FCLK 未初始化时，Vivado 可能显示 FPGA DONE，但 `debug_hub` / ILA 不可见。

### 2.3 顶层与模式

- 主顶层：`RTL/top/pl_comm_top.v`
  - 支持 TX/RX 独立使能。
  - `tx_en=0` 时 DAC 输出回零。
  - ADC capture 后并联 `qpsk_rx_fixed_demod`，输出 demod symbol/valid/lock。
- 固定配置封装：`RTL/top/pl_comm_top_fixed_cfg.v`
  - 用于仿真、bitstream profile 和板级 bring-up。
  - 导出 `rx_demod_bit`、`rx_demod_lock` 到 J11 debug 管脚。
  - 导出 `rx_demod_dbg_bus[95:0]` 给 ILA，用于观察 lock score、I/Q、timing phase、phase bin、NCO correction、raw ADC 等。

常用 profile：

- `loopback`：本地 Gray 循环 TX/RX 回环。
- `loopback_prbs`：本地 PRBS7 随机符号 TX/RX 回环压力测试。
- `external_rx`：关闭本地 TX，只保留外部 ADC 输入和 RX demod。
- `original_tx_prbs` / `original_tx_gray`：板 A 原 AX7020 风格接口 TX-only 镜像。
- `new_interface_rx`：板 B 新 HS 接口 RX 镜像。

两板模式角色固定为：板 A 原 AX7020 风格接口做 TX，板 B 新 HS 接口做 RX。不要把新 HS 接口当 TX 使用。

### 2.4 目录与文件作用

- `RTL/`：可综合 RTL 源码。
- `RTL/top/`：顶层集成与固定配置封装。
- `RTL/modem/`：QPSK 调制/解调链相关模块。
- `RTL/drivers/`：AD9215、AD9762、AXIS 适配等器件/总线侧模块。
- `RTL/source/`：测试数据源和激励源模块。
- `RTL/buffer/`：跨时钟域缓冲模块。
- `RTL/utils/`：复位同步、分包等公共模块。
- `Sim/`：testbench 与仿真说明，详见 `Sim/README.md`。
- `Constraints/`：时钟、IO、debug 管脚约束。
- `Tool/`：离线处理、ILA CSV 解码和分析工具，详见 `Tool/README.md`。
- `sw/`：PS 端或配套软件源码。
- `scripts/`：Vivado/Vitis/板级自动化脚本，详见 `scripts/README.md`。
- `artifacts/`：脚本生成或归档的阶段性硬件产物，例如 `external_rx/`、`loopback_prbs/`、`original_tx_prbs/`、`new_interface_rx/`、`xsa/`。这些产物主要用于实验复现和板级验证，通常不作为源码基线提交。
- `AGENTS.md`：给 AI/自动化协作者使用的项目上下文、避坑记录和命令行经验。
- `RECORD.md`：阶段性仿真、实现、硬件 bring-up 和文档整理时间线。

### 2.5 仿真入口

常用仿真脚本放在 `scripts/`，testbench 说明放在 `Sim/README.md`。阶段 2 重点回归通常包括：

- `run_qpsk_rx_demod_loopback_sim.tcl`
- `run_qpsk_rx_demod_random_external*_sim.tcl`
- `run_pl_comm_top_external_rx*_sim.tcl`

这些脚本会扫描仿真日志中的 `[PASS]` / `[FAIL]` 标记并返回对应退出码，适合批处理回归。

### 2.6 使用注意事项

- 当前 RX demod 已覆盖固定频点、本地回环、PRBS、正/负宽频偏和锁后载波漂移等场景，但仍不是完整的任意外部发射机盲同步方案。
- 真实外部输入调试建议先跑 `SignalOnly`，确认 ADC span/RMS 和频谱能量确实来自外部 QPSK 输入，再跑完整 demod lock/valid 检查。
- 本地模拟回环链路可能接近 ADC 满量程；若后续出现削顶或 ADC span 过大，应先降低模拟增益或发射幅度，再判断 demod RTL。
- 两块板同时接 JTAG 时，不能只靠 Digilent cable serial 判断板卡身份；优先用 FPGA DNA、实物连接和显式 `-target`。
- 新板非 HS 的 `clk_50M`、reset、debug 等管脚若要正式使用，需要另行确认约束和 Bank VCCO。
- 根 README 面向项目用户；脚本细节放在 `scripts/README.md`；调试时间线放在 `RECORD.md`；AI 接力规则和避坑经验放在 `AGENTS.md`。

### 2.7 工具版本与脚本文档

建议使用同一大版本的 Xilinx 工具，避免 PS7、AXI DMA、BSP 或 XSA 元数据在不同版本间产生差异。

- Vivado：`2020.2`
- Vitis：`2020.2`
- Vivado 命令行：`D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat`
- Vitis / XSCT：`D:\Program_Files\Xilinx\Vitis\2020.2\bin\xsct.bat`

常用仿真、bitstream 生成、烧录、ILA 抓取、PS/FCLK 初始化和两板链路检查命令见 `scripts/README.md`。

### 2.8 Vivado 工程恢复

当前仓库以源码、约束、脚本和文档作为可复现基线；Vivado 生成目录、bitstream、XSA、Vitis 工作区不作为日常源码基线。

从干净源码恢复 Vivado 工程：

```powershell
cd D:\Project\ProjectVivado
& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source Ez_QPSK\scripts\rebuild_project_current.tcl -tclargs --origin_dir Ez_QPSK\scripts --project_name Ez_QPSK
```

工程恢复后再按需要运行仿真、综合、实现、生成 bitstream 或导出 XSA。

如需从 Vivado GUI 重新导出工程重建脚本：

```tcl
write_project_tcl -force -all_properties -dump_project_info ./scripts/rebuild_project_current.tcl
```

当前仓库更适合保留完整展开的 Tcl 重建脚本；除非决定把 `.bd` 等 BD 文件本体纳入版本管理，否则不建议使用 `-use_bd_files` 作为主要恢复方式。

## 3. 开发与版本管理规范

### 3.1 Git 管理

- 源码、约束、脚本和说明文档入库。
- Vivado/Vitis 生成目录、仿真缓存、bitstream、XSA、DCP、ILA CSV 等生成物默认忽略。
- 阶段性硬件产物可放在 `artifacts/` 供本机实验复现，但不建议作为日常源码提交。
- 当前 BD/PS 配置以 `scripts/rebuild_project_current.tcl` 中的 Vivado Tcl 定义为准。

### 3.2 RTL 与 CDC

1. 流接口握手统一使用 `data/valid/ready` 或 AXIS `tdata/tvalid/tready/tlast/tkeep`。
2. 复位统一低有效 `rst_n`，并在各时钟域同步释放。
3. 跨时钟数据流必须通过异步 FIFO 或等价 CDC 结构。
4. 单 bit 控制跨域使用 2FF 同步，多 bit 控制使用握手或锁存方案。
5. 参数必须明确支持范围，限制条件应能在仿真期报错。

### 3.3 后续方向

1. 扩展长时间稳定性和误码/帧级统计。
2. 覆盖更多输入幅度、信道衰减、残余频偏和符号率偏差组合。
3. 继续增强锁前频偏捕获、非数据辅助同步和符号定时恢复。
4. 保留 ADC 原始样本 DMA 搬运，用离线脚本交叉验证在线判决。
5. 进入协议化上位机数据输入与链路 BER 闭环。
