`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_qpsk_rx_demod_random_external
// Purpose:
//   Exercise the RX demod with an external-like random QPSK source.  Unlike the
//   Gray-cycle tests, this does not provide a known repeating symbol pattern for
//   lock; the checker resolves only fixed latency and QPSK 90-degree ambiguity.
//   The source also includes residual carrier offset, slow amplitude/DC drift,
//   and deterministic ADC sample noise.
// -----------------------------------------------------------------------------
module tb_qpsk_rx_demod_random_external;

`ifdef QPSK_RX_RANDOM_DRIFT_NEG
`define QPSK_RX_RANDOM_DRIFT_ENABLED
`endif
`ifdef QPSK_RX_RANDOM_DRIFT
`define QPSK_RX_RANDOM_DRIFT_ENABLED
`endif

localparam integer ADC_DW = 10;
localparam integer PHASE_W = 24;
localparam integer SPS = 50;
localparam integer MAX_SYMBOLS = 4096;
localparam integer SYMBOL_MASK = MAX_SYMBOLS - 1;
localparam integer CAL_SYMS = 32;
localparam integer SEARCH_WIN = 6;
localparam integer LOCK_SETTLE_SYMS = 64;
`ifdef QPSK_RX_RANDOM_DRIFT_ENABLED
localparam integer TARGET_LOCKED_SYMS = 3200;
localparam integer MIN_NCO_CORR = 4500;
`else
localparam integer TARGET_LOCKED_SYMS = 360;
localparam integer MIN_NCO_CORR = 96;
`endif
localparam [PHASE_W-1:0] RX_PHASE_INC = 24'h11EB85;

localparam real FS_HZ = 100000000.0;
localparam real CARRIER_HZ = 7000000.0;
`ifdef QPSK_RX_RANDOM_DRIFT_NEG
localparam real CARRIER_OFFSET_HZ = -15000.0;
localparam integer EXPECT_NCO_SIGN = -1;
`elsif QPSK_RX_RANDOM_DRIFT
localparam real CARRIER_OFFSET_HZ = 15000.0;
localparam integer EXPECT_NCO_SIGN = 1;
`elsif QPSK_RX_RANDOM_WIDE_NEG
localparam real CARRIER_OFFSET_HZ = -35000.0;
localparam integer EXPECT_NCO_SIGN = -1;
`elsif QPSK_RX_RANDOM_WIDE
localparam real CARRIER_OFFSET_HZ = 35000.0;
localparam integer EXPECT_NCO_SIGN = 1;
`elsif QPSK_RX_RANDOM_NEG
localparam real CARRIER_OFFSET_HZ = -15000.0;
localparam integer EXPECT_NCO_SIGN = -1;
`else
localparam real CARRIER_OFFSET_HZ = 15000.0;
localparam integer EXPECT_NCO_SIGN = 1;
`endif
localparam real TX_SYMBOL_RATE_HZ = 2006000.0;
localparam real PHASE_OFFSET_DEG = 77.0;
localparam real ADC_AMPLITUDE = 150.0;
localparam real ADC_AMPLITUDE_RIPPLE = 22.0;
localparam real ADC_DC_OFFSET = 11.0;
localparam real ADC_DC_RIPPLE = 16.0;
localparam integer ADC_NOISE_SPAN = 8;
localparam real SYMBOL_PHASE_OFFSET = 0.22;
localparam real PI = 3.14159265358979323846;
localparam real PHASE_STEP_RAD = 2.0 * PI * (CARRIER_HZ + CARRIER_OFFSET_HZ) / FS_HZ;
`ifdef QPSK_RX_RANDOM_DRIFT_NEG
localparam real CARRIER_OFFSET_FINAL_HZ = -35000.0;
localparam integer CARRIER_DRIFT_START_SAMPLE = 500000;
localparam integer CARRIER_DRIFT_SAMPLES = 80000;
`elsif QPSK_RX_RANDOM_DRIFT
localparam real CARRIER_OFFSET_FINAL_HZ = 35000.0;
localparam integer CARRIER_DRIFT_START_SAMPLE = 500000;
localparam integer CARRIER_DRIFT_SAMPLES = 80000;
`endif
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

reg [1:0] tx_sym_mem [0:MAX_SYMBOLS-1];
reg [1:0] calib_rx [0:CAL_SYMS-1];
integer calib_ref [0:CAL_SYMS-1];

integer k;
integer j;
integer rot;
integer off;
integer sample_count;
integer rx_valid_cnt;
integer locked_cnt;
integer quantized;
integer noise_sample;
integer tx_sym_idx;
integer tx_ref_idx;
integer calib_count;
integer candidate_matches;
integer best_matches;
integer locked_offset;
integer locked_rot;
integer mismatch_cnt;
integer lock_settle_cnt;
reg [15:0] lfsr;
reg [15:0] noise_lfsr;
reg locked_seen;
reg calibrated;
reg drift_started_seen;
reg drift_done_seen;
reg [1:0] tx_sym;
reg [1:0] expected_sym;
real tx_phase;
real tx_symbol_phase;
real tx_phase_step;
real carrier_offset_now;
real drift_frac;
real sym_i;
real sym_q;
real rf_sample;
real amp_phase;
real dc_phase;
real amp_now;
real dc_now;

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
        $display("[TB_QPSK_RX_RANDOM][FAIL] %0t ns: %0s", $time, msg);
        $display("[TB_QPSK_RX_RANDOM][DBG] valid=%0d locked=%0d sym=%b exp=%b I=%0d Q=%0d phase=%0d rot=%0d gray_score=%0d blind_score=%0d blind_lock=%0b nco_corr=%0d offset=%0d map_rot=%0d mismatches=%0d tx_ref=%0d",
                 rx_valid_cnt, locked_cnt, rx_sym, expected_sym, dbg_i, dbg_q,
                 dbg_best_phase, dbg_phase_bin, dbg_lock_score,
                 u_rx.blind_lock_score, u_rx.blind_locked, u_rx.nco_freq_corr,
                 locked_offset, locked_rot, mismatch_cnt, tx_ref_idx);
        $finish;
    end
endtask

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

function integer abs_integer;
    input integer x;
    begin
        if (x < 0) begin
            abs_integer = -x;
        end else begin
            abs_integer = x;
        end
    end
endfunction

function [1:0] tx_sym_at;
    input integer idx;
    begin
        tx_sym_at = tx_sym_mem[idx & SYMBOL_MASK];
    end
endfunction

function [1:0] rotate_sym;
    input [1:0] sym;
    input integer rot_sel;
    begin
        case (rot_sel[1:0])
            2'd0: rotate_sym = sym;
            2'd1: rotate_sym = {sym[0], ~sym[1]};
            2'd2: rotate_sym = {~sym[1], ~sym[0]};
            default: rotate_sym = {~sym[0], sym[1]};
        endcase
    end
endfunction

task calibrate_reference;
    begin
        best_matches = -1;
        locked_offset = 0;
        locked_rot = 0;
        for (off = -SEARCH_WIN; off <= SEARCH_WIN; off = off + 1) begin
            for (rot = 0; rot < 4; rot = rot + 1) begin
                candidate_matches = 0;
                for (j = 0; j < CAL_SYMS; j = j + 1) begin
                    if (calib_rx[j] === rotate_sym(tx_sym_at(calib_ref[j] - off), rot)) begin
                        candidate_matches = candidate_matches + 1;
                    end
                end
                if (candidate_matches > best_matches) begin
                    best_matches = candidate_matches;
                    locked_offset = off;
                    locked_rot = rot;
                end
            end
        end

        if (best_matches < (CAL_SYMS - 1)) begin
            tb_fail("ERR_CALIBRATION_MATCH");
        end
        calibrated <= 1'b1;
        $display("[TB_QPSK_RX_RANDOM][INFO] %0t ns: calibrated, matches=%0d/%0d offset=%0d rot=%0d",
                 $time, best_matches, CAL_SYMS, locked_offset, locked_rot);
    end
endtask

initial begin
    lfsr = 16'hACE1;
    for (k = 0; k < MAX_SYMBOLS; k = k + 1) begin
        lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        tx_sym_mem[k] = lfsr[1:0] ^ {lfsr[5], lfsr[9]};
    end
end

initial clk = 1'b0;
always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        adc_data <= (1 << (ADC_DW-1));
        sample_count <= 0;
        tx_sym_idx <= 0;
        tx_phase = PHASE_OFFSET_RAD;
        tx_symbol_phase = SYMBOL_PHASE_OFFSET;
        tx_phase_step = PHASE_STEP_RAD;
        carrier_offset_now = CARRIER_OFFSET_HZ;
        drift_frac = 0.0;
        noise_lfsr <= 16'h1D0F;
        drift_started_seen <= 1'b0;
        drift_done_seen <= 1'b0;
        amp_phase = 0.0;
        dc_phase = 0.0;
    end else begin
        tx_sym_idx = $rtoi(tx_symbol_phase);
        tx_sym = tx_sym_at(tx_sym_idx);
        sym_i = tx_sym[0] ? -1.0 : 1.0;
        sym_q = tx_sym[1] ? -1.0 : 1.0;
        rf_sample = (sym_i * $cos(tx_phase)) - (sym_q * $sin(tx_phase));
        amp_now = ADC_AMPLITUDE + (ADC_AMPLITUDE_RIPPLE * $sin(amp_phase));
        dc_now = ADC_DC_OFFSET + (ADC_DC_RIPPLE * $sin(dc_phase));
        noise_sample = noise_lfsr[3:0];
        if (noise_sample >= ADC_NOISE_SPAN) begin
            noise_sample = noise_sample - (2 * ADC_NOISE_SPAN);
        end
        quantized = (1 << (ADC_DW-1)) + round_real(dc_now +
                    (amp_now * rf_sample)) + noise_sample;
        adc_data <= clip_adc(quantized);

`ifdef QPSK_RX_RANDOM_DRIFT_ENABLED
        if (sample_count < CARRIER_DRIFT_START_SAMPLE) begin
            carrier_offset_now = CARRIER_OFFSET_HZ;
        end else if (sample_count < (CARRIER_DRIFT_START_SAMPLE + CARRIER_DRIFT_SAMPLES)) begin
            if (!drift_started_seen) begin
                drift_started_seen <= 1'b1;
                $display("[TB_QPSK_RX_RANDOM][INFO] %0t ns: carrier drift start, offset_hz=%0f",
                         $time, CARRIER_OFFSET_HZ);
            end
            drift_frac = 1.0 * (sample_count - CARRIER_DRIFT_START_SAMPLE) /
                         CARRIER_DRIFT_SAMPLES;
            carrier_offset_now = CARRIER_OFFSET_HZ +
                                 ((CARRIER_OFFSET_FINAL_HZ - CARRIER_OFFSET_HZ) *
                                  drift_frac);
        end else begin
            if (!drift_done_seen) begin
                drift_done_seen <= 1'b1;
                $display("[TB_QPSK_RX_RANDOM][INFO] %0t ns: carrier drift done, offset_hz=%0f",
                         $time, CARRIER_OFFSET_FINAL_HZ);
            end
            carrier_offset_now = CARRIER_OFFSET_FINAL_HZ;
        end
        tx_phase_step = 2.0 * PI * (CARRIER_HZ + carrier_offset_now) / FS_HZ;
        tx_phase = tx_phase + tx_phase_step;
`else
        tx_phase = tx_phase + PHASE_STEP_RAD;
`endif
        if (tx_phase > (2.0 * PI)) begin
            tx_phase = tx_phase - (2.0 * PI);
        end

        tx_symbol_phase = tx_symbol_phase + SYMBOL_STEP;
        noise_lfsr <= {noise_lfsr[14:0], noise_lfsr[15] ^ noise_lfsr[13] ^
                       noise_lfsr[12] ^ noise_lfsr[10]};
        amp_phase = amp_phase + 0.00037;
        if (amp_phase > (2.0 * PI)) begin
            amp_phase = amp_phase - (2.0 * PI);
        end
        dc_phase = dc_phase + 0.00019;
        if (dc_phase > (2.0 * PI)) begin
            dc_phase = dc_phase - (2.0 * PI);
        end
        sample_count <= sample_count + 1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_valid_cnt <= 0;
        locked_cnt <= 0;
        calib_count <= 0;
        lock_settle_cnt <= 0;
        locked_offset <= 0;
        locked_rot <= 0;
        mismatch_cnt <= 0;
        locked_seen <= 1'b0;
        calibrated <= 1'b0;
        expected_sym <= 2'b00;
        tx_ref_idx <= 0;
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
                    lock_settle_cnt <= 0;
                    $display("[TB_QPSK_RX_RANDOM][INFO] %0t ns: blind lock acquired, sym=%b I=%0d Q=%0d phase=%0d rot=%0d gray_score=%0d blind_score=%0d nco_corr=%0d tx_ref=%0d",
                             $time, rx_sym, dbg_i, dbg_q, dbg_best_phase,
                             dbg_phase_bin, dbg_lock_score,
                             u_rx.blind_lock_score, u_rx.nco_freq_corr, tx_ref_idx);
                end

                if (!calibrated) begin
                    if (lock_settle_cnt < LOCK_SETTLE_SYMS) begin
                        lock_settle_cnt <= lock_settle_cnt + 1;
                    end else begin
                        calib_rx[calib_count] = rx_sym;
                        calib_ref[calib_count] = tx_ref_idx;
                        if (calib_count == (CAL_SYMS - 1)) begin
                            calibrate_reference;
                        end else begin
                            calib_count <= calib_count + 1;
                        end
                    end
                end else begin
                    expected_sym = rotate_sym(tx_sym_at(tx_ref_idx - locked_offset), locked_rot);
                    if (rx_sym !== expected_sym) begin
                        mismatch_cnt <= mismatch_cnt + 1;
                        tb_fail("ERR_TX_REFERENCE_MISMATCH");
                    end
                    locked_cnt <= locked_cnt + 1;

                    if (locked_cnt >= TARGET_LOCKED_SYMS) begin
`ifdef QPSK_RX_RANDOM_DRIFT_ENABLED
                        if (!drift_done_seen) begin
                            tb_fail("ERR_CARRIER_DRIFT_NOT_COMPLETED");
                        end
`endif
                        if (abs_integer(u_rx.nco_freq_corr) < MIN_NCO_CORR) begin
                            tb_fail("ERR_NCO_FREQ_TRACK_NOT_ACTIVE");
                        end
                        if (((EXPECT_NCO_SIGN > 0) && (u_rx.nco_freq_corr < MIN_NCO_CORR)) ||
                            ((EXPECT_NCO_SIGN < 0) && (u_rx.nco_freq_corr > -MIN_NCO_CORR))) begin
                            tb_fail("ERR_NCO_FREQ_TRACK_SIGN");
                        end
                        $display("[TB_QPSK_RX_RANDOM][PASS] %0t ns: random external RX symbols recovered, locked_symbols=%0d valid_symbols=%0d phase=%0d rot=%0d blind_score=%0d nco_corr=%0d offset=%0d map_rot=%0d",
                                 $time, locked_cnt, rx_valid_cnt, dbg_best_phase,
                                  dbg_phase_bin, u_rx.blind_lock_score,
                                  u_rx.nco_freq_corr, locked_offset, locked_rot);
                        $finish;
                    end
                end
            end else if (locked_seen) begin
                tb_fail("ERR_LOCK_DROPPED");
            end
        end
    end
end

`ifdef QPSK_RX_RANDOM_ACQ_TRACE
always @(posedge clk) begin
    if (rst_n && rx_valid &&
        u_rx.blind_train_active && !u_rx.track_locked &&
        !u_rx.blind_locked && !u_rx.acq_freq_wrapped &&
        (u_rx.acq_freq_dwell == 9'd255)) begin
        $display("[TB_QPSK_RX_RANDOM][ACQ] %0t ns: idx=%0d nco_corr=%0d score=%0d phase=%0d guard=%0d dd_acc=%0d dd_err=%0d I=%0d Q=%0d",
                 $time, u_rx.acq_freq_idx, u_rx.nco_freq_corr,
                 u_rx.acq_candidate_score, u_rx.phase_bin,
                 u_rx.blind_phase_guard, u_rx.dd_phase_acc,
                 u_rx.dd_phase_err, dbg_i, dbg_q);
    end
end
`endif

initial begin
    rst_n = 1'b0;
    adc_data = (1 << (ADC_DW-1));
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
end

initial begin
`ifdef QPSK_RX_RANDOM_WIDE
    #12000000;
`elsif QPSK_RX_RANDOM_WIDE_NEG
    #12000000;
`elsif QPSK_RX_RANDOM_DRIFT_NEG
    #9000000;
`elsif QPSK_RX_RANDOM_DRIFT
    #9000000;
`else
    #6000000;
`endif
    tb_fail("ERR_TIMEOUT");
end

endmodule

`ifdef QPSK_RX_RANDOM_DRIFT_ENABLED
`undef QPSK_RX_RANDOM_DRIFT_ENABLED
`endif
