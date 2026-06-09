`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_qpsk_rx_demod_external_drift
// Purpose:
//   Exercise the PL RX demod core with an external-like QPSK source.  The source
//   uses the nominal fixed 7 MHz carrier plus residual carrier offset, but its
//   symbol clock is intentionally independent from the RX SPS=50 cadence.
// -----------------------------------------------------------------------------
module tb_qpsk_rx_demod_external_drift;

localparam integer ADC_DW = 10;
localparam integer PHASE_W = 24;
localparam integer SPS = 50;
localparam integer TARGET_LOCKED_SYMS = 520;
localparam [PHASE_W-1:0] RX_PHASE_INC = 24'h11EB85;

localparam real FS_HZ = 100000000.0;
localparam real CARRIER_HZ = 7000000.0;
localparam real CARRIER_OFFSET_HZ = 3000.0;
localparam real TX_SYMBOL_RATE_HZ = 2010000.0;
localparam real PHASE_OFFSET_DEG = 123.0;
localparam real ADC_AMPLITUDE = 150.0;
localparam real ADC_DC_OFFSET = -18.0;
localparam real SYMBOL_PHASE_OFFSET = 0.37;
localparam real PI = 3.14159265358979323846;
localparam real PHASE_STEP_RAD = 2.0 * PI * (CARRIER_HZ + CARRIER_OFFSET_HZ) / FS_HZ;
localparam real PHASE_OFFSET_RAD = PI * PHASE_OFFSET_DEG / 180.0;
localparam real SYMBOL_STEP = TX_SYMBOL_RATE_HZ / FS_HZ;

reg                       clk;
reg                       rst_n;
reg  [ADC_DW-1:0]         adc_data;
wire                      s_ready;
wire [1:0]                rx_sym;
wire                      rx_valid;
wire                      rx_lock;
wire signed [15:0]        dbg_i;
wire signed [15:0]        dbg_q;
wire [5:0]                dbg_best_phase;
wire [3:0]                dbg_phase_bin;
wire [7:0]                dbg_lock_score;

integer sample_count;
integer rx_valid_cnt;
integer locked_cnt;
integer quantized;
integer tx_sym_idx;
integer tx_ref_idx;
integer tx_rx_offset;
reg locked_seen;
reg [1:0] prev_locked_sym;
reg [1:0] expected_next_sym;
reg [1:0] expected_tx_sym;
reg [1:0] tx_sym;
real tx_phase;
real tx_symbol_phase;
real sym_i;
real sym_q;
real rf_sample;

qpsk_rx_fixed_demod #(
    .ADC_DW(ADC_DW),
    .PHASE_W(PHASE_W),
    .NCO_W(12),
    .MIX_W(24),
    .SUM_W(32),
    .CORR_W(24),
    .SPS(SPS),
    .LOCK_THRESHOLD(40)
) u_rx (
    .clk(clk),
    .rst_n(rst_n),
    .en(1'b1),
    .s_adc(adc_data),
    .s_valid(1'b1),
    .s_ready(s_ready),
    .cfg_phase_inc(RX_PHASE_INC),
    .m_sym(rx_sym),
    .m_valid(rx_valid),
    .m_lock(rx_lock),
    .dbg_i(dbg_i),
    .dbg_q(dbg_q),
    .dbg_best_phase(dbg_best_phase),
    .dbg_phase_bin(dbg_phase_bin),
    .dbg_lock_score(dbg_lock_score)
);

task tb_fail;
    input [8*96-1:0] msg;
    begin
        $display("[TB_QPSK_RX_EXT][FAIL] %0t ns: %0s", $time, msg);
        $display("[TB_QPSK_RX_EXT][DBG] valid=%0d locked=%0d sym=%b I=%0d Q=%0d phase=%0d rot=%0d score=%0d tx_sym_idx=%0d tx_sym_phase=%0f timing_acc=%0d early_valid=%0d early_metric=%0d",
                 rx_valid_cnt, locked_cnt, rx_sym, dbg_i, dbg_q,
                 dbg_best_phase, dbg_phase_bin, dbg_lock_score,
                 tx_sym_idx, tx_symbol_phase, u_rx.timing_track_acc,
                 u_rx.timing_early_valid, u_rx.timing_early_metric);
        $finish;
    end
endtask

function [1:0] gray_seq4;
    input integer idx;
    begin
        case (idx[1:0])
            2'd0: gray_seq4 = 2'b00;
            2'd1: gray_seq4 = 2'b01;
            2'd2: gray_seq4 = 2'b11;
            2'd3: gray_seq4 = 2'b10;
            default: gray_seq4 = 2'b00;
        endcase
    end
endfunction

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

function integer gray_index;
    input [1:0] sym;
    begin
        case (sym)
            2'b00: gray_index = 0;
            2'b01: gray_index = 1;
            2'b11: gray_index = 2;
            2'b10: gray_index = 3;
            default: gray_index = 0;
        endcase
    end
endfunction

function integer round_real;
    input real x;
    begin
        if (x >= 0.0) begin
            round_real = $rtoi(x + 0.5);
        end else begin
            round_real = $rtoi(x - 0.5);
        end
    end
endfunction

function [ADC_DW-1:0] clip_adc;
    input integer x;
    begin
        if (x < 0) begin
            clip_adc = {ADC_DW{1'b0}};
        end else if (x > ((1 << ADC_DW) - 1)) begin
            clip_adc = {ADC_DW{1'b1}};
        end else begin
            clip_adc = x[ADC_DW-1:0];
        end
    end
endfunction

initial clk = 1'b0;
always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        adc_data <= (1 << (ADC_DW-1));
        sample_count <= 0;
        tx_sym_idx <= 0;
        tx_phase = PHASE_OFFSET_RAD;
        tx_symbol_phase = SYMBOL_PHASE_OFFSET;
    end else begin
        tx_sym_idx = $rtoi(tx_symbol_phase);
        tx_sym = gray_seq4(tx_sym_idx);
        sym_i = tx_sym[0] ? -1.0 : 1.0;
        sym_q = tx_sym[1] ? -1.0 : 1.0;
        rf_sample = (sym_i * $cos(tx_phase)) - (sym_q * $sin(tx_phase));
        quantized = (1 << (ADC_DW-1)) + round_real(ADC_DC_OFFSET +
                    (ADC_AMPLITUDE * rf_sample));
        adc_data <= clip_adc(quantized);

        tx_phase = tx_phase + PHASE_STEP_RAD;
        if (tx_phase > (2.0 * PI)) begin
            tx_phase = tx_phase - (2.0 * PI);
        end

        tx_symbol_phase = tx_symbol_phase + SYMBOL_STEP;
        sample_count <= sample_count + 1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_valid_cnt <= 0;
        locked_cnt <= 0;
        locked_seen <= 1'b0;
        prev_locked_sym <= 2'b00;
        expected_next_sym <= 2'b00;
        expected_tx_sym <= 2'b00;
        tx_ref_idx <= 0;
        tx_rx_offset <= 0;
    end else begin
        if (rx_valid) begin
            rx_valid_cnt <= rx_valid_cnt + 1;
            tx_ref_idx = $rtoi(SYMBOL_PHASE_OFFSET + (sample_count * SYMBOL_STEP));

            if ((^rx_sym) === 1'bx) begin
                tb_fail("ERR_RX_SYMBOL_XZ");
            end

            if (rx_lock) begin
                if (!locked_seen) begin
                    locked_seen <= 1'b1;
                    locked_cnt <= 1;
                    prev_locked_sym <= rx_sym;
                    tx_rx_offset <= tx_ref_idx - gray_index(rx_sym);
                    $display("[TB_QPSK_RX_EXT][INFO] %0t ns: lock acquired, sym=%b I=%0d Q=%0d phase=%0d rot=%0d score=%0d tx_ref=%0d offset=%0d",
                             $time, rx_sym, dbg_i, dbg_q, dbg_best_phase,
                             dbg_phase_bin, dbg_lock_score, tx_ref_idx,
                             tx_ref_idx - gray_index(rx_sym));
                end else begin
                    expected_next_sym = gray_next(prev_locked_sym);
                    if (rx_sym !== expected_next_sym) begin
                        tb_fail("ERR_GRAY_SEQUENCE_MISMATCH");
                    end

                    expected_tx_sym = gray_seq4(tx_ref_idx - tx_rx_offset);
                    if (rx_sym !== expected_tx_sym) begin
                        tb_fail("ERR_TX_REFERENCE_MISMATCH");
                    end

                    prev_locked_sym <= rx_sym;
                    locked_cnt <= locked_cnt + 1;
                end

                if (locked_cnt >= TARGET_LOCKED_SYMS) begin
                    $display("[TB_QPSK_RX_EXT][PASS] %0t ns: external-like RX demod Gray cycle recovered, locked_symbols=%0d valid_symbols=%0d phase=%0d rot=%0d score=%0d",
                             $time, locked_cnt, rx_valid_cnt, dbg_best_phase,
                             dbg_phase_bin, dbg_lock_score);
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
    adc_data = (1 << (ADC_DW-1));
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
end

initial begin
    #4000000;
    tb_fail("ERR_TIMEOUT");
end

endmodule
