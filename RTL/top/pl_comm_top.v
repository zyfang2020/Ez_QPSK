// -----------------------------------------------------------------------------
// 模块: pl_comm_top
// 功能: 当前阶段 PL 最小可运行通信链路顶层
// TX: (tx_test_pattern | qpsk_test_gen/external_sym -> qpsk_tx_single_dac) -> ad9762_driver
// RX: ad9215_capture -> async_fifo -> pkt_gen -> axis_to_dma_pkt -> AXIS DMA
// 说明:
//   - TX/RX 采用独立使能: tx_en / rx_en
//   - tx_en=0 时，ad9762_driver 在 HOLD_LAST=0 配置下持续输出 0 电平
// -----------------------------------------------------------------------------
module pl_comm_top #(
    parameter integer ADC_DW = 10,
    parameter integer DAC_DW = 12,
    parameter integer RX_DW = 16,
    parameter integer FIFO_DEPTH = 2048,
    parameter integer PKT_LEN = 4096
) (
    // 时钟与全局复位
    // 纯 RTL 顶层当前约定：
    // - clk_axi 作为板级输入系统时钟
    // - clk_adc / clk_dac 为导出到板外 ADC / DAC 的时钟
    // - ADC 侧使用 clk_adc 的相反边沿做采样，以形成半周期错开
    output wire                      clk_adc,
    input  wire                      clk_axi,
    output wire                      clk_dac,
    input  wire                      rst_n,
    // 板级 ADC / DAC 数据口
    input  wire [ADC_DW-1:0]         adc_data,
    output wire [DAC_DW-1:0]         dac_data,
    // TX/RX 总使能
    input  wire                      tx_en,
    input  wire                      rx_en,
    // TX 测试源配置
    input  wire [1:0]                tx_mode_sel,
    input  wire [DAC_DW-1:0]         tx_const_data,
    // TX 源选择: 0=tx_test_pattern, 1=QPSK 调制链
    input  wire                      tx_src_sel,
    // QPSK 内部测试源配置
    input  wire                      qpsk_en,
    input  wire [1:0]                qpsk_mode_sel,
    input  wire [1:0]                qpsk_cfg_sym,
    // QPSK 符号输入选择: 0=内部 qpsk_test_gen, 1=预留流接口 qpsk_sym_*
    input  wire                      qpsk_src_sel,
    input  wire [1:0]                qpsk_sym_data,
    input  wire                      qpsk_sym_valid,
    output wire                      qpsk_sym_ready,
    // 输出到 AXI DMA S2MM 的 AXIS 口
    output wire [RX_DW-1:0]          m_axis_rx_tdata,
    output wire [((RX_DW+7)/8)-1:0]  m_axis_rx_tkeep,
    output wire                      m_axis_rx_tvalid,
    input  wire                      m_axis_rx_tready,
    output wire                      m_axis_rx_tlast
);

wire rst_n_adc;
wire rst_n_axi;
wire rst_n_dac;

wire [DAC_DW-1:0] tx_test_data;
wire tx_test_valid;
wire tx_test_ready;

wire [DAC_DW-1:0] tx_qpsk_data;
wire tx_qpsk_valid;
wire tx_qpsk_ready;

wire [DAC_DW-1:0] tx_data;
wire tx_valid;
wire tx_ready;
wire tx_test_path_en;
wire tx_qpsk_path_en;

wire [1:0] qpsk_gen_sym;
wire qpsk_gen_valid;
wire qpsk_gen_ready;

wire [1:0] qpsk_mux_sym;
wire qpsk_mux_valid;
wire qpsk_mux_ready;

wire [RX_DW-1:0] cap_data;
wire cap_valid;
wire cap_ready;
wire cap_valid_gated;

wire [RX_DW-1:0] fifo_data;
wire fifo_valid;
wire fifo_ready;

wire [RX_DW-1:0] pkt_data;
wire pkt_valid;
wire pkt_ready;
wire pkt_last;

localparam [23:0] QPSK_PHASE_INC_DEFAULT = 24'h133333;

// 当前纯 RTL 顶层使用单一板级时钟：
// - 直接转发为 ADC / DAC 板级时钟输出
// - FPGA 内部对 DAC 采用相反边沿更新数据，对 ADC 采用相反边沿采样
assign clk_adc = clk_axi;
assign clk_dac = clk_axi;

// 各时钟域复位同步
reset_sync u_reset_sync_adc (
    .clk(clk_adc),
    .rst_n_in(rst_n),
    .rst_n_out(rst_n_adc)
);

reset_sync u_reset_sync_axi (
    .clk(clk_axi),
    .rst_n_in(rst_n),
    .rst_n_out(rst_n_axi)
);

reset_sync u_reset_sync_dac (
    .clk(clk_dac),
    .rst_n_in(rst_n),
    .rst_n_out(rst_n_dac)
);

// TX: 产生测试数据
tx_test_pattern #(
    .DW(DAC_DW)
) u_tx_test_pattern (
    .clk(clk_dac),
    .rst_n(rst_n_dac),
    .en(tx_en & (~tx_src_sel)),
    .mode_sel(tx_mode_sel),
    .cfg_const(tx_const_data),
    .m_data(tx_test_data),
    .m_valid(tx_test_valid),
    .m_ready(tx_test_ready)
);

// TX: QPSK 内部符号源
qpsk_test_gen u_qpsk_test_gen (
    .clk(clk_dac),
    .rst_n(rst_n_dac),
    .en(qpsk_en & tx_en & tx_src_sel),
    .mode_sel(qpsk_mode_sel),
    .cfg_sym(qpsk_cfg_sym),
    .m_sym(qpsk_gen_sym),
    .m_valid(qpsk_gen_valid),
    .m_ready(qpsk_gen_ready)
);

// QPSK 符号输入复用（当前主要使用内部源；外部接口保留）
assign qpsk_mux_sym   = qpsk_src_sel ? qpsk_sym_data  : qpsk_gen_sym;
assign qpsk_mux_valid = tx_qpsk_path_en ? (qpsk_src_sel ? qpsk_sym_valid : qpsk_gen_valid) : 1'b0;
assign qpsk_gen_ready = ((!qpsk_src_sel) && tx_qpsk_path_en) ? qpsk_mux_ready : 1'b0;
assign qpsk_sym_ready = (qpsk_src_sel && tx_qpsk_path_en) ? qpsk_mux_ready : 1'b0;

// TX: QPSK 符号 -> 成型 -> 上变频 -> DAC 采样流
qpsk_tx_single_dac #(
    .DAC_DW(DAC_DW),
    .SYM_W(12),
    .MIX_W(18),
    .GAIN_W(22),
    .PHASE_W(24),
    .SHAPER_SPS(50),
    .SHAPER_BETA_SEL(2),
    .TX_GAIN_NUM(6)
) u_qpsk_tx_single_dac (
    .clk(clk_dac),
    .rst_n(rst_n_dac),
    .s_sym(qpsk_mux_sym),
    .s_valid(qpsk_mux_valid),
    .s_ready(qpsk_mux_ready),
    .cfg_rrc_beta_sel(2'd2),
    .cfg_phase_inc(QPSK_PHASE_INC_DEFAULT),
    .m_data(tx_qpsk_data),
    .m_valid(tx_qpsk_valid),
    .m_ready(tx_qpsk_ready)
);

assign tx_test_path_en = tx_en && (!tx_src_sel);
assign tx_qpsk_path_en = tx_en && tx_src_sel && qpsk_en;

assign tx_data       = tx_qpsk_path_en ? tx_qpsk_data :
                       tx_test_path_en ? tx_test_data :
                       {DAC_DW{1'b0}};
assign tx_valid      = tx_qpsk_path_en ? tx_qpsk_valid :
                       tx_test_path_en ? tx_test_valid :
                       1'b0;
assign tx_qpsk_ready = tx_qpsk_path_en ? tx_ready : 1'b0;
assign tx_test_ready = tx_test_path_en ? tx_ready : 1'b0;

// TX: 推送到 DAC
ad9762_driver #(
    .DW(DAC_DW),
    .UPDATE_NEGEDGE(1),
    // TX 关闭时希望 DAC 回零（例如 RX 模式）
    .HOLD_LAST(0)
) u_ad9762_driver (
    .clk_dac(clk_dac),
    .rst_n(rst_n_dac),
    .s_data(tx_data),
    .s_valid(tx_valid),
    .s_ready(tx_ready),
    .dac_data(dac_data)
);

// RX: ADC 并口适配为流
ad9215_capture #(
    .ADC_DW(ADC_DW),
    .OUT_DW(RX_DW),
    .SAMPLE_NEGEDGE(1)
) u_ad9215_capture (
    .clk_adc(clk_adc),
    .rst_n(rst_n_adc),
    .adc_data(adc_data),
    .m_data(cap_data),
    .m_valid(cap_valid),
    .m_ready(cap_ready)
);

assign cap_valid_gated = cap_valid & rx_en;

// RX: ADC -> AXI 跨时钟域
stream_async_fifo #(
    .DW(RX_DW),
    .DEPTH(FIFO_DEPTH)
) u_stream_async_fifo (
    .s_clk(clk_adc),
    .s_rst_n(rst_n_adc),
    .s_data(cap_data),
    .s_valid(cap_valid_gated),
    .s_ready(cap_ready),
    .m_clk(clk_axi),
    .m_rst_n(rst_n_axi),
    .m_data(fifo_data),
    .m_valid(fifo_valid),
    .m_ready(fifo_ready)
);

// RX: 固定长度分包，产生 last
stream_pkt_gen #(
    .DW(RX_DW),
    .PKT_LEN(PKT_LEN)
) u_stream_pkt_gen (
    .clk(clk_axi),
    .rst_n(rst_n_axi),
    .s_data(fifo_data),
    .s_valid(fifo_valid),
    .s_ready(fifo_ready),
    .m_data(pkt_data),
    .m_valid(pkt_valid),
    .m_ready(pkt_ready),
    .m_last(pkt_last)
);

// RX: 内部流 -> AXI-Stream(DMA)
axis_to_dma_pkt #(
    .DW(RX_DW)
) u_axis_to_dma_pkt (
    .s_data(pkt_data),
    .s_valid(pkt_valid),
    .s_ready(pkt_ready),
    .s_last(pkt_last),
    .m_axis_tdata(m_axis_rx_tdata),
    .m_axis_tkeep(m_axis_rx_tkeep),
    .m_axis_tvalid(m_axis_rx_tvalid),
    .m_axis_tready(m_axis_rx_tready),
    .m_axis_tlast(m_axis_rx_tlast)
);

endmodule
