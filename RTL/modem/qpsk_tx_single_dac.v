// -----------------------------------------------------------------------------
// 模块: qpsk_tx_single_dac
// 功能: 单路 DAC 的 QPSK 发射基带链路
// 链路:
//   符号(2bit) -> QPSK映射(I/Q) -> 脉冲成型 -> NCO上变频 -> DAC格式化
// 说明:
//   - 本模块输出可直接连接 ad9762_driver 的无符号采样流
//   - 当前成型采用 RRC（SPS=50，roll-off 可参数选择）
// -----------------------------------------------------------------------------
module qpsk_tx_single_dac #(
    parameter integer DAC_DW = 12,
    parameter integer SYM_W = 12,
    parameter integer MIX_W = 18,
    parameter integer GAIN_W = 22,
    parameter integer PHASE_W = 24,
    parameter integer SHAPER_SPS = 50,
    parameter integer SHAPER_BETA_SEL = 2, // 0:0.20, 1:0.35, 2:0.50
    parameter integer TX_GAIN_NUM = 6
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [1:0]                s_sym,
    input  wire                      s_valid,
    output wire                      s_ready,
    input  wire [1:0]                cfg_rrc_beta_sel,
    input  wire [PHASE_W-1:0]        cfg_phase_inc,
    output wire [DAC_DW-1:0]         m_data,
    output wire                      m_valid,
    input  wire                      m_ready
);

wire signed [SYM_W-1:0] map_i;
wire signed [SYM_W-1:0] map_q;
wire                    map_valid;
wire                    map_ready;

wire signed [SYM_W-1:0] shp_i;
wire signed [SYM_W-1:0] shp_q;
wire                    shp_valid;
wire                    shp_ready;

wire signed [MIX_W-1:0] mix_data;
wire signed [GAIN_W-1:0] mix_data_gain;
wire                    mix_valid;
wire                    mix_ready;

qpsk_symbol_mapper #(
    .SYM_W(SYM_W),
    .SYM_AMP($signed(1 << (SYM_W-2)))
) u_qpsk_symbol_mapper (
    .clk(clk),
    .rst_n(rst_n),
    .s_sym(s_sym),
    .s_valid(s_valid),
    .s_ready(s_ready),
    .m_i(map_i),
    .m_q(map_q),
    .m_valid(map_valid),
    .m_ready(map_ready)
);

iq_pulse_shaper #(
    .W(SYM_W),
    .SPS(SHAPER_SPS),
    .RRC_BETA_SEL(SHAPER_BETA_SEL)
) u_iq_pulse_shaper (
    .clk(clk),
    .rst_n(rst_n),
    .s_i(map_i),
    .s_q(map_q),
    .s_valid(map_valid),
    .s_ready(map_ready),
    .m_i(shp_i),
    .m_q(shp_q),
    .m_valid(shp_valid),
    .cfg_rrc_beta_sel(cfg_rrc_beta_sel),
    .m_ready(shp_ready)
);

iq_nco_upconverter #(
    .IN_W(SYM_W),
    .NCO_W(12),
    .PHASE_W(PHASE_W),
    .OUT_W(MIX_W)
) u_iq_nco_upconverter (
    .clk(clk),
    .rst_n(rst_n),
    .s_i(shp_i),
    .s_q(shp_q),
    .s_valid(shp_valid),
    .s_ready(shp_ready),
    .cfg_phase_inc(cfg_phase_inc),
    .m_data(mix_data),
    .m_valid(mix_valid),
    .m_ready(mix_ready)
);

assign mix_data_gain = $signed(mix_data) * $signed(TX_GAIN_NUM);

signed_to_offset_dac #(
    .IN_W(GAIN_W),
    .DAC_DW(DAC_DW)
) u_signed_to_offset_dac (
    .clk(clk),
    .rst_n(rst_n),
    .s_data(mix_data_gain),
    .s_valid(mix_valid),
    .s_ready(mix_ready),
    .m_data(m_data),
    .m_valid(m_valid),
    .m_ready(m_ready)
);

endmodule
