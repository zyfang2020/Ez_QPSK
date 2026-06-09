// -----------------------------------------------------------------------------
// Module: qpsk_rx_fixed_demod
// Function: Fixed-carrier QPSK receive demodulator for stage-2 PL loopback.
// Chain:
//   unsigned ADC -> centered/DC-removed -> fixed NCO DDC -> moving-average LPF
//   -> coarse SPS timing phase select -> Gray-cycle phase/quality tracking
//   -> hard QPSK decisions
// Notes:
//   - The first local-test mode assumes the known Gray cycle 00->01->11->10
//     for lock/phase quality. The DDC/timing blocks are kept separate so the
//     phase tracker can later be replaced by a Costas or decision-directed loop.
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
    output reg  [7:0]              dbg_lock_score
);

localparam integer ADC_SIGNED_W = ADC_DW + 1;
localparam integer DC_W = ADC_SIGNED_W + DC_FRAC + 1;
localparam integer ROT_W = SUM_W + NCO_W + 1;
localparam integer PHASE_EST_W = 18;
localparam integer PHASE_EST_SHIFT = 6;
localparam integer PHASE_DOT_W = PHASE_EST_W + NCO_W + 1;
localparam [ADC_SIGNED_W-1:0] ADC_MID = (1 << (ADC_DW-1));
localparam [1:0] TRACK_IDLE   = 2'd0;
localparam [1:0] TRACK_OFFSET = 2'd1;
localparam [1:0] TRACK_LOAD   = 2'd2;
localparam [1:0] TRACK_ANGLE  = 2'd3;

reg [PHASE_W-1:0] phase_acc;
reg [5:0] sample_phase;
reg [7:0] timing_epoch_cnt;
reg timing_ready;
reg [5:0] best_phase;
reg [TIMING_W-1:0] epoch_best_metric;
reg [5:0] epoch_best_phase;
reg [TIMING_W-1:0] metric_d;
reg [5:0] phase_d;
reg metric_valid_d;

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

integer n;

reg signed [CORR_W-1:0] corr_re_term;
reg signed [CORR_W-1:0] corr_im_term;
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

assign s_ready = 1'b1;
assign sample_accept = en && s_valid;
assign sample_proc_accept = en && sample_valid_q;

assign adc_centered = $signed({1'b0, adc_sample}) - $signed(ADC_MID);
assign adc_centered_q = {{(DC_W-ADC_SIGNED_W){adc_centered[ADC_SIGNED_W-1]}}, adc_centered} <<< DC_FRAC;
assign dc_err = adc_centered_q - dc_avg;
assign dc_term = dc_avg >>> DC_FRAC;
assign adc_hp = {{(DC_W-ADC_SIGNED_W){adc_centered[ADC_SIGNED_W-1]}}, adc_centered} - dc_term;

assign nco_idx = phase_acc[PHASE_W-1 -: 4];
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
assign abs_sum_i = abs_sum(sum_i_next);
assign abs_sum_q = abs_sum(sum_q_next);
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
    if (!rst_n) begin
        phase_acc        <= {PHASE_W{1'b0}};
        sample_phase     <= 6'd0;
        timing_epoch_cnt <= 8'd0;
        timing_ready     <= 1'b0;
        best_phase       <= 6'd0;
        epoch_best_metric <= {TIMING_W{1'b0}};
        epoch_best_phase  <= 6'd0;
        metric_d         <= {TIMING_W{1'b0}};
        phase_d          <= 6'd0;
        metric_valid_d   <= 1'b0;
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
    end else if (!en) begin
        phase_acc        <= {PHASE_W{1'b0}};
        sample_phase     <= 6'd0;
        timing_epoch_cnt <= 8'd0;
        timing_ready     <= 1'b0;
        best_phase       <= 6'd0;
        epoch_best_metric <= {TIMING_W{1'b0}};
        epoch_best_phase  <= 6'd0;
        metric_d         <= {TIMING_W{1'b0}};
        phase_d          <= 6'd0;
        metric_valid_d   <= 1'b0;
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
            phase_acc <= phase_acc + cfg_phase_inc;
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
            exp_lock_sym = rot_exp_sym_d;
            if (dec_sym_done == exp_lock_sym) begin
                if (lock_score != 8'hff) begin
                    lock_score <= lock_score + 8'd1;
                end
            end else begin
                if (lock_score != 8'd0) begin
                    lock_score <= lock_score - 8'd1;
                end
            end

            m_sym   <= dec_sym_done;
            m_valid <= 1'b1;
            m_lock  <= (lock_score >= LOCK_THRESHOLD[7:0]);
            dbg_i   <= rot_i_reg >>> (NCO_W + 4);
            dbg_q   <= rot_q_reg >>> (NCO_W + 4);
            sym_count <= sym_count + 16'd1;
        end else begin
            m_lock <= (lock_score >= LOCK_THRESHOLD[7:0]);
        end

        if (mix_valid) begin
            hist_i[sample_phase] <= mix_i_d;
            hist_q[sample_phase] <= mix_q_d;
            sum_i <= sum_i_next;
            sum_q <= sum_q_next;

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
                        best_phase <= phase_d;
                    end else begin
                        best_phase <= epoch_best_phase;
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
            phase_d <= sample_phase;
            metric_valid_d <= 1'b1;

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
                    best_offset <= scan_best_offset;
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

            if ((tracker_state == TRACK_IDLE) && phase_dot_valid) begin
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
        end

        dbg_best_phase <= best_phase;
        dbg_phase_bin  <= phase_bin;
        dbg_lock_score <= lock_score;
    end
end

endmodule
