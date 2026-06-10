`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_pl_comm_top_external_rx
// Purpose:
//   Verify the board-facing fixed wrapper in external-RX mode:
//     external QPSK ADC samples -> ad9215_capture -> qpsk_rx_fixed_demod
//   with local TX disabled. This covers the same top-level debug pins intended
//   for J11 bring-up: rx_demod_bit and rx_demod_lock.
// -----------------------------------------------------------------------------
module tb_pl_comm_top_external_rx;

localparam integer ADC_DW = 10;
localparam integer DAC_DW = 12;
localparam integer RX_DW = 16;
localparam integer FIFO_DEPTH = 512;
localparam integer PKT_LEN = 128;
localparam integer PHASE_W = 24;
localparam integer MAX_SYMBOLS = 4096;
localparam integer SYMBOL_MASK = MAX_SYMBOLS - 1;
localparam integer CAL_SYMS = 12;
localparam integer SEARCH_WIN = 6;
localparam integer TARGET_LOCKED_SYMS = 260;
localparam integer MIN_NCO_CORR = 96;

localparam real FS_HZ = 100000000.0;
localparam real CARRIER_HZ = 7000000.0;
`ifdef QPSK_TOP_EXT_RX_NEG
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
localparam real PHASE_OFFSET_RAD = PI * PHASE_OFFSET_DEG / 180.0;
localparam real SYMBOL_STEP = TX_SYMBOL_RATE_HZ / FS_HZ;

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
wire                      rx_demod_bit_pin;
wire                      rx_demod_lock_pin;

wire [1:0]                rx_sym_dbg;
wire                      rx_valid_dbg;
wire                      rx_lock_dbg;
wire signed [15:0]        rx_i_dbg;
wire signed [15:0]        rx_q_dbg;
wire [5:0]                rx_best_phase_dbg;
wire [3:0]                rx_phase_bin_dbg;
wire [7:0]                rx_lock_score_dbg;

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
integer dac_nonzero_cnt;
reg [15:0] lfsr;
reg [15:0] noise_lfsr;
reg locked_seen;
reg calibrated;
reg [1:0] tx_sym;
reg [1:0] expected_sym;
real tx_phase;
real tx_symbol_phase;
real sym_i;
real sym_q;
real rf_sample;
real amp_phase;
real dc_phase;
real amp_now;
real dc_now;

assign rx_sym_dbg = u_dut.rx_demod_sym_dbg;
assign rx_valid_dbg = u_dut.rx_demod_valid_dbg;
assign rx_lock_dbg = u_dut.rx_demod_lock_dbg;
assign rx_i_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_i;
assign rx_q_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_q;
assign rx_best_phase_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_best_phase;
assign rx_phase_bin_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_phase_bin;
assign rx_lock_score_dbg = u_dut.u_pl_comm_top.rx_demod_dbg_lock_score;

pl_comm_top_fixed_cfg #(
    .ADC_DW(ADC_DW),
    .DAC_DW(DAC_DW),
    .RX_DW(RX_DW),
    .FIFO_DEPTH(FIFO_DEPTH),
    .PKT_LEN(PKT_LEN),
    .FIXED_TX_EN(0),
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
    .m_axis_rx_tlast(m_axis_rx_tlast),
    .rx_demod_bit(rx_demod_bit_pin),
    .rx_demod_lock(rx_demod_lock_pin)
);

task tb_fail;
    input [8*96-1:0] msg;
    begin
        $display("[TB_TOP_EXT_RX][FAIL] %0t ns: %0s", $time, msg);
        $display("[TB_TOP_EXT_RX][DBG] valid=%0d locked=%0d sym=%b exp=%b I=%0d Q=%0d phase=%0d rot=%0d score=%0d blind_score=%0d blind_lock=%0b nco_corr=%0d offset=%0d map_rot=%0d mismatches=%0d tx_ref=%0d dac_nonzero=%0d",
                 rx_valid_cnt, locked_cnt, rx_sym_dbg, expected_sym,
                 rx_i_dbg, rx_q_dbg, rx_best_phase_dbg, rx_phase_bin_dbg,
                 rx_lock_score_dbg,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_lock_score,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_locked,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr,
                 locked_offset, locked_rot, mismatch_cnt, tx_ref_idx,
                 dac_nonzero_cnt);
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
            for (j = 0; j < CAL_SYMS; j = j + 1) begin
                $display("[TB_TOP_EXT_RX][CAL] j=%0d rx=%b ref_idx=%0d ref_sym=%b",
                         j, calib_rx[j], calib_ref[j], tx_sym_at(calib_ref[j]));
            end
            tb_fail("ERR_CALIBRATION_MATCH");
        end
        calibrated <= 1'b1;
        $display("[TB_TOP_EXT_RX][INFO] %0t ns: calibrated, matches=%0d/%0d offset=%0d rot=%0d",
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

// Drive external ADC data on the opposite edge from ad9215_capture sampling.
always @(posedge clk_adc or negedge rst_n) begin
    if (!rst_n) begin
        adc_data <= (1 << (ADC_DW-1));
        sample_count <= 0;
        tx_sym_idx <= 0;
        tx_phase = PHASE_OFFSET_RAD;
        tx_symbol_phase = SYMBOL_PHASE_OFFSET;
        noise_lfsr <= 16'h1D0F;
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

        tx_phase = tx_phase + PHASE_STEP_RAD;
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
        m_axis_rx_tready <= 1'b0;
    end else begin
        m_axis_rx_tready <= 1'b1;
    end
end

always @(negedge clk_dac or negedge rst_n) begin
    if (!rst_n) begin
        dac_nonzero_cnt <= 0;
    end else if (dac_data != {DAC_DW{1'b0}}) begin
        dac_nonzero_cnt <= dac_nonzero_cnt + 1;
        tb_fail("ERR_TX_DISABLED_DAC_NONZERO");
    end
end

always @(posedge clk_adc or negedge rst_n) begin
    if (!rst_n) begin
        rx_valid_cnt <= 0;
        locked_cnt <= 0;
        calib_count <= 0;
        locked_offset <= 0;
        locked_rot <= 0;
        mismatch_cnt <= 0;
        locked_seen <= 1'b0;
        calibrated <= 1'b0;
        expected_sym <= 2'b00;
        tx_ref_idx <= 0;
    end else begin
        if (rx_demod_lock_pin !== rx_lock_dbg) begin
            tb_fail("ERR_LOCK_PIN_MISMATCH");
        end

        if (rx_valid_dbg) begin
            rx_valid_cnt <= rx_valid_cnt + 1;
            tx_ref_idx = $rtoi(SYMBOL_PHASE_OFFSET + (sample_count * SYMBOL_STEP));

            if ((^rx_sym_dbg) === 1'bx) begin
                tb_fail("ERR_RX_SYMBOL_XZ");
            end
            if (rx_demod_bit_pin !== rx_sym_dbg[0]) begin
                tb_fail("ERR_BIT_PIN_MISMATCH");
            end

            if (rx_lock_dbg) begin
                if (!locked_seen) begin
                    locked_seen <= 1'b1;
                    $display("[TB_TOP_EXT_RX][INFO] %0t ns: blind lock acquired, sym=%b I=%0d Q=%0d phase=%0d rot=%0d gray_score=%0d blind_score=%0d nco_corr=%0d tx_ref=%0d",
                             $time, rx_sym_dbg, rx_i_dbg, rx_q_dbg,
                             rx_best_phase_dbg, rx_phase_bin_dbg,
                             rx_lock_score_dbg,
                             u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_lock_score,
                             u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr,
                             tx_ref_idx);
                end

                if (!calibrated) begin
                    calib_rx[calib_count] = rx_sym_dbg;
                    calib_ref[calib_count] = tx_ref_idx;
                    if (calib_count == (CAL_SYMS - 1)) begin
                        calibrate_reference;
                    end else begin
                        calib_count <= calib_count + 1;
                    end
                end else begin
                    expected_sym = rotate_sym(tx_sym_at(tx_ref_idx - locked_offset), locked_rot);
                    if (rx_sym_dbg !== expected_sym) begin
                        mismatch_cnt <= mismatch_cnt + 1;
                        tb_fail("ERR_TX_REFERENCE_MISMATCH");
                    end
                    locked_cnt <= locked_cnt + 1;

                    if (locked_cnt >= TARGET_LOCKED_SYMS) begin
                        if (abs_integer(u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr) < MIN_NCO_CORR) begin
                            tb_fail("ERR_NCO_FREQ_TRACK_NOT_ACTIVE");
                        end
                        if (((EXPECT_NCO_SIGN > 0) &&
                             (u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr < MIN_NCO_CORR)) ||
                            ((EXPECT_NCO_SIGN < 0) &&
                             (u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr > -MIN_NCO_CORR))) begin
                            tb_fail("ERR_NCO_FREQ_TRACK_SIGN");
                        end
                        $display("[TB_TOP_EXT_RX][PASS] %0t ns: top external RX recovered symbols, locked_symbols=%0d valid_symbols=%0d phase=%0d rot=%0d blind_score=%0d nco_corr=%0d offset=%0d map_rot=%0d",
                                 $time, locked_cnt, rx_valid_cnt,
                                 rx_best_phase_dbg, rx_phase_bin_dbg,
                                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_lock_score,
                                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr,
                                 locked_offset, locked_rot);
                        $finish;
                    end
                end
            end else if (locked_seen) begin
                tb_fail("ERR_LOCK_DROPPED");
            end
        end
    end
end

`ifdef QPSK_TOP_EXT_RX_TRACE
always @(posedge clk_adc) begin
    if (rst_n &&
        u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.rot_dec_valid &&
        u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_train_active &&
        !u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.track_locked &&
        !u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_locked &&
        !u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.acq_freq_wrapped &&
        (u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.acq_freq_dwell == 9'd383)) begin
        $display("[TB_TOP_EXT_RX][ACQ] t=%0t idx=%0d freq=%0d cand=%0d best=%0d best_freq=%0d phase=%0d stable=%0b fine=%0b dd_err=%0d",
                 $time,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.acq_freq_idx,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.nco_freq_corr,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.acq_candidate_score,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.acq_best_score,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.acq_best_freq,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.phase_bin,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_symbol_stable,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.blind_symbol_fine,
                 u_dut.u_pl_comm_top.u_qpsk_rx_fixed_demod.dd_phase_err);
    end
end
`endif

initial begin
    rst_n = 1'b0;
    adc_data = (1 << (ADC_DW-1));
    m_axis_rx_tready = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
end

initial begin
    #5000000;
    tb_fail("ERR_TIMEOUT");
end

endmodule
