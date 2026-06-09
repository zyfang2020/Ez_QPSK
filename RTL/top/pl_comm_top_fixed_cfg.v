// -----------------------------------------------------------------------------
// Module: pl_comm_top_fixed_cfg
// Function: Fixed-configuration wrapper of pl_comm_top for board bring-up.
// Notes:
//   - TX/RX are enabled by default for loopback bring-up.
//   - clk_io drives the ADC/DAC side processing path and is forwarded to board IO.
//   - clk_axi drives the AXI/DMA side processing path.
// -----------------------------------------------------------------------------
module pl_comm_top_fixed_cfg #(
    parameter integer ADC_DW = 10,
    parameter integer DAC_DW = 12,
    parameter integer RX_DW = 16,
    parameter integer FIFO_DEPTH = 2048,
    parameter integer PKT_LEN = 100000,
    parameter integer FIXED_TX_EN = 1,
    parameter integer FIXED_RX_EN = 1
) (
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_io" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_io CLK" *)
    input  wire                      clk_io,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk_axi, ASSOCIATED_BUSIF m_axis_rx" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk_axi CLK" *)
    input  wire                      clk_axi,
    output wire                      clk_adc,
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
    output wire                      m_axis_rx_tlast,
    output wire                      rx_demod_bit,
    output wire                      rx_demod_lock,
    output wire [95:0]               rx_demod_dbg_bus
);

    localparam [1:0] TX_MODE_SEL_FIXED   = 2'd0;
    localparam [1:0] QPSK_MODE_SEL_FIXED = 2'd0;
    localparam [1:0] QPSK_CFG_SYM_FIXED  = 2'b00;

    (* keep = "true", mark_debug = "true" *) wire [1:0] rx_demod_sym_dbg;
    (* keep = "true", mark_debug = "true" *) wire       rx_demod_valid_dbg;
    (* keep = "true", mark_debug = "true" *) wire       rx_demod_lock_dbg;
    (* keep = "true", mark_debug = "true" *) wire [95:0] rx_demod_dbg_bus_dbg;

    assign rx_demod_bit  = rx_demod_sym_dbg[0];
    assign rx_demod_lock = rx_demod_lock_dbg;
    assign rx_demod_dbg_bus = rx_demod_dbg_bus_dbg;

    pl_comm_top #(
        .ADC_DW(ADC_DW),
        .DAC_DW(DAC_DW),
        .RX_DW(RX_DW),
        .FIFO_DEPTH(FIFO_DEPTH),
        .PKT_LEN(PKT_LEN)
    ) u_pl_comm_top (
        .clk_io(clk_io),
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
        .rx_demod_sym(rx_demod_sym_dbg),
        .rx_demod_valid(rx_demod_valid_dbg),
        .rx_demod_lock(rx_demod_lock_dbg),
        .rx_demod_dbg_bus(rx_demod_dbg_bus_dbg),
        .m_axis_rx_tdata(m_axis_rx_tdata),
        .m_axis_rx_tkeep(m_axis_rx_tkeep),
        .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .m_axis_rx_tready(m_axis_rx_tready),
        .m_axis_rx_tlast(m_axis_rx_tlast)
    );

endmodule
