// -----------------------------------------------------------------------------
// 模块: pl_comm_top_fixed_cfg
// 功能: pl_comm_top 的固定配置封装（上板最小联调用）
// 说明:
//   - 默认同时启用 TX/RX（便于本地回环联调，可按需修改 FIXED_TX_EN/FIXED_RX_EN）
//   - 固定选择 QPSK 发射链 + 内部 qpsk_test_gen
//   - 外部 qpsk_sym_* 预留口不使用
//   - 纯 RTL 顶层当前使用 clk_axi 作为输入系统时钟，并导出 clk_adc/clk_dac
// -----------------------------------------------------------------------------
module pl_comm_top_fixed_cfg #(
    parameter integer ADC_DW = 10,
    parameter integer DAC_DW = 12,
    parameter integer RX_DW = 16,
    parameter integer FIFO_DEPTH = 2048,
    parameter integer PKT_LEN = 4096,
    parameter integer FIXED_TX_EN = 1,
    parameter integer FIXED_RX_EN = 1
) (
    output wire                      clk_adc,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_axi, ASSOCIATED_BUSIF m_axis_rx, ASSOCIATED_RESET rst_n" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_axi CLK" *)
    input  wire                      clk_axi,
    output wire                      clk_dac,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    input  wire                      rst_n,
    input  wire [ADC_DW-1:0]         adc_data,
    output wire [DAC_DW-1:0]         dac_data,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TDATA" *)
    output wire [RX_DW-1:0]          m_axis_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TKEEP" *)
    output wire [((RX_DW+7)/8)-1:0]  m_axis_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TVALID" *)
    output wire                      m_axis_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TREADY" *)
    input  wire                      m_axis_rx_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx TLAST" *)
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
        .adc_data(adc_data),
        .dac_data(dac_data),
        .tx_en(FIXED_TX_EN != 0),
        .rx_en(FIXED_RX_EN != 0),
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
