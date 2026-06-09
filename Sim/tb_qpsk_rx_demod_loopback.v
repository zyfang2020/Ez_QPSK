`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_qpsk_rx_demod_loopback
// Purpose:
//   Verify the stage-2 PL RX demod branch with local TX digital loopback:
//   qpsk_test_gen -> qpsk_tx_single_dac -> ad9762_driver -> adc_data
//   -> ad9215_capture -> qpsk_rx_fixed_demod.
// -----------------------------------------------------------------------------
module tb_qpsk_rx_demod_loopback;

localparam integer ADC_DW = 10;
localparam integer DAC_DW = 12;
localparam integer RX_DW = 16;
localparam integer FIFO_DEPTH = 512;
localparam integer PKT_LEN = 128;
localparam integer TARGET_LOCKED_SYMS = 160;

reg                       clk;
reg                       rst_n;
reg  [ADC_DW-1:0]         adc_data;
wire                      clk_adc;
wire                      clk_dac;
wire [DAC_DW-1:0]         dac_data;
wire [RX_DW-1:0]          m_axis_rx_tdata;
wire [((RX_DW+7)/8)-1:0]  m_axis_rx_tkeep;
wire                      m_axis_rx_tvalid;
wire                      m_axis_rx_tlast;
reg                       m_axis_rx_tready;

wire [1:0]                rx_sym_dbg;
wire                      rx_valid_dbg;
wire                      rx_lock_dbg;
wire [5:0]                rx_best_phase_dbg;
wire [3:0]                rx_phase_bin_dbg;
wire [7:0]                rx_lock_score_dbg;

integer                   rx_valid_cnt;
integer                   locked_cnt;
reg                       locked_seen;
reg [1:0]                 prev_locked_sym;
reg [1:0]                 expected_next_sym;

assign rx_sym_dbg = u_dut.rx_demod_sym_dbg;
assign rx_valid_dbg = u_dut.rx_demod_valid_dbg;
assign rx_lock_dbg = u_dut.rx_demod_lock_dbg;
assign rx_best_phase_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_best_phase;
assign rx_phase_bin_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_phase_bin;
assign rx_lock_score_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_lock_score;

task tb_fail;
    input [8*96-1:0] msg;
    begin
        $display("[TB_QPSK_RX_DEMOD][FAIL] %0t ns: %0s", $time, msg);
        $display("[TB_QPSK_RX_DEMOD][DBG] valid=%0d locked=%0d sym=%b phase=%0d rot=%0d score=%0d",
                 rx_valid_cnt, locked_cnt, rx_sym_dbg, rx_best_phase_dbg,
                 rx_phase_bin_dbg, rx_lock_score_dbg);
        $finish;
    end
endtask

function [1:0] gray_next;
    input [1:0] cur;
    begin
        case (cur)
            2'b00: gray_next = 2'b01;
            2'b01: gray_next = 2'b11;
            2'b11: gray_next = 2'b10;
            2'b10: gray_next = 2'b00;
            default: gray_next = 2'b00;
        endcase
    end
endfunction

initial clk = 1'b0;
always #5 clk = ~clk;  // 100 MHz sample/AXI clock plan for current stage

pl_comm_top_fixed_cfg #(
    .ADC_DW(ADC_DW),
    .DAC_DW(DAC_DW),
    .RX_DW(RX_DW),
    .FIFO_DEPTH(FIFO_DEPTH),
    .PKT_LEN(PKT_LEN),
    .FIXED_TX_EN(1),
    .FIXED_RX_EN(1)
) u_dut (
    .clk_io(clk),
    .clk_axi(clk),
    .clk_adc(clk_adc),
    .clk_dac(clk_dac),
    .rst_n(rst_n),
    .adc_data(adc_data),
    .dac_data(dac_data),
    .m_axis_rx_tdata(m_axis_rx_tdata),
    .m_axis_rx_tkeep(m_axis_rx_tkeep),
    .m_axis_rx_tvalid(m_axis_rx_tvalid),
    .m_axis_rx_tready(m_axis_rx_tready),
    .m_axis_rx_tlast(m_axis_rx_tlast)
);

// Digital board-loopback approximation. The DUT samples ADC data on the
// opposite edge, so updating here gives a half-cycle stable window.
always @(posedge clk_adc or negedge rst_n) begin
    if (!rst_n) begin
        adc_data <= {ADC_DW{1'b0}};
    end else begin
        adc_data <= dac_data[DAC_DW-1 -: ADC_DW];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        m_axis_rx_tready <= 1'b0;
    end else begin
        m_axis_rx_tready <= 1'b1;
    end
end

always @(posedge clk_adc or negedge rst_n) begin
    if (!rst_n) begin
        rx_valid_cnt      <= 0;
        locked_cnt        <= 0;
        locked_seen       <= 1'b0;
        prev_locked_sym   <= 2'b00;
        expected_next_sym <= 2'b00;
    end else begin
        if (rx_valid_dbg) begin
            rx_valid_cnt <= rx_valid_cnt + 1;

            if ((^rx_sym_dbg) === 1'bx) begin
                tb_fail("ERR_RX_SYMBOL_XZ");
            end

            if (rx_lock_dbg) begin
                if (!locked_seen) begin
                    locked_seen     <= 1'b1;
                    locked_cnt      <= 1;
                    prev_locked_sym <= rx_sym_dbg;
                    $display("[TB_QPSK_RX_DEMOD][INFO] %0t ns: lock acquired, sym=%b phase=%0d rot=%0d score=%0d",
                             $time, rx_sym_dbg, rx_best_phase_dbg,
                             rx_phase_bin_dbg, rx_lock_score_dbg);
                end else begin
                    expected_next_sym = gray_next(prev_locked_sym);
                    if (rx_sym_dbg !== expected_next_sym) begin
                        tb_fail("ERR_GRAY_SEQUENCE_MISMATCH");
                    end
                    prev_locked_sym <= rx_sym_dbg;
                    locked_cnt <= locked_cnt + 1;
                end

                if (locked_cnt >= TARGET_LOCKED_SYMS) begin
                    $display("[TB_QPSK_RX_DEMOD][PASS] %0t ns: RX demod loopback Gray cycle recovered, locked_symbols=%0d valid_symbols=%0d phase=%0d rot=%0d score=%0d",
                             $time, locked_cnt, rx_valid_cnt, rx_best_phase_dbg,
                             rx_phase_bin_dbg, rx_lock_score_dbg);
                    $finish;
                end
            end else if (locked_seen) begin
                tb_fail("ERR_LOCK_DROPPED");
            end
        end
    end
end

initial begin
    rst_n = 1'b0;
    adc_data = {ADC_DW{1'b0}};
    m_axis_rx_tready = 1'b0;

    repeat (20) @(posedge clk);
    rst_n = 1'b1;
end

initial begin
    #3000000;
    tb_fail("ERR_TIMEOUT");
end

endmodule
