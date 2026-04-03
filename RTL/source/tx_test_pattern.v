// -----------------------------------------------------------------------------
// 模块: tx_test_pattern
// 功能: 发送链最小测试源，输出 data/valid/ready 流
// 模式: 0=常数 1=ramp 2=方波 3=32点正弦LUT
// 时钟: clk（建议在 clk_dac 域使用）
// -----------------------------------------------------------------------------
module tx_test_pattern #(
    parameter integer DW = 12
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire          en,
    input  wire [1:0]    mode_sel,
    input  wire [DW-1:0] cfg_const,
    output reg  [DW-1:0] m_data,
    output reg           m_valid,
    input  wire          m_ready
);

reg [DW-1:0] ramp_cnt;
reg [4:0]    phase_cnt;
reg [DW-1:0] pattern_data;

generate
    if (DW != 12) begin : g_dw_not_supported
        // synopsys translate_off
        initial begin
            $error("tx_test_pattern 当前仅支持 DW=12，当前参数 DW=%0d", DW);
        end
        // synopsys translate_on
    end
endgenerate

function [DW-1:0] sine_lut_32;
    input [4:0] idx;
    begin
        case (idx)
            5'd0:  sine_lut_32 = 12'd2048;
            5'd1:  sine_lut_32 = 12'd2447;
            5'd2:  sine_lut_32 = 12'd2831;
            5'd3:  sine_lut_32 = 12'd3185;
            5'd4:  sine_lut_32 = 12'd3495;
            5'd5:  sine_lut_32 = 12'd3750;
            5'd6:  sine_lut_32 = 12'd3940;
            5'd7:  sine_lut_32 = 12'd4056;
            5'd8:  sine_lut_32 = 12'd4095;
            5'd9:  sine_lut_32 = 12'd4056;
            5'd10: sine_lut_32 = 12'd3940;
            5'd11: sine_lut_32 = 12'd3750;
            5'd12: sine_lut_32 = 12'd3495;
            5'd13: sine_lut_32 = 12'd3185;
            5'd14: sine_lut_32 = 12'd2831;
            5'd15: sine_lut_32 = 12'd2447;
            5'd16: sine_lut_32 = 12'd2048;
            5'd17: sine_lut_32 = 12'd1649;
            5'd18: sine_lut_32 = 12'd1265;
            5'd19: sine_lut_32 = 12'd911;
            5'd20: sine_lut_32 = 12'd601;
            5'd21: sine_lut_32 = 12'd346;
            5'd22: sine_lut_32 = 12'd156;
            5'd23: sine_lut_32 = 12'd40;
            5'd24: sine_lut_32 = 12'd0;
            5'd25: sine_lut_32 = 12'd40;
            5'd26: sine_lut_32 = 12'd156;
            5'd27: sine_lut_32 = 12'd346;
            5'd28: sine_lut_32 = 12'd601;
            5'd29: sine_lut_32 = 12'd911;
            5'd30: sine_lut_32 = 12'd1265;
            5'd31: sine_lut_32 = 12'd1649;
            default: sine_lut_32 = 12'd2048;
        endcase
    end
endfunction

always @(*) begin
    // 组合选择当前测试模式对应的数据
    case (mode_sel)
        2'd0: pattern_data = cfg_const;
        2'd1: pattern_data = ramp_cnt;
        2'd2: pattern_data = ramp_cnt[DW-1] ? {DW{1'b1}} : {DW{1'b0}};
        2'd3: pattern_data = sine_lut_32(phase_cnt);
        default: pattern_data = {DW{1'b0}};
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ramp_cnt <= {DW{1'b0}};
        phase_cnt <= 5'd0;
        m_data <= {DW{1'b0}};
        m_valid <= 1'b0;
    end else begin
        m_valid <= en;

        if (en && m_ready) begin
            // 在握手成功时推进数据源，相当于严格的流控源
            m_data <= pattern_data;
            ramp_cnt <= ramp_cnt + 1'b1;
            phase_cnt <= phase_cnt + 5'd1;
        end
    end
end

endmodule
