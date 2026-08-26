// -----------------------------------------------------------------------------
// Module: qpsk_rx_fixed_demod
// Function: Fixed-carrier QPSK receive demodulator for stage-2 PL loopback.
// Chain:
//   unsigned ADC -> centered/DC-removed -> NCO DDC -> moving-average LPF
//   -> coarse SPS timing phase select -> Gray-cycle phase/quality tracking
//   -> hard QPSK decisions
// Notes:
//   - The first local-test mode assumes the known Gray cycle 00->01->11->10
//     for lock/phase quality. The DDC/timing blocks are kept separate so the
//     phase tracker can later be replaced by a Costas or decision-directed loop.
//   - A delayed blind quality path is also present for external sources that do
//     not send the local Gray test cycle; it locks on constellation confidence
//     and decision-directed phase error after pattern acquisition has timed out.
//   - A bounded decision-directed Costas-like PI path nudges the DDC NCO while
//     the coarse blind search checks candidate frequency regions.
//   - Re-acquisition: after a full coarse sweep applies its best candidate, an
//     explicit watchdog counts unlocked symbols; if blind lock is not achieved
//     within REACQ_TIMEOUT_SYMS, the whole coarse sweep restarts. This covers
//     signals that appear late or disappear after lock, without relying on any
//     counter wrap-around side effects.
//   - m_valid only qualifies lock-approved output symbols. Internal acquisition
//     decisions still run before lock but are not exposed as reliable data.
// -----------------------------------------------------------------------------
module qpsk_rx_fixed_demod #(
    parameter integer ADC_DW = 10,
    parameter integer PHASE_W = 24,
    parameter integer NCO_W = 12,
    parameter integer MIX_W = 24,
    parameter integer SUM_W = 32,
    parameter integer CORR_W = 32,
    parameter integer SPS = 50,
    parameter integer DC_FRAC = 8,
    parameter integer DC_SHIFT = 10,
    parameter integer TIMING_W = 32,
    parameter integer TIMING_LEAK_SHIFT = 5,
    parameter integer TIMING_METRIC_SHIFT = 5,
    parameter integer TIMING_ACQ_SYMS = 16,
    parameter integer CORR_IN_SHIFT = 4,
    parameter integer CORR_LEAK_SHIFT = 5,
    parameter integer LOCK_THRESHOLD = 40
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,
    input  wire [ADC_DW-1:0]       s_adc,
    input  wire                    s_valid,
    output wire                    s_ready,
    input  wire [PHASE_W-1:0]      cfg_phase_inc,
    output reg  [1:0]              m_sym,
    output reg                     m_valid,
    output reg                     m_lock,
    output reg  signed [15:0]      dbg_i,
    output reg  signed [15:0]      dbg_q,
    output reg  [5:0]              dbg_best_phase,
    output reg  [3:0]              dbg_phase_bin,
    output reg  [7:0]              dbg_lock_score,
    output wire signed [15:0]      dbg_nco_freq_corr
);

localparam integer ADC_SIGNED_W = ADC_DW + 1;
localparam integer DC_W = ADC_SIGNED_W + DC_FRAC + 1;
localparam integer ROT_W = SUM_W + NCO_W + 1;
localparam integer PHASE_EST_W = 18;
localparam integer PHASE_EST_SHIFT = 6;
localparam integer PHASE_DOT_W = PHASE_EST_W + NCO_W + 1;
localparam signed [4:0] TIMING_TRACK_LIMIT = 5'sd1;
localparam integer TIMING_TRACK_DEADBAND = 8;
localparam signed [17:0] DD_ERR_DEADBAND = 18'sd12;
localparam signed [12:0] DD_ACC_LIMIT = 13'sd96;
localparam integer DD_ERR_SHIFT = 4;
localparam integer DD_FREQ_ERR_SHIFT = 5;
localparam signed [17:0] DD_FREQ_STEP_LIMIT = 18'sd48;
localparam integer FREQ_CORR_W = 16;
localparam signed [FREQ_CORR_W-1:0] FREQ_CORR_MAX = 16'sd8192;
localparam signed [FREQ_CORR_W-1:0] FREQ_CORR_MIN = -16'sd8192;
localparam signed [FREQ_CORR_W:0] FREQ_CORR_MAX_EXT =
    {FREQ_CORR_MAX[FREQ_CORR_W-1], FREQ_CORR_MAX};
localparam signed [FREQ_CORR_W:0] FREQ_CORR_MIN_EXT =
    {FREQ_CORR_MIN[FREQ_CORR_W-1], FREQ_CORR_MIN};
localparam signed [FREQ_CORR_W-1:0] ACQ_FREQ_STEP = 16'sd512;
localparam signed [FREQ_CORR_W-1:0] ACQ_FREQ_MAX = 16'sd8192;
localparam [5:0] ACQ_FREQ_LAST_IDX = 6'd32;
localparam [8:0] ACQ_FREQ_DWELL_SYMS = 9'd256;
localparam [15:0] BLIND_ACQ_DELAY_SYMS = 16'd256;
// Unlocked-wait limit after a completed coarse sweep before the sweep restarts.
// Must exceed the blind lock ramp (BLIND_LOCK_THRESHOLD symbols plus guard) by
// a comfortable margin so a correct candidate is never aborted early.
localparam [10:0] REACQ_TIMEOUT_SYMS = 11'd1024;
localparam [15:0] BLIND_MIN_ABS = 16'd24;
localparam [17:0] BLIND_ERR_LIMIT = 18'd256;
localparam [17:0] BLIND_FINE_ERR_LIMIT = 18'd128;
localparam [4:0] BLIND_PHASE_GUARD_SYMS = 5'd12;
localparam [7:0] BLIND_LOCK_THRESHOLD = 8'd224;
localparam [7:0] BLIND_RELEASE_LEVEL = 8'd112;
localparam [7:0] PATTERN_LOCK_THRESHOLD = (LOCK_THRESHOLD[7:0] > 8'd160) ?
                                          LOCK_THRESHOLD[7:0] : 8'd160;
localparam [7:0] LOCK_RELEASE_LEVEL = (PATTERN_LOCK_THRESHOLD > 16) ?
                                      (PATTERN_LOCK_THRESHOLD - 8'd8) :
                                      (PATTERN_LOCK_THRESHOLD >> 1);
localparam [ADC_SIGNED_W-1:0] ADC_MID = (1 << (ADC_DW-1));
localparam [1:0] TRACK_IDLE   = 2'd0;
localparam [1:0] TRACK_OFFSET = 2'd1;
localparam [1:0] TRACK_LOAD   = 2'd2;
localparam [1:0] TRACK_ANGLE  = 2'd3;

reg [PHASE_W-1:0] phase_acc;
reg [5:0] sample_phase;
(* keep = "true", mark_debug = "true" *) reg signed [FREQ_CORR_W-1:0] nco_freq_corr;
reg [5:0] acq_freq_idx;
reg [8:0] acq_freq_dwell;
reg acq_freq_wrapped;
reg [9:0] acq_candidate_score;
reg [9:0] acq_best_score;
reg signed [FREQ_CORR_W-1:0] acq_best_freq;
reg [3:0] acq_best_phase_bin;
reg acq_symbol_score_valid;
reg acq_symbol_score_fine;
reg acq_apply_best_pending;
reg blind_delay_done;
reg [10:0] reacq_timeout_cnt;
reg [7:0] timing_epoch_cnt;
reg timing_ready;
reg [5:0] best_phase;
reg [TIMING_W-1:0] epoch_best_metric;
reg [5:0] epoch_best_phase;
reg [TIMING_W-1:0] metric_d;
reg [5:0] phase_d;
reg metric_valid_d;
reg signed [SUM_W-1:0] metric_sum_i;
reg signed [SUM_W-1:0] metric_sum_q;
reg [5:0] metric_phase;
reg metric_src_valid;
reg signed [4:0] timing_track_acc;
reg [TIMING_W-1:0] timing_early_metric;
reg timing_early_valid;

reg signed [DC_W-1:0] dc_avg;
reg signed [MIX_W-1:0] hist_i [0:SPS-1];
reg signed [MIX_W-1:0] hist_q [0:SPS-1];
reg signed [SUM_W-1:0] sum_i;
reg signed [SUM_W-1:0] sum_q;
reg [ADC_DW-1:0] adc_sample;
reg sample_valid_q;
reg signed [MIX_W-1:0] mix_i_d;
reg signed [MIX_W-1:0] mix_q_d;
reg mix_valid;

reg [15:0] sym_count;
reg signed [CORR_W-1:0] corr_i [0:3];
reg signed [CORR_W-1:0] corr_q [0:3];
reg [1:0] best_offset;
reg [3:0] phase_bin;
reg [7:0] lock_score;
reg track_locked;
reg [7:0] blind_lock_score;
reg blind_locked;
reg [4:0] blind_phase_guard;
reg [1:0] tracker_state;
reg [4:0] tracker_idx;
reg [CORR_W-1:0] scan_best_mag;
reg [1:0] scan_best_offset;
reg signed [PHASE_EST_W-1:0] phase_scan_re;
reg signed [PHASE_EST_W-1:0] phase_scan_im;
reg signed [PHASE_DOT_W-1:0] phase_dot_d;
reg [3:0] phase_dot_bin_d;
reg phase_dot_valid;
reg signed [PHASE_DOT_W-1:0] phase_best_dot;
reg [3:0] phase_best_bin;
reg signed [SUM_W-1:0] sym_i_reg;
reg signed [SUM_W-1:0] sym_q_reg;
reg [1:0] rot_exp_sym_req;
reg [1:0] rot_exp_sym_d;
reg rot_req_valid;
reg signed [ROT_W-1:0] rot_i_reg;
reg signed [ROT_W-1:0] rot_q_reg;
reg rot_dec_valid;
reg signed [CORR_W-1:0] corr_i_in_q;
reg signed [CORR_W-1:0] corr_q_in_q;
reg [1:0] corr_sym_base_q;
reg corr_update_pending;
reg signed [12:0] dd_phase_acc;
reg dd_nco_step_pending;
reg signed [FREQ_CORR_W-1:0] dd_nco_step;
reg blind_phase_guard_set_pending;
reg [1:0] blind_prev_sym;
reg blind_prev_sym_valid;

integer n;

reg signed [CORR_W-1:0] corr_re_term;
reg signed [CORR_W-1:0] corr_im_term;
reg [5:0] epoch_winner_phase;
reg [5:0] timing_phase_delta;
reg signed [4:0] timing_acc_next;
reg [7:0] lock_score_next;
reg [7:0] blind_score_next;
reg pattern_lock_now;
reg [9:0] acq_candidate_score_next;
reg [9:0] acq_best_score_next;
reg signed [FREQ_CORR_W-1:0] acq_best_freq_next;
reg [3:0] acq_best_phase_bin_next;
reg [1:0] exp_sym_tmp;
reg [1:0] exp_lock_sym;
reg [CORR_W-1:0] corr_mag_tmp;

wire sample_accept;
wire sample_proc_accept;
wire signed [ADC_SIGNED_W-1:0] adc_centered;
wire signed [DC_W-1:0] adc_centered_q;
wire signed [DC_W-1:0] dc_err;
wire signed [DC_W-1:0] dc_term;
wire signed [DC_W-1:0] adc_hp;

wire [3:0] nco_idx;
wire signed [PHASE_W:0] phase_inc_base_ext;
wire signed [PHASE_W:0] phase_inc_corr_ext;
wire signed [PHASE_W:0] phase_inc_sum;
wire [PHASE_W-1:0] phase_inc_eff;
wire signed [NCO_W-1:0] cos_val;
wire signed [NCO_W-1:0] sin_val;
wire signed [DC_W+NCO_W-1:0] mul_i_wide;
wire signed [DC_W+NCO_W-1:0] mul_q_wide;
wire signed [MIX_W-1:0] mix_i;
wire signed [MIX_W-1:0] mix_q;

wire signed [SUM_W-1:0] mix_i_ext;
wire signed [SUM_W-1:0] mix_q_ext;
wire signed [SUM_W-1:0] hist_i_ext;
wire signed [SUM_W-1:0] hist_q_ext;
wire signed [SUM_W-1:0] sum_i_next;
wire signed [SUM_W-1:0] sum_q_next;
wire [SUM_W-1:0] abs_sum_i;
wire [SUM_W-1:0] abs_sum_q;
wire [TIMING_W-1:0] timing_metric;

wire signed [NCO_W-1:0] rot_cos;
wire signed [NCO_W-1:0] rot_sin;
wire signed [SUM_W+NCO_W-1:0] rot_i_mul_cos;
wire signed [SUM_W+NCO_W-1:0] rot_i_mul_sin;
wire signed [SUM_W+NCO_W-1:0] rot_q_mul_cos;
wire signed [SUM_W+NCO_W-1:0] rot_q_mul_sin;
wire signed [ROT_W-1:0] rot_i_now;
wire signed [ROT_W-1:0] rot_q_now;
wire [1:0] dec_sym_done;
wire sample_symbol;
wire signed [PHASE_EST_W+NCO_W-1:0] phase_dot_re_wide;
wire signed [PHASE_EST_W+NCO_W-1:0] phase_dot_im_wide;
wire signed [PHASE_DOT_W-1:0] phase_dot_now;
wire signed [15:0] dd_i_now;
wire signed [15:0] dd_q_now;
wire signed [16:0] dd_i_ext;
wire signed [16:0] dd_q_ext;
wire signed [16:0] dd_isign_q;
wire signed [16:0] dd_qsign_i;
wire signed [17:0] dd_phase_err;
wire signed [12:0] dd_phase_step;
wire [15:0] dd_abs_i;
wire [15:0] dd_abs_q;
wire [15:0] dd_min_abs;
wire [17:0] dd_abs_phase_err;
wire blind_train_active;
wire pattern_track_active;
wire decision_track_active;
wire blind_symbol_confident;
wire blind_symbol_stable;
wire blind_symbol_fine;
wire blind_symbol_transition;
wire blind_acq_candidate_ready;

reg signed [12:0] dd_acc_next;

assign s_ready = 1'b1;
assign dbg_nco_freq_corr = nco_freq_corr;
assign sample_accept = en && s_valid;
assign sample_proc_accept = en && sample_valid_q;

assign adc_centered = $signed({1'b0, adc_sample}) - $signed(ADC_MID);
assign adc_centered_q = {{(DC_W-ADC_SIGNED_W){adc_centered[ADC_SIGNED_W-1]}}, adc_centered} <<< DC_FRAC;
assign dc_err = adc_centered_q - dc_avg;
assign dc_term = dc_avg >>> DC_FRAC;
assign adc_hp = {{(DC_W-ADC_SIGNED_W){adc_centered[ADC_SIGNED_W-1]}}, adc_centered} - dc_term;

assign nco_idx = phase_acc[PHASE_W-1 -: 4];
assign phase_inc_base_ext = {1'b0, cfg_phase_inc};
assign phase_inc_corr_ext = {{(PHASE_W+1-FREQ_CORR_W){nco_freq_corr[FREQ_CORR_W-1]}}, nco_freq_corr};
assign phase_inc_sum = phase_inc_base_ext + phase_inc_corr_ext;
assign phase_inc_eff = phase_inc_sum[PHASE_W-1:0];
assign cos_val = cos_lut(nco_idx);
assign sin_val = sin_lut(nco_idx);

assign mul_i_wide = adc_hp * cos_val;
assign mul_q_wide = adc_hp * (-sin_val);
assign mix_i = mul_i_wide >>> (NCO_W-1);
assign mix_q = mul_q_wide >>> (NCO_W-1);

assign mix_i_ext = {{(SUM_W-MIX_W){mix_i_d[MIX_W-1]}}, mix_i_d};
assign mix_q_ext = {{(SUM_W-MIX_W){mix_q_d[MIX_W-1]}}, mix_q_d};
assign hist_i_ext = {{(SUM_W-MIX_W){hist_i[sample_phase][MIX_W-1]}}, hist_i[sample_phase]};
assign hist_q_ext = {{(SUM_W-MIX_W){hist_q[sample_phase][MIX_W-1]}}, hist_q[sample_phase]};
assign sum_i_next = sum_i + mix_i_ext - hist_i_ext;
assign sum_q_next = sum_q + mix_q_ext - hist_q_ext;
assign abs_sum_i = abs_sum(metric_sum_i);
assign abs_sum_q = abs_sum(metric_sum_q);
assign timing_metric = (abs_sum_i >> TIMING_METRIC_SHIFT) +
                       (abs_sum_q >> TIMING_METRIC_SHIFT);

assign sample_symbol = mix_valid && timing_ready && (sample_phase == best_phase);

assign rot_cos = cos_lut(phase_bin);
assign rot_sin = sin_lut(phase_bin);
assign rot_i_mul_cos = sym_i_reg * rot_cos;
assign rot_i_mul_sin = sym_i_reg * rot_sin;
assign rot_q_mul_cos = sym_q_reg * rot_cos;
assign rot_q_mul_sin = sym_q_reg * rot_sin;
assign rot_i_now = {{1{rot_i_mul_cos[SUM_W+NCO_W-1]}}, rot_i_mul_cos} +
                   {{1{rot_q_mul_sin[SUM_W+NCO_W-1]}}, rot_q_mul_sin};
assign rot_q_now = {{1{rot_q_mul_cos[SUM_W+NCO_W-1]}}, rot_q_mul_cos} -
                   {{1{rot_i_mul_sin[SUM_W+NCO_W-1]}}, rot_i_mul_sin};
assign dec_sym_done = {rot_q_reg[ROT_W-1], rot_i_reg[ROT_W-1]};

assign phase_dot_re_wide = phase_scan_re * cos_lut(tracker_idx[3:0]);
assign phase_dot_im_wide = phase_scan_im * sin_lut(tracker_idx[3:0]);
assign phase_dot_now = {{1{phase_dot_re_wide[PHASE_EST_W+NCO_W-1]}}, phase_dot_re_wide} +
                       {{1{phase_dot_im_wide[PHASE_EST_W+NCO_W-1]}}, phase_dot_im_wide};
assign dd_i_now = rot_i_reg >>> (NCO_W + 4);
assign dd_q_now = rot_q_reg >>> (NCO_W + 4);
assign dd_i_ext = {dd_i_now[15], dd_i_now};
assign dd_q_ext = {dd_q_now[15], dd_q_now};
assign dd_isign_q = dec_sym_done[0] ? -dd_q_ext : dd_q_ext;
assign dd_qsign_i = dec_sym_done[1] ? -dd_i_ext : dd_i_ext;
assign dd_phase_err = {dd_isign_q[16], dd_isign_q} -
                      {dd_qsign_i[16], dd_qsign_i};
assign dd_phase_step = dd_phase_err >>> DD_ERR_SHIFT;
assign dd_abs_i = abs16(dd_i_now);
assign dd_abs_q = abs16(dd_q_now);
assign dd_min_abs = (dd_abs_i < dd_abs_q) ? dd_abs_i : dd_abs_q;
assign dd_abs_phase_err = abs18(dd_phase_err);
assign blind_train_active = timing_ready && (!track_locked) &&
                            blind_delay_done;
assign pattern_track_active = !blind_train_active || track_locked;
assign decision_track_active = track_locked || blind_locked || blind_train_active;
assign blind_symbol_confident = (dd_min_abs >= BLIND_MIN_ABS) &&
                                (dd_abs_phase_err <= BLIND_ERR_LIMIT);
assign blind_symbol_stable = blind_symbol_confident &&
                             (blind_phase_guard == 5'd0);
assign blind_symbol_fine = blind_symbol_stable &&
                           (dd_abs_phase_err <= BLIND_FINE_ERR_LIMIT);
assign blind_symbol_transition = blind_prev_sym_valid &&
                                 (dec_sym_done != blind_prev_sym);
assign blind_acq_candidate_ready = blind_locked || acq_freq_wrapped;

generate
    if (SPS != 50) begin : g_sps_not_supported
        // synopsys translate_off
        initial begin
            $error("qpsk_rx_fixed_demod currently supports SPS=50 only, got SPS=%0d", SPS);
        end
        // synopsys translate_on
    end
    if (NCO_W != 12) begin : g_nco_w_not_supported
        // synopsys translate_off
        initial begin
            $error("qpsk_rx_fixed_demod currently supports NCO_W=12 only, got NCO_W=%0d", NCO_W);
        end
        // synopsys translate_on
    end
    // The fixed-point truncations in the decision/dd path (dd_i_now, dd_q_now,
    // dd_phase_step) are only proven overflow-safe for the validated 10-bit
    // ADC scale chain.
    if (ADC_DW != 10) begin : g_adc_dw_not_supported
        // synopsys translate_off
        initial begin
            $error("qpsk_rx_fixed_demod currently supports ADC_DW=10 only, got ADC_DW=%0d", ADC_DW);
        end
        // synopsys translate_on
    end
endgenerate

function signed [NCO_W-1:0] cos_lut;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  cos_lut = 12'sd2047;
            4'd1:  cos_lut = 12'sd1891;
            4'd2:  cos_lut = 12'sd1447;
            4'd3:  cos_lut = 12'sd783;
            4'd4:  cos_lut = 12'sd0;
            4'd5:  cos_lut = -12'sd783;
            4'd6:  cos_lut = -12'sd1447;
            4'd7:  cos_lut = -12'sd1891;
            4'd8:  cos_lut = -12'sd2047;
            4'd9:  cos_lut = -12'sd1891;
            4'd10: cos_lut = -12'sd1447;
            4'd11: cos_lut = -12'sd783;
            4'd12: cos_lut = 12'sd0;
            4'd13: cos_lut = 12'sd783;
            4'd14: cos_lut = 12'sd1447;
            default: cos_lut = 12'sd1891;
        endcase
    end
endfunction

function signed [NCO_W-1:0] sin_lut;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  sin_lut = 12'sd0;
            4'd1:  sin_lut = 12'sd783;
            4'd2:  sin_lut = 12'sd1447;
            4'd3:  sin_lut = 12'sd1891;
            4'd4:  sin_lut = 12'sd2047;
            4'd5:  sin_lut = 12'sd1891;
            4'd6:  sin_lut = 12'sd1447;
            4'd7:  sin_lut = 12'sd783;
            4'd8:  sin_lut = 12'sd0;
            4'd9:  sin_lut = -12'sd783;
            4'd10: sin_lut = -12'sd1447;
            4'd11: sin_lut = -12'sd1891;
            4'd12: sin_lut = -12'sd2047;
            4'd13: sin_lut = -12'sd1891;
            4'd14: sin_lut = -12'sd1447;
            default: sin_lut = -12'sd783;
        endcase
    end
endfunction

function [SUM_W-1:0] abs_sum;
    input signed [SUM_W-1:0] x;
    begin
        abs_sum = x[SUM_W-1] ? (~x + {{(SUM_W-1){1'b0}}, 1'b1}) : x;
    end
endfunction

function [CORR_W-1:0] abs_corr;
    input signed [CORR_W-1:0] x;
    begin
        abs_corr = x[CORR_W-1] ? (~x + {{(CORR_W-1){1'b0}}, 1'b1}) : x;
    end
endfunction

function [15:0] abs16;
    input signed [15:0] x;
    begin
        abs16 = x[15] ? (~x + 16'd1) : x;
    end
endfunction

function [17:0] abs18;
    input signed [17:0] x;
    begin
        abs18 = x[17] ? (~x + 18'd1) : x;
    end
endfunction

function signed [FREQ_CORR_W-1:0] limit_costas_freq_step;
    input signed [17:0] err;
    reg signed [17:0] shifted;
    begin
        shifted = err >>> DD_FREQ_ERR_SHIFT;
        if ((err > DD_ERR_DEADBAND) && (shifted == 18'sd0)) begin
            shifted = 18'sd1;
        end

        if (shifted > DD_FREQ_STEP_LIMIT) begin
            limit_costas_freq_step = DD_FREQ_STEP_LIMIT[FREQ_CORR_W-1:0];
        end else if (shifted < -DD_FREQ_STEP_LIMIT) begin
            shifted = -DD_FREQ_STEP_LIMIT;
            limit_costas_freq_step = shifted[FREQ_CORR_W-1:0];
        end else begin
            limit_costas_freq_step = shifted[FREQ_CORR_W-1:0];
        end
    end
endfunction

function signed [FREQ_CORR_W-1:0] sat_freq_corr_add;
    input signed [FREQ_CORR_W-1:0] value;
    input signed [FREQ_CORR_W-1:0] step;
    reg signed [FREQ_CORR_W:0] sum_ext;
    begin
        sum_ext = {value[FREQ_CORR_W-1], value} +
                  {step[FREQ_CORR_W-1], step};
        if (sum_ext > FREQ_CORR_MAX_EXT) begin
            sat_freq_corr_add = FREQ_CORR_MAX;
        end else if (sum_ext < FREQ_CORR_MIN_EXT) begin
            sat_freq_corr_add = FREQ_CORR_MIN;
        end else begin
            sat_freq_corr_add = sum_ext[FREQ_CORR_W-1:0];
        end
    end
endfunction

function [1:0] gray_seq4;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: gray_seq4 = 2'b00;
            2'd1: gray_seq4 = 2'b01;
            2'd2: gray_seq4 = 2'b11;
            2'd3: gray_seq4 = 2'b10;
            default: gray_seq4 = 2'b00;
        endcase
    end
endfunction

function [5:0] phase_next;
    input [5:0] phase;
    begin
        if (phase == (SPS - 1)) begin
            phase_next = 6'd0;
        end else begin
            phase_next = phase + 6'd1;
        end
    end
endfunction

function [5:0] phase_prev;
    input [5:0] phase;
    begin
        if (phase == 6'd0) begin
            phase_prev = SPS - 1;
        end else begin
            phase_prev = phase - 6'd1;
        end
    end
endfunction

function [5:0] phase_forward_delta;
    input [5:0] from_phase;
    input [5:0] to_phase;
    begin
        if (to_phase >= from_phase) begin
            phase_forward_delta = to_phase - from_phase;
        end else begin
            phase_forward_delta = to_phase + SPS - from_phase;
        end
    end
endfunction

function signed [FREQ_CORR_W-1:0] acq_freq_value;
    input [5:0] idx;
    reg [5:0] mag_idx;
    reg signed [FREQ_CORR_W-1:0] mag;
    begin
        if (idx == 6'd0) begin
            acq_freq_value = {FREQ_CORR_W{1'b0}};
        end else begin
            mag_idx = (idx + 6'd1) >> 1;
            mag = $signed({1'b0, mag_idx}) * ACQ_FREQ_STEP;
            if (mag > ACQ_FREQ_MAX) begin
                mag = ACQ_FREQ_MAX;
            end
            if (idx[0]) begin
                acq_freq_value = mag;
            end else begin
                acq_freq_value = -mag;
            end
        end
    end
endfunction

function signed [PHASE_EST_W-1:0] corr_to_phase_est;
    input signed [CORR_W-1:0] x;
    reg signed [CORR_W-1:0] shifted;
    begin
        shifted = x >>> PHASE_EST_SHIFT;
        if (!shifted[CORR_W-1] && (|shifted[CORR_W-2:PHASE_EST_W-1])) begin
            corr_to_phase_est = {1'b0, {(PHASE_EST_W-1){1'b1}}};
        end else if (shifted[CORR_W-1] && (~&shifted[CORR_W-2:PHASE_EST_W-1])) begin
            corr_to_phase_est = {1'b1, {(PHASE_EST_W-1){1'b0}}};
        end else begin
            corr_to_phase_est = shifted[PHASE_EST_W-1:0];
        end
    end
endfunction

always @(posedge clk) begin
    if (!rst_n || !en) begin
        phase_acc        <= {PHASE_W{1'b0}};
        sample_phase     <= 6'd0;
        nco_freq_corr    <= {FREQ_CORR_W{1'b0}};
        acq_freq_idx     <= 6'd0;
        acq_freq_dwell   <= 9'd0;
        acq_freq_wrapped <= 1'b0;
        acq_candidate_score <= 10'd0;
        acq_best_score   <= 10'd0;
        acq_best_freq    <= {FREQ_CORR_W{1'b0}};
        acq_best_phase_bin <= 4'd0;
        acq_symbol_score_valid <= 1'b0;
        acq_symbol_score_fine <= 1'b0;
        acq_apply_best_pending <= 1'b0;
        blind_delay_done <= 1'b0;
        reacq_timeout_cnt <= 11'd0;
        timing_epoch_cnt <= 8'd0;
        timing_ready     <= 1'b0;
        best_phase       <= 6'd0;
        epoch_best_metric <= {TIMING_W{1'b0}};
        epoch_best_phase  <= 6'd0;
        metric_d         <= {TIMING_W{1'b0}};
        phase_d          <= 6'd0;
        metric_valid_d   <= 1'b0;
        metric_sum_i     <= {SUM_W{1'b0}};
        metric_sum_q     <= {SUM_W{1'b0}};
        metric_phase     <= 6'd0;
        metric_src_valid <= 1'b0;
        timing_track_acc <= 5'sd0;
        timing_early_metric <= {TIMING_W{1'b0}};
        timing_early_valid <= 1'b0;
        dc_avg           <= {DC_W{1'b0}};
        sum_i            <= {SUM_W{1'b0}};
        sum_q            <= {SUM_W{1'b0}};
        adc_sample       <= {ADC_DW{1'b0}};
        sample_valid_q   <= 1'b0;
        mix_i_d          <= {MIX_W{1'b0}};
        mix_q_d          <= {MIX_W{1'b0}};
        mix_valid        <= 1'b0;
        sym_count        <= 16'd0;
        best_offset      <= 2'd0;
        phase_bin        <= 4'd0;
        lock_score       <= 8'd0;
        track_locked     <= 1'b0;
        blind_lock_score <= 8'd0;
        blind_locked     <= 1'b0;
        blind_phase_guard <= 5'd0;
        tracker_state    <= TRACK_IDLE;
        tracker_idx      <= 5'd0;
        scan_best_mag    <= {CORR_W{1'b0}};
        scan_best_offset <= 2'd0;
        phase_scan_re    <= {PHASE_EST_W{1'b0}};
        phase_scan_im    <= {PHASE_EST_W{1'b0}};
        phase_dot_d      <= {PHASE_DOT_W{1'b0}};
        phase_dot_bin_d  <= 4'd0;
        phase_dot_valid  <= 1'b0;
        phase_best_dot   <= {1'b1, {(PHASE_DOT_W-1){1'b0}}};
        phase_best_bin   <= 4'd0;
        sym_i_reg        <= {SUM_W{1'b0}};
        sym_q_reg        <= {SUM_W{1'b0}};
        rot_exp_sym_req  <= 2'b00;
        rot_exp_sym_d    <= 2'b00;
        rot_req_valid    <= 1'b0;
        rot_i_reg        <= {ROT_W{1'b0}};
        rot_q_reg        <= {ROT_W{1'b0}};
        rot_dec_valid    <= 1'b0;
        corr_i_in_q      <= {CORR_W{1'b0}};
        corr_q_in_q      <= {CORR_W{1'b0}};
        corr_sym_base_q  <= 2'b00;
        corr_update_pending <= 1'b0;
        dd_phase_acc     <= 13'sd0;
        dd_nco_step_pending <= 1'b0;
        dd_nco_step      <= {FREQ_CORR_W{1'b0}};
        blind_phase_guard_set_pending <= 1'b0;
        blind_prev_sym    <= 2'b00;
        blind_prev_sym_valid <= 1'b0;
        m_sym            <= 2'b00;
        m_valid          <= 1'b0;
        m_lock           <= 1'b0;
        dbg_i            <= 16'sd0;
        dbg_q            <= 16'sd0;
        dbg_best_phase   <= 6'd0;
        dbg_phase_bin    <= 4'd0;
        dbg_lock_score   <= 8'd0;
        for (n = 0; n < SPS; n = n + 1) begin
            hist_i[n] <= {MIX_W{1'b0}};
            hist_q[n] <= {MIX_W{1'b0}};
        end
        for (n = 0; n < 4; n = n + 1) begin
            corr_i[n] <= {CORR_W{1'b0}};
            corr_q[n] <= {CORR_W{1'b0}};
        end
    end else begin
        if (sample_accept) begin
            adc_sample <= s_adc;
        end
        sample_valid_q <= sample_accept;

        m_valid <= 1'b0;
        mix_valid <= 1'b0;
        rot_req_valid <= 1'b0;
        rot_dec_valid <= rot_req_valid;

        if (acq_apply_best_pending && !rot_dec_valid) begin
            acq_apply_best_pending <= 1'b0;
            dd_nco_step_pending <= 1'b0;
            dd_nco_step <= {FREQ_CORR_W{1'b0}};
            nco_freq_corr <= acq_best_freq;
            phase_bin <= acq_best_phase_bin;
            dd_phase_acc <= 13'sd0;
            blind_lock_score <= 8'd0;
            blind_phase_guard <= BLIND_PHASE_GUARD_SYMS;
            blind_prev_sym_valid <= 1'b0;
        end else if (dd_nco_step_pending && !rot_dec_valid) begin
            dd_nco_step_pending <= 1'b0;
            nco_freq_corr <= sat_freq_corr_add(nco_freq_corr, dd_nco_step);
        end
        if (blind_phase_guard_set_pending && !rot_dec_valid) begin
            blind_phase_guard_set_pending <= 1'b0;
            blind_phase_guard <= BLIND_PHASE_GUARD_SYMS;
        end

        if (corr_update_pending) begin
            corr_update_pending <= 1'b0;

            for (n = 0; n < 4; n = n + 1) begin
                exp_sym_tmp = gray_seq4(corr_sym_base_q + n[1:0]);
                corr_re_term = (exp_sym_tmp[0] ? -corr_i_in_q : corr_i_in_q) +
                               (exp_sym_tmp[1] ? -corr_q_in_q : corr_q_in_q);
                corr_im_term = (exp_sym_tmp[0] ? -corr_q_in_q : corr_q_in_q) +
                               (exp_sym_tmp[1] ?  corr_i_in_q : -corr_i_in_q);
                corr_i[n] <= corr_i[n] - (corr_i[n] >>> CORR_LEAK_SHIFT) + corr_re_term;
                corr_q[n] <= corr_q[n] - (corr_q[n] >>> CORR_LEAK_SHIFT) + corr_im_term;
            end

            tracker_state <= TRACK_OFFSET;
            tracker_idx <= 5'd0;
            scan_best_mag <= {CORR_W{1'b0}};
            scan_best_offset <= 2'd0;
            phase_dot_valid <= 1'b0;
        end

        if (sample_proc_accept) begin
            dc_avg <= dc_avg + (dc_err >>> DC_SHIFT);
            phase_acc <= phase_acc + phase_inc_eff;
            mix_i_d <= mix_i;
            mix_q_d <= mix_q;
            mix_valid <= 1'b1;
        end

        if (rot_req_valid) begin
            rot_i_reg <= rot_i_now;
            rot_q_reg <= rot_q_now;
            rot_exp_sym_d <= rot_exp_sym_req;
        end

        if (rot_dec_valid) begin
            if (blind_phase_guard != 5'd0) begin
                blind_phase_guard <= blind_phase_guard - 5'd1;
            end

            exp_lock_sym = rot_exp_sym_d;
            lock_score_next = lock_score;
            if (pattern_track_active) begin
                if (dec_sym_done == exp_lock_sym) begin
                    if (lock_score != 8'hff) begin
                        lock_score_next = lock_score + 8'd1;
                    end
                end else begin
                    if (lock_score != 8'd0) begin
                        lock_score_next = lock_score - 8'd1;
                    end
                end
            end else begin
                lock_score_next = 8'd0;
            end
            lock_score <= lock_score_next;
            pattern_lock_now = pattern_track_active &&
                               (lock_score_next >= PATTERN_LOCK_THRESHOLD);

            if (pattern_lock_now) begin
                track_locked <= 1'b1;
            end else if ((!pattern_track_active) || (lock_score_next <= LOCK_RELEASE_LEVEL)) begin
                track_locked <= 1'b0;
            end

            blind_score_next = blind_lock_score;
            if ((blind_train_active && blind_acq_candidate_ready) || blind_locked) begin
                // When not yet blind-locked this branch is only reachable after
                // the coarse sweep has wrapped, so the fine-quality gate is the
                // post-scan blind_symbol_fine path.
                if (blind_locked ? blind_symbol_stable : blind_symbol_fine) begin
                    if (blind_lock_score != 8'hff) begin
                        blind_score_next = blind_lock_score + 8'd1;
                    end
                end else if (blind_lock_score != 8'd0) begin
                    blind_score_next = blind_lock_score - 8'd1;
                end else begin
                    blind_score_next = 8'd0;
                end
            end else begin
                blind_score_next = 8'd0;
            end
            blind_lock_score <= blind_score_next;

            acq_candidate_score_next = acq_candidate_score;
            if (acq_symbol_score_valid) begin
                if (acq_symbol_score_fine) begin
                    if (acq_candidate_score < 10'h3fe) begin
                        acq_candidate_score_next = acq_candidate_score + 10'd2;
                    end else begin
                        acq_candidate_score_next = 10'h3ff;
                    end
                end else if (acq_candidate_score > 10'd1) begin
                    acq_candidate_score_next = acq_candidate_score - 10'd2;
                end else begin
                    acq_candidate_score_next = 10'd0;
                end
            end
            acq_symbol_score_valid <= blind_train_active && !track_locked &&
                                      !blind_locked && !acq_freq_wrapped &&
                                      blind_symbol_transition &&
                                      (blind_phase_guard == 5'd0);
            acq_symbol_score_fine <= blind_symbol_fine;

            if (blind_train_active || blind_locked) begin
                blind_prev_sym <= dec_sym_done;
                if (blind_phase_guard == 5'd0) begin
                    blind_prev_sym_valid <= 1'b1;
                end
            end else begin
                blind_prev_sym_valid <= 1'b0;
            end

            if (blind_score_next >= BLIND_LOCK_THRESHOLD) begin
                blind_locked <= 1'b1;
            end else if (blind_score_next <= BLIND_RELEASE_LEVEL) begin
                blind_locked <= 1'b0;
            end

            m_sym   <= dec_sym_done;
            m_valid <= track_locked || pattern_lock_now ||
                       blind_locked || (blind_score_next >= BLIND_LOCK_THRESHOLD);
            m_lock  <= track_locked || pattern_lock_now ||
                       blind_locked || (blind_score_next >= BLIND_LOCK_THRESHOLD);
            dbg_i   <= rot_i_reg >>> (NCO_W + 4);
            dbg_q   <= rot_q_reg >>> (NCO_W + 4);
            sym_count <= sym_count + 16'd1;
            // Latch the blind-start delay instead of comparing sym_count
            // continuously, so the 16-bit symbol counter wrap has no effect on
            // acquisition state. Re-acquisition is handled only by the explicit
            // watchdog below.
            if (sym_count >= BLIND_ACQ_DELAY_SYMS) begin
                blind_delay_done <= 1'b1;
            end

            if (decision_track_active || pattern_lock_now ||
                (blind_score_next >= BLIND_LOCK_THRESHOLD)) begin
                dd_acc_next = dd_phase_acc;
                if (dd_abs_phase_err > DD_ERR_DEADBAND) begin
                    dd_acc_next = dd_phase_acc + dd_phase_step;
                end else if (dd_phase_acc > 13'sd0) begin
                    dd_acc_next = dd_phase_acc - 13'sd1;
                end else if (dd_phase_acc < 13'sd0) begin
                    dd_acc_next = dd_phase_acc + 13'sd1;
                end

                if (dd_acc_next >= DD_ACC_LIMIT) begin
                    phase_bin <= phase_bin + 4'd1;
                    if (blind_train_active && !track_locked && !blind_locked &&
                        (blind_score_next < BLIND_LOCK_THRESHOLD)) begin
                        blind_phase_guard_set_pending <= 1'b1;
                    end
                    dd_phase_acc <= dd_acc_next - DD_ACC_LIMIT;
                end else if (dd_acc_next <= -DD_ACC_LIMIT) begin
                    phase_bin <= phase_bin - 4'd1;
                    if (blind_train_active && !track_locked && !blind_locked &&
                        (blind_score_next < BLIND_LOCK_THRESHOLD)) begin
                        blind_phase_guard_set_pending <= 1'b1;
                    end
                    dd_phase_acc <= dd_acc_next + DD_ACC_LIMIT;
                end else begin
                    dd_phase_acc <= dd_acc_next;
                end

                if ((track_locked || blind_locked || pattern_lock_now ||
                     (blind_score_next >= BLIND_LOCK_THRESHOLD)) &&
                    blind_symbol_confident && (dd_abs_phase_err > DD_ERR_DEADBAND)) begin
                    dd_nco_step_pending <= 1'b1;
                    dd_nco_step <= limit_costas_freq_step(dd_phase_err);
                end
            end else begin
                dd_phase_acc <= 13'sd0;
                dd_nco_step_pending <= 1'b0;
                dd_nco_step <= {FREQ_CORR_W{1'b0}};
            end

            if (blind_train_active && !track_locked && !blind_locked &&
                !acq_freq_wrapped &&
                !pattern_lock_now &&
                (blind_lock_score < BLIND_LOCK_THRESHOLD)) begin
                reacq_timeout_cnt <= 11'd0;
                if (acq_freq_dwell >= (ACQ_FREQ_DWELL_SYMS - 9'd1)) begin
                    acq_best_score_next = acq_best_score;
                    acq_best_freq_next = acq_best_freq;
                    acq_best_phase_bin_next = acq_best_phase_bin;
                    if (acq_candidate_score_next > acq_best_score) begin
                        acq_best_score_next = acq_candidate_score_next;
                        acq_best_freq_next = acq_freq_value(acq_freq_idx);
                        acq_best_phase_bin_next = phase_bin;
                    end

                    acq_freq_dwell <= 9'd0;
                    acq_candidate_score <= 10'd0;
                    acq_best_score <= acq_best_score_next;
                    acq_best_freq <= acq_best_freq_next;
                    acq_best_phase_bin <= acq_best_phase_bin_next;
                    blind_lock_score <= 8'd0;
                    blind_phase_guard <= BLIND_PHASE_GUARD_SYMS;
                    blind_phase_guard_set_pending <= 1'b0;
                    blind_prev_sym_valid <= 1'b0;
                    dd_phase_acc <= 13'sd0;
                    dd_nco_step_pending <= 1'b0;
                    dd_nco_step <= {FREQ_CORR_W{1'b0}};
                    if (acq_freq_idx >= ACQ_FREQ_LAST_IDX) begin
                        acq_freq_idx <= 6'd0;
                        acq_freq_wrapped <= 1'b1;
                        acq_apply_best_pending <= 1'b1;
                    end else begin
                        acq_freq_idx <= acq_freq_idx + 6'd1;
                        nco_freq_corr <= acq_freq_value(acq_freq_idx + 6'd1);
                    end
                end else begin
                    acq_freq_dwell <= acq_freq_dwell + 9'd1;
                    acq_candidate_score <= acq_candidate_score_next;
                    nco_freq_corr <= acq_freq_value(acq_freq_idx);
                end
            end else if (track_locked || blind_locked ||
                         pattern_lock_now ||
                         (blind_lock_score >= BLIND_LOCK_THRESHOLD)) begin
                acq_freq_idx <= 6'd0;
                acq_freq_dwell <= 9'd0;
                acq_candidate_score <= 10'd0;
                acq_symbol_score_valid <= 1'b0;
                acq_apply_best_pending <= 1'b0;
                blind_phase_guard_set_pending <= 1'b0;
                blind_phase_guard <= 5'd0;
                blind_prev_sym_valid <= 1'b0;
                reacq_timeout_cnt <= 11'd0;
            end else if (blind_train_active && acq_freq_wrapped) begin
                // Post-sweep wait state: the best sweep candidate has been
                // applied but blind lock has not been reached. If lock does not
                // settle within REACQ_TIMEOUT_SYMS symbols, restart the whole
                // coarse sweep so late-arriving or re-appearing signals are
                // re-acquired deterministically.
                if (reacq_timeout_cnt >= (REACQ_TIMEOUT_SYMS - 11'd1)) begin
                    reacq_timeout_cnt <= 11'd0;
                    acq_freq_idx <= 6'd0;
                    acq_freq_dwell <= 9'd0;
                    acq_freq_wrapped <= 1'b0;
                    acq_candidate_score <= 10'd0;
                    acq_best_score <= 10'd0;
                    acq_best_freq <= {FREQ_CORR_W{1'b0}};
                    acq_best_phase_bin <= 4'd0;
                    acq_symbol_score_valid <= 1'b0;
                    acq_apply_best_pending <= 1'b0;
                    nco_freq_corr <= {FREQ_CORR_W{1'b0}};
                    blind_lock_score <= 8'd0;
                    blind_phase_guard <= BLIND_PHASE_GUARD_SYMS;
                    blind_phase_guard_set_pending <= 1'b0;
                    blind_prev_sym_valid <= 1'b0;
                    dd_phase_acc <= 13'sd0;
                    dd_nco_step_pending <= 1'b0;
                    dd_nco_step <= {FREQ_CORR_W{1'b0}};
                end else begin
                    reacq_timeout_cnt <= reacq_timeout_cnt + 11'd1;
                end
            end else if (!blind_train_active) begin
                acq_freq_idx <= 6'd0;
                acq_freq_dwell <= 9'd0;
                acq_freq_wrapped <= 1'b0;
                acq_candidate_score <= 10'd0;
                acq_best_score <= 10'd0;
                acq_best_freq <= {FREQ_CORR_W{1'b0}};
                acq_best_phase_bin <= 4'd0;
                acq_symbol_score_valid <= 1'b0;
                acq_apply_best_pending <= 1'b0;
                dd_nco_step_pending <= 1'b0;
                dd_nco_step <= {FREQ_CORR_W{1'b0}};
                blind_phase_guard_set_pending <= 1'b0;
                nco_freq_corr <= {FREQ_CORR_W{1'b0}};
                blind_phase_guard <= 5'd0;
                blind_prev_sym_valid <= 1'b0;
                reacq_timeout_cnt <= 11'd0;
            end
        end else begin
            m_lock <= track_locked || blind_locked;
        end

        if (mix_valid) begin
            hist_i[sample_phase] <= mix_i_d;
            hist_q[sample_phase] <= mix_q_d;
            sum_i <= sum_i_next;
            sum_q <= sum_q_next;
            metric_sum_i <= sum_i_next;
            metric_sum_q <= sum_q_next;
            metric_phase <= sample_phase;
            metric_src_valid <= 1'b1;

            if (metric_valid_d) begin
                if (phase_d == 6'd0) begin
                    epoch_best_metric <= metric_d;
                    epoch_best_phase <= 6'd0;
                end else if (metric_d > epoch_best_metric) begin
                    epoch_best_metric <= metric_d;
                    epoch_best_phase <= phase_d;
                end

                if (phase_d == (SPS - 1)) begin
                    if (metric_d > epoch_best_metric) begin
                        epoch_winner_phase = phase_d;
                    end else begin
                        epoch_winner_phase = epoch_best_phase;
                    end

                    if (!timing_ready) begin
                        best_phase <= epoch_winner_phase;
                        timing_track_acc <= 5'sd0;
                    end

                    if (timing_epoch_cnt != 8'hff) begin
                        timing_epoch_cnt <= timing_epoch_cnt + 8'd1;
                    end
                    if (timing_epoch_cnt >= TIMING_ACQ_SYMS[7:0]) begin
                        timing_ready <= 1'b1;
                    end
                end
            end

            metric_d <= timing_metric;
            phase_d <= metric_phase;
            metric_valid_d <= metric_src_valid;

            if (timing_ready && (track_locked || blind_locked) && metric_valid_d) begin
                if (phase_d == phase_prev(best_phase)) begin
                    timing_early_metric <= metric_d;
                    timing_early_valid <= 1'b1;
                end else if (phase_d == phase_next(best_phase)) begin
                    if (timing_early_valid) begin
                        if (timing_early_metric > (metric_d + TIMING_TRACK_DEADBAND)) begin
                            timing_acc_next = timing_track_acc - 5'sd1;
                            if (timing_acc_next <= -TIMING_TRACK_LIMIT) begin
                                best_phase <= phase_prev(best_phase);
                                timing_track_acc <= 5'sd0;
                            end else begin
                                timing_track_acc <= timing_acc_next;
                            end
                        end else if (metric_d > (timing_early_metric + TIMING_TRACK_DEADBAND)) begin
                            timing_acc_next = timing_track_acc + 5'sd1;
                            if (timing_acc_next >= TIMING_TRACK_LIMIT) begin
                                best_phase <= phase_next(best_phase);
                                timing_track_acc <= 5'sd0;
                            end else begin
                                timing_track_acc <= timing_acc_next;
                            end
                        end else if (timing_track_acc > 5'sd0) begin
                            timing_track_acc <= timing_track_acc - 5'sd1;
                        end else if (timing_track_acc < 5'sd0) begin
                            timing_track_acc <= timing_track_acc + 5'sd1;
                        end
                    end
                    timing_early_valid <= 1'b0;
                end
            end else begin
                timing_early_valid <= 1'b0;
                timing_track_acc <= 5'sd0;
            end

            if (!corr_update_pending) begin
            case (tracker_state)
                TRACK_IDLE: begin
                    phase_dot_valid <= 1'b0;
                end

                TRACK_OFFSET: begin
                    corr_mag_tmp = abs_corr(corr_i[tracker_idx[1:0]]) +
                                   abs_corr(corr_q[tracker_idx[1:0]]);
                    if ((tracker_idx[1:0] == 2'd0) || (corr_mag_tmp > scan_best_mag)) begin
                        scan_best_mag <= corr_mag_tmp;
                        scan_best_offset <= tracker_idx[1:0];
                    end

                    if (tracker_idx[1:0] == 2'd3) begin
                        tracker_state <= TRACK_LOAD;
                    end else begin
                        tracker_idx <= tracker_idx + 5'd1;
                    end
                end

                TRACK_LOAD: begin
                    if (!track_locked && !blind_train_active && !blind_locked) begin
                        best_offset <= scan_best_offset;
                    end
                    phase_scan_re <= corr_to_phase_est(corr_i[scan_best_offset]);
                    phase_scan_im <= corr_to_phase_est(corr_q[scan_best_offset]);
                    phase_best_dot <= {1'b1, {(PHASE_DOT_W-1){1'b0}}};
                    phase_best_bin <= 4'd0;
                    phase_dot_d <= {PHASE_DOT_W{1'b0}};
                    phase_dot_bin_d <= 4'd0;
                    phase_dot_valid <= 1'b0;
                    tracker_idx <= 5'd0;
                    tracker_state <= TRACK_ANGLE;
                end

                TRACK_ANGLE: begin
                    if (phase_dot_valid && (phase_dot_d > phase_best_dot)) begin
                        phase_best_dot <= phase_dot_d;
                        phase_best_bin <= phase_dot_bin_d;
                    end

                    phase_dot_d <= phase_dot_now;
                    phase_dot_bin_d <= tracker_idx[3:0];
                    phase_dot_valid <= 1'b1;

                    if (tracker_idx[3:0] == 4'd15) begin
                        tracker_state <= TRACK_IDLE;
                    end
                    tracker_idx <= tracker_idx + 5'd1;
                end
            endcase
            end

            if ((tracker_state == TRACK_IDLE) && phase_dot_valid &&
                !track_locked && !blind_train_active && !blind_locked) begin
                if (phase_dot_d > phase_best_dot) begin
                    phase_bin <= phase_dot_bin_d;
                end else begin
                    phase_bin <= phase_best_bin;
                end
                phase_dot_valid <= 1'b0;
            end

            if (sample_symbol && !corr_update_pending) begin
                corr_i_in_q <= sum_i_next >>> CORR_IN_SHIFT;
                corr_q_in_q <= sum_q_next >>> CORR_IN_SHIFT;
                corr_sym_base_q <= sym_count[1:0];
                corr_update_pending <= 1'b1;
                sym_i_reg <= sum_i_next;
                sym_q_reg <= sum_q_next;
                rot_exp_sym_req <= gray_seq4(sym_count[1:0] + best_offset);
                rot_req_valid <= 1'b1;

                phase_dot_valid <= 1'b0;
            end

            if (sample_phase == (SPS - 1)) begin
                sample_phase <= 6'd0;
            end else begin
                sample_phase <= sample_phase + 6'd1;
            end
        end else begin
            metric_valid_d <= 1'b0;
            metric_src_valid <= 1'b0;
        end

        dbg_best_phase <= best_phase;
        dbg_phase_bin  <= phase_bin;
        dbg_lock_score <= (blind_lock_score > lock_score) ? blind_lock_score : lock_score;
    end
end

endmodule
