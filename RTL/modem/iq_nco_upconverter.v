// -----------------------------------------------------------------------------
// 模块: iq_nco_upconverter
// 功能: I/Q 基带数字上变频，输出单路实数样本
// 公式: y[n] = I[n]*cos(w0n) - Q[n]*sin(w0n)
// 说明:
//   - NCO 采用相位累加器 + LUT
//   - 输入/输出均使用 valid/ready 握手
// -----------------------------------------------------------------------------
module iq_nco_upconverter #(
    parameter integer IN_W = 12,
    parameter integer NCO_W = 12,
    parameter integer PHASE_W = 24,
    parameter integer OUT_W = 18
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire signed [IN_W-1:0]        s_i,
    input  wire signed [IN_W-1:0]        s_q,
    input  wire                          s_valid,
    output wire                          s_ready,
    input  wire [PHASE_W-1:0]            cfg_phase_inc,
    output reg  signed [OUT_W-1:0]       m_data,
    output reg                           m_valid,
    input  wire                          m_ready
);

reg [PHASE_W-1:0] phase_acc;
wire [3:0] lut_idx;
wire signed [NCO_W-1:0] cos_val;
wire signed [NCO_W-1:0] sin_val;
wire signed [IN_W+NCO_W-1:0] mul_i_cos;
wire signed [IN_W+NCO_W-1:0] mul_q_sin;
wire signed [IN_W+NCO_W:0] mix_wide;
wire signed [OUT_W-1:0] mix_scaled;

generate
    if (NCO_W != 12) begin : g_nco_w_not_supported
        // synopsys translate_off
        initial begin
            $error("iq_nco_upconverter 当前 LUT 仅支持 NCO_W=12，当前参数 NCO_W=%0d", NCO_W);
        end
        // synopsys translate_on
    end
    if (PHASE_W < 4) begin : g_phase_w_too_small
        // synopsys translate_off
        initial begin
            $error("iq_nco_upconverter 要求 PHASE_W >= 4，当前参数 PHASE_W=%0d", PHASE_W);
        end
        // synopsys translate_on
    end
endgenerate

assign s_ready = (!m_valid) || m_ready;
assign lut_idx = phase_acc[PHASE_W-1 -: 4];
assign cos_val = cos_lut(lut_idx);
assign sin_val = sin_lut(lut_idx);

assign mul_i_cos = s_i * cos_val;
assign mul_q_sin = s_q * sin_val;
assign mix_wide  = mul_i_cos - mul_q_sin;
// NCO 幅值约为 2^(NCO_W-1)，右移后恢复到与 IN_W 同量级
assign mix_scaled = mix_wide >>> (NCO_W-1);

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

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase_acc <= {PHASE_W{1'b0}};
        m_data    <= {OUT_W{1'b0}};
        m_valid   <= 1'b0;
    end else begin
        if (s_valid && s_ready) begin
            m_data  <= mix_scaled;
            m_valid <= 1'b1;
            phase_acc <= phase_acc + cfg_phase_inc;
        end else if (m_ready) begin
            m_valid <= 1'b0;
        end
    end
end

endmodule
