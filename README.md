# Ez_QPSK 项目说明（AX7020 / Zynq-7020）

## 1. 目标与阶段

### 1.1 最终目标

- 在 AX7020（Zynq-7020）上实现 QPSK 调制与解调完整链路。
- 目标符号率：`2 Msym/s`。
- 当前发射链默认工作点：`clk_dac = 100 MHz`，`SHAPER_SPS = 50`，对应约 `2 Msym/s`。
- 当前频点规划：目标信道约 `6~9 MHz`，建议载波中心频率 `7.5 MHz`。

### 1.2 分阶段路线

1. 阶段 1：固定数据发送 + 离线解调  
   目标：先打通“可控发送 + 可复现采集 + PC 离线验证”闭环。
2. 阶段 2：固定数据发送 + 在线解调  
   目标：在板端完成实时解调链，形成在线观测与判决能力。
3. 阶段 3：协议化数据输入  
   目标：确定链路协议，从上位机获取数据包并驱动调制发送。

### 1.3 当前进度（当前处于阶段 1）

- 已完成：QPSK 调制链 RTL 实现与仿真验证（未上板）。
- 已完成：`qpsk_test_gen -> qpsk_tx_single_dac -> ad9762_driver` 单 DAC 发射链仿真验证。
- 已完成：ADC 侧采集与 AXI 搬运通路 RTL 实现（`ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt`）。
- 当前策略：先把采样数据搬运到 DDR，再导出到电脑做离线解调。
- 未完成：上板联调、在线解调闭环、协议化上位机数据接入。

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

### 2.2 时钟与复位

- 时钟域：`clk_adc`、`clk_axi`、`clk_dac`。
- 全局复位：低有效 `rst_n`。
- 复位同步：通过 `RTL/utils/reset_sync.v` 在各时钟域同步释放。
- 约束文件：
  - `Constraints/pl_comm_top_clocks.xdc`
  - `Constraints/pl_comm_top_io_template.xdc`

### 2.3 顶层与模式说明

- 顶层：`RTL/top/pl_comm_top.v`
  - 支持 TX/RX 独立使能（`tx_en` / `rx_en`）。
  - `tx_en=0` 时，DAC 输出回零（`ad9762_driver` 配置 `HOLD_LAST=0`）。
  - TX 源支持 `tx_test_pattern` 与 QPSK 调制链选择（`tx_src_sel`）。
  - QPSK 输入支持内部测试源与外部符号口选择（`qpsk_src_sel`）。
- 固定配置封装：`RTL/top/pl_comm_top_fixed_cfg.v`
  - 当前用于最小 bring-up：固定走 QPSK 内部测试发送路径。

### 2.4 目录与文件作用（按工程根目录）

- `RTL/`：可综合 RTL 源码根目录。
- `RTL/top/`：顶层集成与固定配置封装（如 `pl_comm_top*`）。
- `RTL/modem/`：QPSK 调制链相关模块（映射、成型、上变频、DAC 格式转换）。
- `RTL/drivers/`：器件与总线侧驱动/适配（AD9215、AD9762、AXIS 适配）。
- `RTL/source/`：测试数据源/激励源模块（`tx_test_pattern`、`qpsk_test_gen`）。
- `RTL/buffer/`：跨时钟域缓冲模块（异步 FIFO）。
- `RTL/utils/`：公共工具模块（复位同步、分包等）。
- `RTL/ctrl/`：控制面模块预留目录（后续寄存器/配置控制逻辑放这里）。
- `Sim/`：仿真目录（testbench 与仿真文档）。
- `Constraints/`：约束目录（`.xdc`，包含时钟与 IO 约束模板）。
- `Tool/`：离线处理工具目录（算法验证、后处理脚本、辅助数据）。
- `scripts/`：自动化脚本目录（工程重建、综合、实现、批处理）。
- `README.md`：项目总说明（目标、阶段、工程说明、规范）。

### 2.5 当前仿真入口

- `Sim/tb_tx_chain_min.v`：TX 测试源到 DAC 驱动。
- `Sim/tb_rx_chain_min.v`：ADC 到 AXI 打包搬运链。
- `Sim/tb_qpsk_tx_chain_min.v`：legacy QPSK 发射链。
- `Sim/tb_qpsk_tx_single_dac_min.v`：推荐 QPSK 单 DAC 发射链（可导出 CSV）。
- 离线脚本：`Tool/matlab/qpsk_single_dac_demod_demo.m`（读取 CSV 做离线解调示例）。

### 2.6 当前注意事项

- 当前文档口径为“阶段 1：离线解调优先”，不宣称在线解调已完成。
- 当前“ADC->AXI->DDR”链路重点是可搬运、可观测、可导出。
- `qpsk_sym_*` 为后续协议化输入预留接口，当前主要使用内部 `qpsk_test_gen`。
- RX 侧 AXIS 口通常在 Vivado BD 内连接 DMA，不作为外部引脚导出。

### 2.7 本机 Vivado 命令行路径（Windows）

- Vivado 安装路径（已确认）：
  - `D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat`
- 在工程根目录批处理运行单 DAC TX 仿真（不打开 GUI）：
  - `D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl`
- PowerShell 等价命令：
  - `& "D:\Program_Files\Xilinx\Vivado\2020.2\bin\vivado.bat" -mode batch -source scripts/run_qpsk_tx_single_dac_sim.tcl`

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
- `scripts/`：放工程自动化脚本（重建工程、综合、实现、批处理流程）。
- 根目录文档/工程文件约定：
- `README.md`：项目总说明与阶段目标、规范基线。
- `Sim/README.md`：仿真运行方法与通过判据。
- `Tool/README.md`：工具脚本目录约定与使用说明。
- `Ez_QPSK.xpr`：Vivado 工程入口文件（可选保留用于快速打开）。

### 3.2 Git 管理规范

- `.gitignore`：忽略 Vivado 生成目录和运行日志（如 `*.runs/`、`*.cache/`、`*.sim/`）。
- `.gitattributes`：统一文本 LF；`*.bit/*.bin/*.mcs/*.dcp/*.ltx` 标记为二进制。
- 建议仅提交可复现工程所需文件：RTL、约束、脚本、仿真、文档。

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

### 3.6 当前阶段下一步（对齐阶段 1）

1. 完成板端 DMA S2MM + DDR 搬运联调与稳定性验证。
2. 建立导出数据到 PC 的自动化流程（原始数据与元信息）。
3. 固化离线解调判据（频偏、相位恢复、EVM/BER 统计口径）。
4. 在离线闭环稳定后进入阶段 2（在线解调）。
