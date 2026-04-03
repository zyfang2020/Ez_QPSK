// -----------------------------------------------------------------------------
// 模块: pl_comm_top_fixed_cfg
// 功能: pl_comm_top 的固定配置封装（上板最小联调用）
// 说明:
//   - 固定 TX 模式，控制口全开
//   - 固定选择 QPSK 发射链 + 内部 qpsk_test_gen
//   - 外部 qpsk_sym_* 预留口不使用
// -----------------------------------------------------------------------------
module pl_comm_top_fixed_cfg #(
    parameter integer ADC_DW = 10,
    parameter integer DAC_DW = 12,
    parameter integer RX_DW = 16,
    parameter integer FIFO_DEPTH = 2048,
    parameter integer PKT_LEN = 4096
) (
    input  wire                      clk_adc,
    input  wire                      clk_axi,
    input  wire                      clk_dac,
    input  wire                      rst_n,
    input  wire [ADC_DW-1:0]         adc_data,
    output wire [DAC_DW-1:0]         dac_data,
    output wire [RX_DW-1:0]          m_axis_rx_tdata,
    output wire [((RX_DW+7)/8)-1:0]  m_axis_rx_tkeep,
    output wire                      m_axis_rx_tvalid,
    input  wire                      m_axis_rx_tready,
    output wire                      m_axis_rx_tlast
);

    localparam [1:0] TX_MODE_SEL_FIXED   = 2'd0;
    localparam [1:0] QPSK_MODE_SEL_FIXED = 2'd0;
    localparam [1:0] QPSK_CFG_SYM_FIXED  = 2'b00;

    pl_comm_top #(
        .ADC_DW(ADC_DW),
        .DAC_DW(DAC_DW),
        .RX_DW(RX_DW),
        .FIFO_DEPTH(FIFO_DEPTH),
        .PKT_LEN(PKT_LEN)
    ) u_pl_comm_top (
        .clk_adc(clk_adc),
        .clk_axi(clk_axi),
        .clk_dac(clk_dac),
        .rst_n(rst_n),
        .op_mode_tx(1'b1),
        .adc_data(adc_data),
        .dac_data(dac_data),
        .tx_en(1'b1),
        .tx_mode_sel(TX_MODE_SEL_FIXED),
        .tx_const_data({DAC_DW{1'b0}}),
        .tx_src_sel(1'b1),
        .qpsk_en(1'b1),
        .qpsk_mode_sel(QPSK_MODE_SEL_FIXED),
        .qpsk_cfg_sym(QPSK_CFG_SYM_FIXED),
        .qpsk_src_sel(1'b0),
        .qpsk_sym_data(2'b00),
        .qpsk_sym_valid(1'b0),
        .qpsk_sym_ready(),
        .m_axis_rx_tdata(m_axis_rx_tdata),
        .m_axis_rx_tkeep(m_axis_rx_tkeep),
        .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .m_axis_rx_tready(m_axis_rx_tready),
        .m_axis_rx_tlast(m_axis_rx_tlast)
    );

endmodule

