# Ez_QPSK 项目说明（AX7020 / Zynq-7020）

## 1. 目标与阶段

### 1.1 最终目标

- 在 AX7020（Zynq-7020）上实现 QPSK 调制与解调完整链路。
- 目标符号率：`2 Msym/s`。
- 当前发射链默认工作点：`clk_dac = 100 MHz`，`SHAPER_SPS = 50`，对应约 `2 Msym/s`。
- 当前频点规划：目标信道约 `6~9 MHz`，当前载波中心频率 `7 MHz`。

### 1.2 分阶段路线

1. 阶段 1：固定数据发送 + 离线解调  
   目标：先打通“可控发送 + 可复现采集 + PC 离线验证”闭环。
2. 阶段 2：固定数据发送 + 在线解调  
   目标：在板端完成实时解调链，形成在线观测与判决能力。
3. 阶段 3：协议化数据输入  
   目标：确定链路协议，从上位机获取数据包并驱动调制发送。

### 1.3 当前进度（阶段 2 在线解调与外部输入仿真验证）

- 已完成：QPSK 调制链 RTL 实现与仿真验证（单板本地回环）。
- 已完成：`qpsk_test_gen -> qpsk_tx_single_dac -> ad9762_driver` 单 DAC 发射链仿真验证。
- 已完成：ADC 侧采集与 AXI 搬运通路 RTL 实现（`ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt`）。
- 已完成：顶层“无板数字回环”仿真验证，确认 `DAC -> 本地回环 ADC -> RX AXIS` 数据链与 `tlast` 行为正确。
- 已完成：新增 PL 侧 `qpsk_rx_fixed_demod` 在线解调分支，并通过本地 TX loopback 仿真恢复 Gray 序列。
- 已完成：为 RX demod 增加 decision-directed 相位微调、锁定迟滞和轻量 early/late 定时跟踪，并通过带相位偏移、`3 kHz` 残余频偏、符号定时相位偏移和 ADC DC 的进阶仿真。
- 已完成：新增外部输入漂移仿真，使用独立 `2.010 Msym/s` QPSK 源和 TX 参考校验，验证 RX 能跟随外部符号钟偏差。
- 已完成：新增随机外部 QPSK 仿真，验证 RX 在没有本地 Gray 循环先验、带 `+15 kHz/-15 kHz` 和宽压测 `+35 kHz/-35 kHz` 残余载波偏差、慢幅度/DC 漂移和 ADC 采样噪声时可通过锁前频偏扫描与盲质量锁定恢复符号，并确认锁后 Costas-like PI 载波细调参与工作。
- 已完成：新增锁后载波漂移回归，输入在已锁后分别从 `+15 kHz -> +35 kHz`、`-15 kHz -> -35 kHz` 漂移，RX 保持符号恢复并把 NCO correction 跟踪到对应频偏方向。
- 已完成：导出 `rx_demod_bit/rx_demod_lock` 到 J11 debug 管脚，便于真实外部输入上板时直接观测判决位与锁定状态。
- 已完成：新增外部 RX 上板模式脚本，可在不重画 BD 的情况下把固定配置切到 `FIXED_TX_EN=0/FIXED_RX_EN=1`，用于外部 QPSK 信号灌 ADC 时关闭本地 DAC 发射。
- 已完成：新增顶层 external RX 正/负频偏仿真，验证 `pl_comm_top_fixed_cfg` 在 TX 关闭时 DAC 保持回零，外部 PRBS QPSK ADC 激励可经顶层 RX demod 盲锁恢复，并且 J11 debug 输出与内部 lock/bit 一致；顶层 external-RX 宽频偏 `+35 kHz/-35 kHz` 也已通过。
- 已完成：新增并验证 external RX bitstream batch 构建，产物输出到 `artifacts/external_rx/`；最新宽扫候选评分 RTL 版 route/write_bitstream 通过，setup slack `0.219 ns`、hold slack `0.042 ns`，`.ltx` 已包含 ILA `probe2` 的 `rx_demod_dbg_bus[95:0]`。
- 已完成：新增 external RX ILA 抓取脚本，可连接 Hardware Manager、可选烧录 external RX bitstream，并把 ILA 数据导出为 CSV。
- 已完成：新增 external RX ILA CSV 解码工具，可从 Hardware Manager 导出的 `probe2` 数据中解出 lock ratio、lock score、I/Q、timing phase、NCO 频偏校正和符号统计，并可对 NCO 频偏方向/幅度设置附加检查。
- 已完成：新增 external RX 一键板级检查脚本，可串联烧录、ILA 抓取和 `--check-external-rx` 解码阈值检查；真实外部源调试时可追加 `-ExpectNcoSign/-MinNcoAbs/-MaxNcoAbs` 验证残余载波方向和范围，并自动输出多次抓取的聚合摘要。
- 已完成：新增本地 `loopback_prbs` 上板模式，可把内部 QPSK TX 从固定 Gray 循环切到 PRBS7 符号流，用于观察非周期符号工况下的 ADC 幅度、I/Q 活动和硬判决分布。
- 已完成：`loopback_prbs` 本地模拟回环上板验证通过。当前路径为 `PL TX -> DAC -> 外部滤波/放大链路 -> ADC -> PL RX demod`，最新版 ILA 三次抓取均通过 `--check-external-rx`。
- 已完成：刷新 `external_rx` 带 bitstream XSA 并通过 Vitis smoke build，可用于更新/重导入 PS 侧软件工程；最新 smoke 工作区为 `Vitis_WS/codex_xsa_smoke_external_rx_wide_acq`。
- 当前外部源状态：最新 `external_rx` 上板 ILA 可捕获，但 ADC 输入仅为近中点小噪声，`external_rx_board_check.csv` 显示 `adc_raw_span=3`、`lock_ratio=0`；这说明当前没有独立外部 QPSK 信号送入 ADC，或者外部输入链路尚未打开。
- 当前工程定位：保留原 BD/PS/DMA 主结构，在 ADC capture 后并联在线解调 debug 支路。
- 未完成：真实外部 QPSK 发射机上板联调，更完整的盲锁定/误码统计，协议化上位机数据接入。

### 1.4 阶段 1 验收口径

- 发送侧：固定符号流可稳定生成并输出可解调波形。
- 接收侧：ADC 原始数据可稳定搬运至 AXI DMA/DDR，包长与 `last` 行为正确。
- 离线侧：导出数据在 Matlab 脚本中可完成离线解调与频谱/星座验证。

## 2. 当前工程说明

### 2.1 当前链路结构

- TX 最小链路（推荐）  
  `qpsk_test_gen 或外部 qpsk_sym_* -> qpsk_tx_single_dac -> ad9762_driver -> DAC`
- RX 最小链路（当前以搬运为主）  
  `AD9215 -> ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt -> AXI DMA S2MM -> PS DDR -> PC 离线解调`
- RX 在线解调 debug 支路
  `ad9215_capture -> qpsk_rx_fixed_demod -> rx_demod_sym/valid/lock`

### 2.2 时钟与复位

- 时钟域：`clk_adc`、`clk_axi`、`clk_dac`。
- 全局复位：低有效 `rst_n`。
- 复位同步：通过 `RTL/utils/reset_sync.v` 在各时钟域同步释放。
- 当前入库约束文件：
  - `Constraints/sys_clk_ax7020.xdc`
  - `Constraints/pl_comm_top_io_ax7020_adc.xdc`
  - `Constraints/pl_comm_top_io_ax7020_dac.xdc`
  - `Constraints/pl_comm_top_io_ax7020_j11_debug.xdc`
- 当前 BD 中，主链路时钟由 PS `FCLK_CLK0` 提供，并同时连接到 `clk_axi` 和 `clk_io`。
- `pl_comm_top` 内部把 `clk_io` 直接转发为板外 `clk_adc` / `clk_dac`。
- `clk_50M` 是 AX7020 板载 PL 时钟输入；当前 BD 中保留为外部端口，不作为主 QPSK 采样链路的时钟源。external RX bitstream 中，BD ILA 已切到 PS `FCLK_CLK0`，与 `clk_io`/RX demod 同域采样。
- PS/BD 相关时钟连接由 Vivado 工程重建脚本中的 BD 定义恢复。

### 2.3 顶层与模式说明

- 顶层：`RTL/top/pl_comm_top.v`
  - 支持 TX/RX 独立使能（`tx_en` / `rx_en`）。
  - `tx_en=0` 时，DAC 输出回零（`ad9762_driver` 配置 `HOLD_LAST=0`）。
  - TX 源支持 `tx_test_pattern` 与 QPSK 调制链选择（`tx_src_sel`）。
  - QPSK 输入支持内部测试源与外部符号口选择（`qpsk_src_sel`）。
  - ADC capture 后并联 `qpsk_rx_fixed_demod`，输出 `rx_demod_sym/valid/lock` 供仿真和后续 ILA/J11 调试使用。
- 固定配置封装：`RTL/top/pl_comm_top_fixed_cfg.v`
  - 当前用于最小 bring-up：固定走 QPSK 内部测试发送路径。
  - 导出 `rx_demod_bit` 和 `rx_demod_lock` 两个板级 debug 输出；当前约束到 J11 PIN3/F17 与 J11 PIN4/F16。
  - 导出 `rx_demod_dbg_bus[95:0]` 给 BD 内现有 ILA 的 `probe2`，用于 external RX 上板时观察锁定质量、I/Q、定时相位和 NCO 频偏校正。

### 2.4 目录与文件作用（按工程根目录）

- `RTL/`：可综合 RTL 源码根目录。
- `RTL/top/`：顶层集成与固定配置封装（如 `pl_comm_top*`）。
- `RTL/modem/`：QPSK 调制/解调链相关模块（映射、成型、上变频、DDC/判决、DAC 格式转换）。
- `RTL/drivers/`：器件与总线侧驱动/适配（AD9215、AD9762、AXIS 适配）。
- `RTL/source/`：测试数据源/激励源模块（`tx_test_pattern`、`qpsk_test_gen`）。
- `RTL/buffer/`：跨时钟域缓冲模块（异步 FIFO）。
- `RTL/utils/`：公共工具模块（复位同步、分包等）。
- `RTL/ctrl/`：控制面模块预留目录（后续寄存器/配置控制逻辑放这里）。
- `Sim/`：仿真目录（testbench 与仿真文档）。
- `Constraints/`：约束目录（`.xdc`，包含时钟与 IO 约束模板）。
- `Tool/`：离线处理工具目录（算法验证、后处理脚本、辅助数据）。
- `sw/`：PS 端或配套软件源码目录（如裸机 DMA 接收示例、后续导出/联网工具）。
- `scripts/`：自动化脚本目录（官方 Vivado 工程重建脚本、仿真批处理）。
- `README.md`：项目总说明（目标、阶段、工程说明、规范）。

### 2.5 当前仿真入口

- `Sim/tb_tx_chain_min.v`：TX 测试源到 DAC 驱动。
- `Sim/tb_rx_chain_min.v`：ADC 到 AXI 打包搬运链。
- `Sim/tb_qpsk_tx_chain_min.v`：legacy QPSK 发射链。
- `Sim/tb_qpsk_tx_single_dac_min.v`：推荐 QPSK 单 DAC 发射链（可导出 CSV）。
- `Sim/tb_qpsk_rx_demod_loopback.v`：stage-2 本地 TX loopback 在线解调验证。
- `Sim/tb_qpsk_rx_demod_impairments.v`：stage-2+ 进阶恢复验证，直接生成带 `3 kHz` 残余频偏等扰动的 QPSK ADC 输入。
- `Sim/tb_qpsk_rx_demod_external_drift.v`：stage-2+ 外部输入漂移验证，直接生成独立 `2.010 Msym/s` QPSK ADC 输入并按 TX 参考校验 RX 输出。
- `Sim/tb_qpsk_rx_demod_random_external.v`：stage-2+ 随机外部输入验证，使用带 `+15 kHz/-15 kHz`、宽压测 `+35 kHz/-35 kHz`、以及锁后 `+15 kHz -> +35 kHz` / `-15 kHz -> -35 kHz` 漂移的残余载波偏差，叠加慢幅度/DC 漂移和 ADC 采样噪声的 PRBS QPSK 符号，并按 TX 参考校验盲锁后的 RX 输出。
- `Sim/tb_pl_comm_top_external_rx.v`：stage-2+ 顶层外部 RX 验证，实例化 `pl_comm_top_fixed_cfg` 的 `FIXED_TX_EN=0/FIXED_RX_EN=1` 模式，检查 TX 关闭回零、J11 debug 输出、`+15 kHz/-15 kHz` 与宽压测 `+35 kHz/-35 kHz` 残余频偏方向和外部 ADC 输入解调。
- 离线脚本：`Tool/matlab/qpsk_single_dac_demod_demo.m`（读取 CSV 做离线解调示例）。

### 2.6 当前注意事项

- 当前在线解调已覆盖本地固定 Gray loopback 仿真，不等同于外部发射机全场景锁定。
- 当前 decision-directed 相位微调、锁前频偏扫描、锁后 Costas-like PI 载波细调和 early/late 定时跟踪已覆盖固定频点正/负残余频偏、宽压测 `+35 kHz/-35 kHz`、锁后正/负向载波漂移仿真与仿真外部符号率漂移，仍不等同于真实射频环境的完整盲同步链。
- 当前 RX demod 优先使用本地 Gray 相关锁定；若长期不能匹配该测试模式，会进入盲锁分支，用星座置信度和 decision-directed 相位误差形成外部随机数据的 lock。ILA 中的 `rx_demod_dbg_lock_score` 显示 Gray/盲锁两路质量分数中的较高值。
- `loopback_prbs` 是随机符号压力测试模式，也已作为本地模拟回环的阶段性硬件验收通过。2026-06-11 最新 ILA 三次抓取 `Tool/data/local_prbs_loopback_post_fix_ila_00..02.csv` 均通过 `--check-external-rx`：`lock_ratio=1`，`lock_score=255`，有效符号数 `21/20/21`，ADC span `964/1000/976`，符号熵约 `1.88..1.99` bits。PRBS 下 Gray-cycle 匹配率低是预期现象，不作为失败依据；当前幅度接近满量程，后续若要留余量可适当降低模拟链路增益。
- `external_rx` 会关闭本地 DAC TX。2026-06-11 最新 external RX ILA 抓取 `Tool/data/external_rx_board_check.csv` 显示 ADC span 只有 `3` 且 `lock_ratio=0`，这不是当前 RTL 判定失败的主要证据，而是 ADC 端没有足够外部 QPSK 输入幅度的证据。接入真实外部源后，优先确认 ADC span 明显大于几十个 LSB，再看 lock 和符号统计。
- external RX bitstream 的 `.ltx` 中，BD ILA `probe2` 连接 `rx_demod_dbg_bus[95:0]`。位域：`[95:80]` signed `nco_freq_corr`，`[79:64]` I，`[63:48]` Q，`[47:40]` lock score，`[39:34]` best timing phase，`[33:30]` phase bin，`[29]` lock，`[28]` valid，`[27:26]` symbol，`[25:16]` raw ADC pins，`[15:0]` captured ADC stream sample。
- external RX bitstream 中，BD ILA 使用 PS `FCLK_CLK0` 采样，与 RX demod 同域；J11 管脚仍建议同时观察实时 bit/lock。
- 当前“ADC->AXI->DDR”链路仍保留，在线解调支路不替代原始采样搬运。
- `qpsk_sym_*` 为后续协议化输入预留接口，当前主要使用内部 `qpsk_test_gen`。
- RX 侧 AXIS 口通常在 Vivado BD 内连接 DMA，不作为外部引脚导出。
- 外部 QPSK 输入仍需要继续升级锁前宽频偏捕获和 Gardner/early-late 定时恢复；当前 `+35 kHz/-35 kHz` 是仿真压力回归通过项，不能替代真实外部发射机的全场景同步验收。

### 2.7 本机 Xilinx 工具版本（Windows）

- 当前工程建议固定使用同一大版本的 Vivado / Vitis，避免 PS7、AXI DMA、BSP 或 XSA 元数据在不同版本间产生差异。
- 本机已确认版本：
  - Vivado：`2020.2`
  - Vitis：`2020.2`
  - Vitis HLS：`2020.2`
- Vivado 命令行路径：
  - `D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat`
- Vitis 安装目录：
  - `D:\Program_Files\Xilinx\Vitis\2020.2`
- 在工程根目录批处理运行单 DAC TX 仿真（不打开 GUI）：
  - `D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl`
- PowerShell 等价命令：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl`
- 运行 stage-2 RX demod 本地 loopback 仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_loopback_sim.tcl`
- 运行 stage-2+ RX demod 带扰动仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_impairments_sim.tcl`
- 运行 stage-2+ RX demod 外部漂移仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_external_drift_sim.tcl`
- 运行 stage-2+ RX demod 随机外部输入仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_sim.tcl`
- 运行 stage-2+ RX demod 随机外部输入负频偏仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_neg_sim.tcl`
- 运行 stage-2+ RX demod 随机外部输入宽频偏仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_wide_sim.tcl`
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_wide_neg_sim.tcl`
- 运行 stage-2+ RX demod 随机外部输入锁后载波漂移仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_drift_sim.tcl`
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_rx_demod_random_external_drift_neg_sim.tcl`
- 运行 stage-2+ 顶层外部 RX 模式仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_sim.tcl`
- 运行 stage-2+ 顶层外部 RX 负频偏模式仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_neg_sim.tcl`
- 运行 stage-2+ 顶层外部 RX 宽频偏模式仿真：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_wide_sim.tcl`
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_pl_comm_top_external_rx_wide_neg_sim.tcl`
- 刷新当前 BD 并导出 J11 RX demod debug 引脚：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/export_rx_demod_j11_debug.tcl`
- 切到外部 RX 上板验证模式（关闭本地 TX，保留 RX demod 与 DMA 采样）：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/set_qpsk_rx_board_mode.tcl -tclargs external_rx`
- 恢复本地 TX/RX loopback bring-up 模式：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/set_qpsk_rx_board_mode.tcl -tclargs loopback`
- 切到本地 PRBS TX/RX loopback 压力测试模式：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/set_qpsk_rx_board_mode.tcl -tclargs loopback_prbs`
- 生成 external RX 上板 bitstream（自动切 `FIXED_TX_EN=0/FIXED_RX_EN=1` 并复制 `.bit/.ltx` 到 `artifacts/external_rx/`）：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_external_rx_bitstream.tcl`
  - 可追加 `-tclargs loopback` 或 `-tclargs loopback_prbs` 生成对应本地回环镜像，产物分别输出到 `artifacts/loopback/` 或 `artifacts/loopback_prbs/`。
- 烧录 external RX 上板 bitstream 并绑定 ILA probes：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/program_external_rx_bitstream.tcl`
- 列出 Hardware Manager 可见的 JTAG target/device/ILA（上板前预检）：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -list`
- 抓取 external RX ILA CSV（可加 `-program` 先烧录）：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/capture_external_rx_ila.tcl -tclargs -program -out Tool\data\external_rx_ila.csv`
  - 若刚烧录后需要等待锁定或想提高命中率，可用 `-warmup-ms 500 -repeat 3` 连抓多份，输出文件会加 `_00/_01/_02` 后缀。
- 一键 external RX 板级检查（默认烧录 `external_rx`，抓三次 ILA，并逐份运行 `--check-external-rx`）：
  - `powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1`
  - 本地随机模拟回环 smoke 可用：`powershell -ExecutionPolicy Bypass -File scripts/check_external_rx_board.ps1 -Mode loopback_prbs`
  - 若外部源相对本地 `7 MHz` NCO 有已知正/负残余频偏，可追加例如 `-ExpectNcoSign positive -MinNcoAbs 96 -MaxNcoAbs 8192`；本地同钟回环的 NCO correction 可能为 0，不建议默认加这个约束。
  - 脚本会为每份 CSV 写 `*_summary.json`，并默认写 `Tool\data\<mode>_board_check_aggregate_summary.json`，聚合显示多次抓取的 lock ratio、valid ratio、ADC span、I/Q RMS 和 locked NCO correction 的 min/avg/max。可用 `-AggregateSummaryJson path\to\summary.json` 改输出位置。
- 解码 Vivado Hardware Manager 导出的 external RX ILA CSV：
  - `python Tool/python/decode_rx_demod_ila.py path\to\ila_export.csv --decoded-csv Tool\data\rx_demod_ila_decoded.csv --summary-json Tool\data\rx_demod_ila_summary.json`
  - 解码摘要会把 `nco_freq_corr` 按默认 `100 MHz / 24-bit` NCO 换算为 Hz，并给出 ADC 动态范围与简单诊断提示；可追加 `--expect-nco-sign positive|negative|nonzero`、`--min-nco-abs`、`--max-nco-abs` 做外部源频偏门槛检查。
  - 第一轮外部输入验收可加 `--check-external-rx`，默认要求 `lock_ratio >= 0.50`、`valid_ratio >= 0.005`、`adc_raw_span >= 16`，不满足时命令返回非零。
  - 若外部 QPSK 源可配置为本项目 Gray 循环 `00 -> 01 -> 11 -> 10`，再加 `--check-gray-cycle`，工具会允许循环起点和方向不确定，并检查有效符号序列是否持续匹配。

### 2.8 Vivado 工程重建脚本

- 在 Vivado Tcl Console 中导出当前工程重建脚本：
  - `write_project_tcl -force -all_properties -dump_project_info ./scripts/rebuild_project_current.tcl`
- 当前仓库建议使用上面这一条，不使用 `-use_bd_files`。
- 原因：`-use_bd_files` 会让导出的脚本依赖工程中的 `.bd` 等 BD 文件本体；如果这些文件不进 Git，别人拉仓库后脚本可能无法独立重建工程。
- 当前仓库更适合保留“完整展开”的 Tcl 重建脚本，这样即使 `*.bd`、`*.srcs/`、`*.gen/` 没有入库，也能仅靠源码和脚本恢复工程。
- 如果后续你决定把 `Ez_QPSK.srcs/sources_1/bd/` 一并纳入版本管理，再考虑 `-use_bd_files` 会更合适；它生成的脚本通常更短，也更接近直接复用现有 BD 文件。

#### 从 Git 节点恢复 Vivado 工程

可以把 Git 中的源码节点视为工程基线：切回某个 commit / tag 后，用该节点里的 `scripts/rebuild_project_current.tcl` 恢复 Vivado 工程生成物。

推荐流程：

1. 关闭 Vivado / Vitis。
2. 在仓库根目录切到目标节点：
   - `git checkout <commit-or-tag>`
3. 如果要严格复现该节点，先清理旧的 Vivado 生成物，或直接在干净 clone 中操作。生成物包括 `Ez_QPSK.xpr`、`Ez_QPSK.srcs/`、`Ez_QPSK.gen/`、`Ez_QPSK.runs/`、`Ez_QPSK.cache/`、`Ez_QPSK.hw/`、`Ez_QPSK.sim/`、`.Xil/` 等。
4. 从工程父目录运行重建脚本，使脚本创建/恢复 `Ez_QPSK` 工程目录：
   - `cd D:\Project\ProjectVivado`
   - `D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch -source Ez_QPSK/scripts/rebuild_project_current.tcl -tclargs --origin_dir Ez_QPSK/scripts --project_name Ez_QPSK`
5. 打开恢复后的 `Ez_QPSK.xpr`，按需要重新综合、实现、生成 bitstream，并重新导出 XSA。

注意：

- Git 只保证恢复入库源码、约束、脚本和说明文件；Vivado 生成目录、bitstream、XSA、Vitis 工作区不作为源码基线。
- `scripts/run_qpsk_tx_single_dac_sim.tcl` 与 `scripts/run_qpsk_rx_demod_loopback_sim.tcl` 需要已有 `Ez_QPSK.xpr`，所以干净 checkout 后应先运行重建脚本，再运行仿真脚本。
- 如果只是在当前工作树里回退源码，但没有清理旧生成物，Vivado 可能继续看到旧的缓存或旧 BD 输出；做可复现实验时优先使用干净 clone 或清理生成目录。

## 3. 规范与标准

### 3.1 目录规范

- 源码与脚本入库，生成物忽略。
- 主要目录固定：`RTL/`、`Sim/`、`Constraints/`、`Tool/`、`scripts/`。
- 新增模块请按功能放入对应子目录，避免跨目录混放。
- 各大目录放置约定：
- `RTL/`：放可综合 HDL 源文件（设计主逻辑）。
- `Sim/`：放 testbench、仿真专用激励与仿真说明。
- `Constraints/`：放 `.xdc` 约束（时钟、IO、时序例外等）。
- `Tool/`：放离线处理工具脚本（Matlab/Python）和离线分析辅助数据。
- `scripts/`：放工程自动化脚本。当前主入口为官方导出的 `scripts/rebuild_project_current.tcl`，用于恢复 Vivado 工程状态；仿真批处理脚本也放在该目录。
- `sw/`：放 PS 端软件源码、板端 bring-up 示例和后续软件工具。
- 根目录文档/工程文件约定：
- `README.md`：项目总说明与阶段目标、规范基线。
- `Sim/README.md`：仿真运行方法与通过判据。
- `Tool/README.md`：工具脚本目录约定与使用说明。
- `scripts/rebuild_project_current.tcl`：Vivado 工程恢复入口，提交时应随源码一并入库。

### 3.2 Git 管理规范

- `.gitignore`：忽略 Vivado 生成目录和运行日志（如 `*.runs/`、`*.cache/`、`*.sim/`）。
- `.gitattributes`：统一文本 LF；`*.bit/*.bin/*.mcs/*.dcp/*.ltx` 标记为二进制。
- 建议仅提交可复现工程所需文件：`RTL/`、`Sim/`、`Constraints/`、`scripts/rebuild_project_current.tcl`、仿真脚本、`sw/` 下手写源码、`Tool/` 下脚本和文档。
- 不依赖 `*.xpr`、`*.srcs/`、`*.gen/`、`*.runs/`、`.Xil/`、`*.xsa`、`Vitis_WS/` 作为版本管理对象；这些内容应通过重建脚本、Vivado 导出或 Vitis 平台重新生成。
- 当前工程中的 BD/PS 配置以 `scripts/rebuild_project_current.tcl` 中内嵌的 Vivado Tcl 定义为准。
- `*.bit`、`*.bin`、`*.mcs`、`*.ltx`、`*.dcp` 和 `*.xsa` 可作为阶段性 release 附件保存，但不建议作为日常源码提交。

### 3.3 RTL 与 CDC 规范

1. 接口握手统一使用 `data/valid/ready`。
2. AXIS 命名统一使用 `tdata/tvalid/tready/tlast/tkeep`。
3. 复位统一低有效 `rst_n`，并在各时钟域同步释放。
4. 跨时钟数据流必须通过异步 FIFO 或等价 CDC 结构。
5. 单 bit 控制跨域使用 2FF 同步，多 bit 控制使用握手/锁存方案。

### 3.4 参数化与可观测规范

1. 参数必须明确支持范围，限制条件应在仿真期可报错。
2. 关键长度与计数参数使用 `localparam integer`，避免位宽截断隐患。
3. 不可回压链路需提供溢出可观测量（至少 `overflow_sticky`，建议 `overflow_cnt`）。
4. 关键中间节点建议预留 DDR 抓取或调试 tap。

### 3.5 约束与接口命名规范

- 时钟约束统一在 `Constraints/`，命名建议 `<top>_<scope>.xdc`。
- 显式声明异步时钟组，避免错误跨域收敛。
- 顶层控制口（`*_en/*_sel/*_cfg`）必须有明确驱动来源，禁止悬空。

### 3.6 当前阶段下一步（对齐阶段 2）

1. 本地模拟回环 `loopback_prbs` 已通过，`external_rx` 最新 bitstream/XSA/Vitis smoke 也已就绪；下一步先把独立外部 QPSK 源真正送入 ADC，再用 J11 `rx_demod_bit/rx_demod_lock` 和 ILA 做可观测验证。
2. 接入外部源后优先运行 `scripts/check_external_rx_board.ps1` 做三次抓取和聚合摘要；第一关先看 ADC span 是否明显大于几十个 LSB，并看三次抓取是否稳定。若仍只有个位数，先查外部源、模拟链路、ADC 输入偏置/供电和连接。
3. 若 ADC span 正常，再检查 lock ratio、lock score、I/Q 幅度、timing phase 和 `nco_freq_corr` Hz 换算值；已知外部源频偏方向时可用 `-ExpectNcoSign` 或 `--expect-nco-sign` 把 NCO 方向纳入 PASS/FAIL；若外部源发 Gray 循环，则追加 `--check-gray-cycle` 做更接近验收的符号序列检查。
4. 外部信号建议先从约 `7 MHz` 载波、`2 Msym/s`、中等 ADC 幅度开始；若 `rx_demod_lock` 不稳定，优先同时抓取 ADC 原始样本做离线频谱/星座交叉验证。
5. 针对真实外部 QPSK 输入继续强化锁前宽频偏捕获、误码统计和 ILA/离线交叉验证；当前锁后 Costas-like PI 和候选质量评分已通过 demod 单元与顶层 external-RX 的 `+15 kHz/-15 kHz`、`+35 kHz/-35 kHz` 回归，以及锁后正/负向漂移仿真回归，但不能替代完整外部同步链。
6. 保留 ADC 原始样本 DMA 搬运，用离线脚本交叉验证在线判决。
7. 后续再进入协议化上位机数据输入与误码统计闭环。
