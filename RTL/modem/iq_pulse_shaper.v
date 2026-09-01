// -----------------------------------------------------------------------------
// 模块: iq_pulse_shaper
// 功能: 对符号级 I/Q 做 RRC 脉冲成型，输出过采样 I/Q 样本
// 说明:
//   - 当前实现支持 SPS=50（100MHz 采样下对应 2Msym/s）
//   - 滚降系数可选: 0.20 / 0.35 / 0.50（参数 RRC_BETA_SEL）
//   - RRC span=8 symbols, polyphase 结构, Q14 定点系数
// -----------------------------------------------------------------------------

/*
这里记一下自己的理解：
这是一个滤波器其实，然后同时完成了50倍的升采样
他记录了某种滤波器的系数，用来卷积，相当于频域乘积，就滤波了
然后因为不可能记录全部的系数，所以我们这里只记录加上现在一共9个符号的系数（每个idx一组，
一共50个idx，所以一共9x50=450个系数），
注意是符号
然后在一个符号内，每个节拍我们做一次卷积，输出时钟是100M，我们这里符号采样率设置为50
因为我们设置了一共50的phase，它跑完50组才告诉上游自己ready for 新数据
然后按照卷积定义，我们在同一个符号内，一共50个idx，不同的idx将对应被滑动不同距离的滤波器
系数，同时按照数学上的处理，我们是得先插入0再卷积的，但是既然原始数据只有每个符号处有值，
而其他地方为0，所以我们卷积一共9个符号时长的历史时，其实只需要记录9个系数，因为其他地方是
0，有没有系数无所谓，然后idx的位置移动时滤波器也滑动，每个符号上的系数也就变了
然后我们的滤波器系数覆盖了9个历史时长，idx=0和idx涨到50（这里到50会归零）时其实当前符号
和历史符号的系数是一样的，这样50个idx就是一个循环，我们记录50个idx的系数，然后每个符号
内走一遍就行了
*/
module iq_pulse_shaper #(
    parameter integer W = 12,
    parameter integer SPS = 50,
    parameter integer RRC_BETA_SEL = 2  // 0:0.20, 1:0.35, 2:0.50
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire signed [W-1:0]     s_i,
    input  wire signed [W-1:0]     s_q,
    input  wire                    s_valid,
    output wire                    s_ready,
    output reg  signed [W-1:0]     m_i,
    output reg  signed [W-1:0]     m_q,
    output reg                     m_valid,
    input  wire [1:0]              cfg_rrc_beta_sel,
    input  wire                    m_ready
);

localparam integer COEF_W = 16;
localparam integer COEF_Q = 14;
localparam integer SYM_TAPS = 9; // span=8 -> 9 个符号抽头
// ACC_W 的计算：W（输入符号宽度） + COEF_W（RCC系数宽度） + 5（tap数量位宽裕量log2(SYM_TAPS)）
localparam integer ACC_W = W + COEF_W + 5;

integer n;
integer k;
reg [5:0] phase_idx; // 0..49
reg signed [W-1:0] hist_i [0:SYM_TAPS-1];
reg signed [W-1:0] hist_q [0:SYM_TAPS-1];

reg signed [ACC_W-1:0] s1_prod_i [0:SYM_TAPS-1];
reg signed [ACC_W-1:0] s1_prod_q [0:SYM_TAPS-1];
reg signed [ACC_W-1:0] s2_l2_i [0:2];
reg signed [ACC_W-1:0] s2_l2_q [0:2];
reg                    s1_valid;
reg                    s2_valid;
reg signed [W-1:0] sym_i_k;
reg signed [W-1:0] sym_q_k;
reg signed [COEF_W-1:0] coef_k;

wire s3_accept;
wire s2_accept;
wire s1_accept;
wire launch_sample;
wire need_symbol;
wire [1:0] beta_sel;

assign beta_sel = (cfg_rrc_beta_sel == 2'd3) ?
                  ((RRC_BETA_SEL == 0) ? 2'd0 :
                   (RRC_BETA_SEL == 1) ? 2'd1 : 2'd2) :
                  cfg_rrc_beta_sel;
assign s3_accept = (!m_valid) || m_ready;
assign s2_accept = (!s2_valid) || s3_accept;
assign s1_accept = (!s1_valid) || s2_accept;
assign need_symbol = (phase_idx == 6'd0);
assign launch_sample = s1_accept && (!need_symbol || s_valid);
assign s_ready = s1_accept && need_symbol;

generate
    if (SPS != 50) begin : g_sps_not_supported
        // synopsys translate_off
        initial begin
            $error("iq_pulse_shaper 当前仅支持 SPS=50，当前参数 SPS=%0d", SPS);
        end
        // synopsys translate_on
    end
endgenerate

function signed [COEF_W-1:0] rrc_coef_q14;
    input [1:0] sel;
    input [5:0] phase;
    input [3:0] tap;
    begin
        case (sel)
            2'd0: begin // alpha=0.20
                case (phase)
                    6'd0: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd63;
                            4'd1: rrc_coef_q14 = -16'sd87;
                            4'd2: rrc_coef_q14 = 16'sd108;
                            4'd3: rrc_coef_q14 = -16'sd122;
                            4'd4: rrc_coef_q14 = 16'sd2445;
                            4'd5: rrc_coef_q14 = -16'sd122;
                            4'd6: rrc_coef_q14 = 16'sd108;
                            4'd7: rrc_coef_q14 = -16'sd87;
                            4'd8: rrc_coef_q14 = 16'sd63;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd1: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd60;
                            4'd1: rrc_coef_q14 = -16'sd79;
                            4'd2: rrc_coef_q14 = 16'sd90;
                            4'd3: rrc_coef_q14 = -16'sd77;
                            4'd4: rrc_coef_q14 = 16'sd2443;
                            4'd5: rrc_coef_q14 = -16'sd164;
                            4'd6: rrc_coef_q14 = 16'sd125;
                            4'd7: rrc_coef_q14 = -16'sd95;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd2: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd57;
                            4'd1: rrc_coef_q14 = -16'sd70;
                            4'd2: rrc_coef_q14 = 16'sd71;
                            4'd3: rrc_coef_q14 = -16'sd30;
                            4'd4: rrc_coef_q14 = 16'sd2438;
                            4'd5: rrc_coef_q14 = -16'sd204;
                            4'd6: rrc_coef_q14 = 16'sd141;
                            4'd7: rrc_coef_q14 = -16'sd102;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd3: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd53;
                            4'd1: rrc_coef_q14 = -16'sd61;
                            4'd2: rrc_coef_q14 = 16'sd51;
                            4'd3: rrc_coef_q14 = 16'sd19;
                            4'd4: rrc_coef_q14 = 16'sd2429;
                            4'd5: rrc_coef_q14 = -16'sd241;
                            4'd6: rrc_coef_q14 = 16'sd156;
                            4'd7: rrc_coef_q14 = -16'sd108;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd4: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd49;
                            4'd1: rrc_coef_q14 = -16'sd51;
                            4'd2: rrc_coef_q14 = 16'sd30;
                            4'd3: rrc_coef_q14 = 16'sd71;
                            4'd4: rrc_coef_q14 = 16'sd2416;
                            4'd5: rrc_coef_q14 = -16'sd276;
                            4'd6: rrc_coef_q14 = 16'sd170;
                            4'd7: rrc_coef_q14 = -16'sd114;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd5: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd44;
                            4'd1: rrc_coef_q14 = -16'sd41;
                            4'd2: rrc_coef_q14 = 16'sd9;
                            4'd3: rrc_coef_q14 = 16'sd125;
                            4'd4: rrc_coef_q14 = 16'sd2400;
                            4'd5: rrc_coef_q14 = -16'sd308;
                            4'd6: rrc_coef_q14 = 16'sd183;
                            4'd7: rrc_coef_q14 = -16'sd119;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd6: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd39;
                            4'd1: rrc_coef_q14 = -16'sd30;
                            4'd2: rrc_coef_q14 = -16'sd13;
                            4'd3: rrc_coef_q14 = 16'sd180;
                            4'd4: rrc_coef_q14 = 16'sd2380;
                            4'd5: rrc_coef_q14 = -16'sd337;
                            4'd6: rrc_coef_q14 = 16'sd195;
                            4'd7: rrc_coef_q14 = -16'sd124;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd7: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd34;
                            4'd1: rrc_coef_q14 = -16'sd18;
                            4'd2: rrc_coef_q14 = -16'sd36;
                            4'd3: rrc_coef_q14 = 16'sd238;
                            4'd4: rrc_coef_q14 = 16'sd2356;
                            4'd5: rrc_coef_q14 = -16'sd364;
                            4'd6: rrc_coef_q14 = 16'sd205;
                            4'd7: rrc_coef_q14 = -16'sd127;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd8: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd28;
                            4'd1: rrc_coef_q14 = -16'sd7;
                            4'd2: rrc_coef_q14 = -16'sd59;
                            4'd3: rrc_coef_q14 = 16'sd298;
                            4'd4: rrc_coef_q14 = 16'sd2330;
                            4'd5: rrc_coef_q14 = -16'sd388;
                            4'd6: rrc_coef_q14 = 16'sd214;
                            4'd7: rrc_coef_q14 = -16'sd130;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd9: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd23;
                            4'd1: rrc_coef_q14 = 16'sd5;
                            4'd2: rrc_coef_q14 = -16'sd83;
                            4'd3: rrc_coef_q14 = 16'sd359;
                            4'd4: rrc_coef_q14 = 16'sd2299;
                            4'd5: rrc_coef_q14 = -16'sd409;
                            4'd6: rrc_coef_q14 = 16'sd223;
                            4'd7: rrc_coef_q14 = -16'sd132;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd10: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd16;
                            4'd1: rrc_coef_q14 = 16'sd18;
                            4'd2: rrc_coef_q14 = -16'sd107;
                            4'd3: rrc_coef_q14 = 16'sd422;
                            4'd4: rrc_coef_q14 = 16'sd2266;
                            4'd5: rrc_coef_q14 = -16'sd428;
                            4'd6: rrc_coef_q14 = 16'sd229;
                            4'd7: rrc_coef_q14 = -16'sd134;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd11: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd10;
                            4'd1: rrc_coef_q14 = 16'sd30;
                            4'd2: rrc_coef_q14 = -16'sd131;
                            4'd3: rrc_coef_q14 = 16'sd486;
                            4'd4: rrc_coef_q14 = 16'sd2230;
                            4'd5: rrc_coef_q14 = -16'sd444;
                            4'd6: rrc_coef_q14 = 16'sd235;
                            4'd7: rrc_coef_q14 = -16'sd135;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd12: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd3;
                            4'd1: rrc_coef_q14 = 16'sd43;
                            4'd2: rrc_coef_q14 = -16'sd155;
                            4'd3: rrc_coef_q14 = 16'sd552;
                            4'd4: rrc_coef_q14 = 16'sd2190;
                            4'd5: rrc_coef_q14 = -16'sd458;
                            4'd6: rrc_coef_q14 = 16'sd239;
                            4'd7: rrc_coef_q14 = -16'sd135;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd13: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd3;
                            4'd1: rrc_coef_q14 = 16'sd56;
                            4'd2: rrc_coef_q14 = -16'sd179;
                            4'd3: rrc_coef_q14 = 16'sd618;
                            4'd4: rrc_coef_q14 = 16'sd2147;
                            4'd5: rrc_coef_q14 = -16'sd469;
                            4'd6: rrc_coef_q14 = 16'sd242;
                            4'd7: rrc_coef_q14 = -16'sd135;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd14: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd10;
                            4'd1: rrc_coef_q14 = 16'sd69;
                            4'd2: rrc_coef_q14 = -16'sd203;
                            4'd3: rrc_coef_q14 = 16'sd686;
                            4'd4: rrc_coef_q14 = 16'sd2102;
                            4'd5: rrc_coef_q14 = -16'sd478;
                            4'd6: rrc_coef_q14 = 16'sd244;
                            4'd7: rrc_coef_q14 = -16'sd134;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd15: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd17;
                            4'd1: rrc_coef_q14 = 16'sd81;
                            4'd2: rrc_coef_q14 = -16'sd227;
                            4'd3: rrc_coef_q14 = 16'sd755;
                            4'd4: rrc_coef_q14 = 16'sd2054;
                            4'd5: rrc_coef_q14 = -16'sd484;
                            4'd6: rrc_coef_q14 = 16'sd245;
                            4'd7: rrc_coef_q14 = -16'sd132;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd16: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd25;
                            4'd1: rrc_coef_q14 = 16'sd94;
                            4'd2: rrc_coef_q14 = -16'sd251;
                            4'd3: rrc_coef_q14 = 16'sd824;
                            4'd4: rrc_coef_q14 = 16'sd2003;
                            4'd5: rrc_coef_q14 = -16'sd488;
                            4'd6: rrc_coef_q14 = 16'sd245;
                            4'd7: rrc_coef_q14 = -16'sd130;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd17: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd32;
                            4'd1: rrc_coef_q14 = 16'sd107;
                            4'd2: rrc_coef_q14 = -16'sd274;
                            4'd3: rrc_coef_q14 = 16'sd894;
                            4'd4: rrc_coef_q14 = 16'sd1950;
                            4'd5: rrc_coef_q14 = -16'sd489;
                            4'd6: rrc_coef_q14 = 16'sd243;
                            4'd7: rrc_coef_q14 = -16'sd127;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd18: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd39;
                            4'd1: rrc_coef_q14 = 16'sd120;
                            4'd2: rrc_coef_q14 = -16'sd296;
                            4'd3: rrc_coef_q14 = 16'sd965;
                            4'd4: rrc_coef_q14 = 16'sd1894;
                            4'd5: rrc_coef_q14 = -16'sd489;
                            4'd6: rrc_coef_q14 = 16'sd241;
                            4'd7: rrc_coef_q14 = -16'sd124;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd19: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd46;
                            4'd1: rrc_coef_q14 = 16'sd132;
                            4'd2: rrc_coef_q14 = -16'sd318;
                            4'd3: rrc_coef_q14 = 16'sd1035;
                            4'd4: rrc_coef_q14 = 16'sd1836;
                            4'd5: rrc_coef_q14 = -16'sd486;
                            4'd6: rrc_coef_q14 = 16'sd237;
                            4'd7: rrc_coef_q14 = -16'sd120;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd20: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd54;
                            4'd1: rrc_coef_q14 = 16'sd144;
                            4'd2: rrc_coef_q14 = -16'sd339;
                            4'd3: rrc_coef_q14 = 16'sd1106;
                            4'd4: rrc_coef_q14 = 16'sd1777;
                            4'd5: rrc_coef_q14 = -16'sd481;
                            4'd6: rrc_coef_q14 = 16'sd233;
                            4'd7: rrc_coef_q14 = -16'sd116;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd21: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd61;
                            4'd1: rrc_coef_q14 = 16'sd155;
                            4'd2: rrc_coef_q14 = -16'sd359;
                            4'd3: rrc_coef_q14 = 16'sd1177;
                            4'd4: rrc_coef_q14 = 16'sd1715;
                            4'd5: rrc_coef_q14 = -16'sd474;
                            4'd6: rrc_coef_q14 = 16'sd227;
                            4'd7: rrc_coef_q14 = -16'sd111;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd22: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd68;
                            4'd1: rrc_coef_q14 = 16'sd167;
                            4'd2: rrc_coef_q14 = -16'sd378;
                            4'd3: rrc_coef_q14 = 16'sd1247;
                            4'd4: rrc_coef_q14 = 16'sd1652;
                            4'd5: rrc_coef_q14 = -16'sd465;
                            4'd6: rrc_coef_q14 = 16'sd221;
                            4'd7: rrc_coef_q14 = -16'sd106;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd23: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd75;
                            4'd1: rrc_coef_q14 = 16'sd177;
                            4'd2: rrc_coef_q14 = -16'sd396;
                            4'd3: rrc_coef_q14 = 16'sd1317;
                            4'd4: rrc_coef_q14 = 16'sd1587;
                            4'd5: rrc_coef_q14 = -16'sd454;
                            4'd6: rrc_coef_q14 = 16'sd214;
                            4'd7: rrc_coef_q14 = -16'sd100;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd24: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd81;
                            4'd1: rrc_coef_q14 = 16'sd187;
                            4'd2: rrc_coef_q14 = -16'sd413;
                            4'd3: rrc_coef_q14 = 16'sd1386;
                            4'd4: rrc_coef_q14 = 16'sd1521;
                            4'd5: rrc_coef_q14 = -16'sd442;
                            4'd6: rrc_coef_q14 = 16'sd206;
                            4'd7: rrc_coef_q14 = -16'sd94;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd25: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd88;
                            4'd1: rrc_coef_q14 = 16'sd197;
                            4'd2: rrc_coef_q14 = -16'sd428;
                            4'd3: rrc_coef_q14 = 16'sd1454;
                            4'd4: rrc_coef_q14 = 16'sd1454;
                            4'd5: rrc_coef_q14 = -16'sd428;
                            4'd6: rrc_coef_q14 = 16'sd197;
                            4'd7: rrc_coef_q14 = -16'sd88;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd26: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd94;
                            4'd1: rrc_coef_q14 = 16'sd206;
                            4'd2: rrc_coef_q14 = -16'sd442;
                            4'd3: rrc_coef_q14 = 16'sd1521;
                            4'd4: rrc_coef_q14 = 16'sd1386;
                            4'd5: rrc_coef_q14 = -16'sd413;
                            4'd6: rrc_coef_q14 = 16'sd187;
                            4'd7: rrc_coef_q14 = -16'sd81;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd27: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd100;
                            4'd1: rrc_coef_q14 = 16'sd214;
                            4'd2: rrc_coef_q14 = -16'sd454;
                            4'd3: rrc_coef_q14 = 16'sd1587;
                            4'd4: rrc_coef_q14 = 16'sd1317;
                            4'd5: rrc_coef_q14 = -16'sd396;
                            4'd6: rrc_coef_q14 = 16'sd177;
                            4'd7: rrc_coef_q14 = -16'sd75;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd28: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd106;
                            4'd1: rrc_coef_q14 = 16'sd221;
                            4'd2: rrc_coef_q14 = -16'sd465;
                            4'd3: rrc_coef_q14 = 16'sd1652;
                            4'd4: rrc_coef_q14 = 16'sd1247;
                            4'd5: rrc_coef_q14 = -16'sd378;
                            4'd6: rrc_coef_q14 = 16'sd167;
                            4'd7: rrc_coef_q14 = -16'sd68;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd29: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd111;
                            4'd1: rrc_coef_q14 = 16'sd227;
                            4'd2: rrc_coef_q14 = -16'sd474;
                            4'd3: rrc_coef_q14 = 16'sd1715;
                            4'd4: rrc_coef_q14 = 16'sd1177;
                            4'd5: rrc_coef_q14 = -16'sd359;
                            4'd6: rrc_coef_q14 = 16'sd155;
                            4'd7: rrc_coef_q14 = -16'sd61;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd30: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd116;
                            4'd1: rrc_coef_q14 = 16'sd233;
                            4'd2: rrc_coef_q14 = -16'sd481;
                            4'd3: rrc_coef_q14 = 16'sd1777;
                            4'd4: rrc_coef_q14 = 16'sd1106;
                            4'd5: rrc_coef_q14 = -16'sd339;
                            4'd6: rrc_coef_q14 = 16'sd144;
                            4'd7: rrc_coef_q14 = -16'sd54;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd31: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd120;
                            4'd1: rrc_coef_q14 = 16'sd237;
                            4'd2: rrc_coef_q14 = -16'sd486;
                            4'd3: rrc_coef_q14 = 16'sd1836;
                            4'd4: rrc_coef_q14 = 16'sd1035;
                            4'd5: rrc_coef_q14 = -16'sd318;
                            4'd6: rrc_coef_q14 = 16'sd132;
                            4'd7: rrc_coef_q14 = -16'sd46;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd32: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd124;
                            4'd1: rrc_coef_q14 = 16'sd241;
                            4'd2: rrc_coef_q14 = -16'sd489;
                            4'd3: rrc_coef_q14 = 16'sd1894;
                            4'd4: rrc_coef_q14 = 16'sd965;
                            4'd5: rrc_coef_q14 = -16'sd296;
                            4'd6: rrc_coef_q14 = 16'sd120;
                            4'd7: rrc_coef_q14 = -16'sd39;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd33: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd127;
                            4'd1: rrc_coef_q14 = 16'sd243;
                            4'd2: rrc_coef_q14 = -16'sd489;
                            4'd3: rrc_coef_q14 = 16'sd1950;
                            4'd4: rrc_coef_q14 = 16'sd894;
                            4'd5: rrc_coef_q14 = -16'sd274;
                            4'd6: rrc_coef_q14 = 16'sd107;
                            4'd7: rrc_coef_q14 = -16'sd32;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd34: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd130;
                            4'd1: rrc_coef_q14 = 16'sd245;
                            4'd2: rrc_coef_q14 = -16'sd488;
                            4'd3: rrc_coef_q14 = 16'sd2003;
                            4'd4: rrc_coef_q14 = 16'sd824;
                            4'd5: rrc_coef_q14 = -16'sd251;
                            4'd6: rrc_coef_q14 = 16'sd94;
                            4'd7: rrc_coef_q14 = -16'sd25;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd35: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd132;
                            4'd1: rrc_coef_q14 = 16'sd245;
                            4'd2: rrc_coef_q14 = -16'sd484;
                            4'd3: rrc_coef_q14 = 16'sd2054;
                            4'd4: rrc_coef_q14 = 16'sd755;
                            4'd5: rrc_coef_q14 = -16'sd227;
                            4'd6: rrc_coef_q14 = 16'sd81;
                            4'd7: rrc_coef_q14 = -16'sd17;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd36: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd134;
                            4'd1: rrc_coef_q14 = 16'sd244;
                            4'd2: rrc_coef_q14 = -16'sd478;
                            4'd3: rrc_coef_q14 = 16'sd2102;
                            4'd4: rrc_coef_q14 = 16'sd686;
                            4'd5: rrc_coef_q14 = -16'sd203;
                            4'd6: rrc_coef_q14 = 16'sd69;
                            4'd7: rrc_coef_q14 = -16'sd10;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd37: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd135;
                            4'd1: rrc_coef_q14 = 16'sd242;
                            4'd2: rrc_coef_q14 = -16'sd469;
                            4'd3: rrc_coef_q14 = 16'sd2147;
                            4'd4: rrc_coef_q14 = 16'sd618;
                            4'd5: rrc_coef_q14 = -16'sd179;
                            4'd6: rrc_coef_q14 = 16'sd56;
                            4'd7: rrc_coef_q14 = -16'sd3;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd38: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd135;
                            4'd1: rrc_coef_q14 = 16'sd239;
                            4'd2: rrc_coef_q14 = -16'sd458;
                            4'd3: rrc_coef_q14 = 16'sd2190;
                            4'd4: rrc_coef_q14 = 16'sd552;
                            4'd5: rrc_coef_q14 = -16'sd155;
                            4'd6: rrc_coef_q14 = 16'sd43;
                            4'd7: rrc_coef_q14 = 16'sd3;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd39: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd135;
                            4'd1: rrc_coef_q14 = 16'sd235;
                            4'd2: rrc_coef_q14 = -16'sd444;
                            4'd3: rrc_coef_q14 = 16'sd2230;
                            4'd4: rrc_coef_q14 = 16'sd486;
                            4'd5: rrc_coef_q14 = -16'sd131;
                            4'd6: rrc_coef_q14 = 16'sd30;
                            4'd7: rrc_coef_q14 = 16'sd10;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd40: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd134;
                            4'd1: rrc_coef_q14 = 16'sd229;
                            4'd2: rrc_coef_q14 = -16'sd428;
                            4'd3: rrc_coef_q14 = 16'sd2266;
                            4'd4: rrc_coef_q14 = 16'sd422;
                            4'd5: rrc_coef_q14 = -16'sd107;
                            4'd6: rrc_coef_q14 = 16'sd18;
                            4'd7: rrc_coef_q14 = 16'sd16;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd41: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd132;
                            4'd1: rrc_coef_q14 = 16'sd223;
                            4'd2: rrc_coef_q14 = -16'sd409;
                            4'd3: rrc_coef_q14 = 16'sd2299;
                            4'd4: rrc_coef_q14 = 16'sd359;
                            4'd5: rrc_coef_q14 = -16'sd83;
                            4'd6: rrc_coef_q14 = 16'sd5;
                            4'd7: rrc_coef_q14 = 16'sd23;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd42: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd130;
                            4'd1: rrc_coef_q14 = 16'sd214;
                            4'd2: rrc_coef_q14 = -16'sd388;
                            4'd3: rrc_coef_q14 = 16'sd2330;
                            4'd4: rrc_coef_q14 = 16'sd298;
                            4'd5: rrc_coef_q14 = -16'sd59;
                            4'd6: rrc_coef_q14 = -16'sd7;
                            4'd7: rrc_coef_q14 = 16'sd28;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd43: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd127;
                            4'd1: rrc_coef_q14 = 16'sd205;
                            4'd2: rrc_coef_q14 = -16'sd364;
                            4'd3: rrc_coef_q14 = 16'sd2356;
                            4'd4: rrc_coef_q14 = 16'sd238;
                            4'd5: rrc_coef_q14 = -16'sd36;
                            4'd6: rrc_coef_q14 = -16'sd18;
                            4'd7: rrc_coef_q14 = 16'sd34;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd44: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd124;
                            4'd1: rrc_coef_q14 = 16'sd195;
                            4'd2: rrc_coef_q14 = -16'sd337;
                            4'd3: rrc_coef_q14 = 16'sd2380;
                            4'd4: rrc_coef_q14 = 16'sd180;
                            4'd5: rrc_coef_q14 = -16'sd13;
                            4'd6: rrc_coef_q14 = -16'sd30;
                            4'd7: rrc_coef_q14 = 16'sd39;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd45: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd119;
                            4'd1: rrc_coef_q14 = 16'sd183;
                            4'd2: rrc_coef_q14 = -16'sd308;
                            4'd3: rrc_coef_q14 = 16'sd2400;
                            4'd4: rrc_coef_q14 = 16'sd125;
                            4'd5: rrc_coef_q14 = 16'sd9;
                            4'd6: rrc_coef_q14 = -16'sd41;
                            4'd7: rrc_coef_q14 = 16'sd44;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd46: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd114;
                            4'd1: rrc_coef_q14 = 16'sd170;
                            4'd2: rrc_coef_q14 = -16'sd276;
                            4'd3: rrc_coef_q14 = 16'sd2416;
                            4'd4: rrc_coef_q14 = 16'sd71;
                            4'd5: rrc_coef_q14 = 16'sd30;
                            4'd6: rrc_coef_q14 = -16'sd51;
                            4'd7: rrc_coef_q14 = 16'sd49;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd47: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd108;
                            4'd1: rrc_coef_q14 = 16'sd156;
                            4'd2: rrc_coef_q14 = -16'sd241;
                            4'd3: rrc_coef_q14 = 16'sd2429;
                            4'd4: rrc_coef_q14 = 16'sd19;
                            4'd5: rrc_coef_q14 = 16'sd51;
                            4'd6: rrc_coef_q14 = -16'sd61;
                            4'd7: rrc_coef_q14 = 16'sd53;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd48: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd102;
                            4'd1: rrc_coef_q14 = 16'sd141;
                            4'd2: rrc_coef_q14 = -16'sd204;
                            4'd3: rrc_coef_q14 = 16'sd2438;
                            4'd4: rrc_coef_q14 = -16'sd30;
                            4'd5: rrc_coef_q14 = 16'sd71;
                            4'd6: rrc_coef_q14 = -16'sd70;
                            4'd7: rrc_coef_q14 = 16'sd57;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd49: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd95;
                            4'd1: rrc_coef_q14 = 16'sd125;
                            4'd2: rrc_coef_q14 = -16'sd164;
                            4'd3: rrc_coef_q14 = 16'sd2443;
                            4'd4: rrc_coef_q14 = -16'sd77;
                            4'd5: rrc_coef_q14 = 16'sd90;
                            4'd6: rrc_coef_q14 = -16'sd79;
                            4'd7: rrc_coef_q14 = 16'sd60;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    default: rrc_coef_q14 = 16'sd0;
                endcase
            end
            2'd1: begin // alpha=0.35
                case (phase)
                    6'd0: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd5;
                            4'd1: rrc_coef_q14 = -16'sd59;
                            4'd2: rrc_coef_q14 = 16'sd132;
                            4'd3: rrc_coef_q14 = -16'sd196;
                            4'd4: rrc_coef_q14 = 16'sd2539;
                            4'd5: rrc_coef_q14 = -16'sd196;
                            4'd6: rrc_coef_q14 = 16'sd132;
                            4'd7: rrc_coef_q14 = -16'sd59;
                            4'd8: rrc_coef_q14 = 16'sd5;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd1: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd7;
                            4'd1: rrc_coef_q14 = -16'sd60;
                            4'd2: rrc_coef_q14 = 16'sd124;
                            4'd3: rrc_coef_q14 = -16'sd157;
                            4'd4: rrc_coef_q14 = 16'sd2537;
                            4'd5: rrc_coef_q14 = -16'sd232;
                            4'd6: rrc_coef_q14 = 16'sd140;
                            4'd7: rrc_coef_q14 = -16'sd58;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd2: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd10;
                            4'd1: rrc_coef_q14 = -16'sd60;
                            4'd2: rrc_coef_q14 = 16'sd114;
                            4'd3: rrc_coef_q14 = -16'sd116;
                            4'd4: rrc_coef_q14 = 16'sd2530;
                            4'd5: rrc_coef_q14 = -16'sd265;
                            4'd6: rrc_coef_q14 = 16'sd146;
                            4'd7: rrc_coef_q14 = -16'sd56;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd3: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd13;
                            4'd1: rrc_coef_q14 = -16'sd60;
                            4'd2: rrc_coef_q14 = 16'sd103;
                            4'd3: rrc_coef_q14 = -16'sd71;
                            4'd4: rrc_coef_q14 = 16'sd2520;
                            4'd5: rrc_coef_q14 = -16'sd295;
                            4'd6: rrc_coef_q14 = 16'sd152;
                            4'd7: rrc_coef_q14 = -16'sd54;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd4: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd15;
                            4'd1: rrc_coef_q14 = -16'sd60;
                            4'd2: rrc_coef_q14 = 16'sd91;
                            4'd3: rrc_coef_q14 = -16'sd24;
                            4'd4: rrc_coef_q14 = 16'sd2505;
                            4'd5: rrc_coef_q14 = -16'sd322;
                            4'd6: rrc_coef_q14 = 16'sd156;
                            4'd7: rrc_coef_q14 = -16'sd52;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd5: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd18;
                            4'd1: rrc_coef_q14 = -16'sd59;
                            4'd2: rrc_coef_q14 = 16'sd77;
                            4'd3: rrc_coef_q14 = 16'sd26;
                            4'd4: rrc_coef_q14 = 16'sd2486;
                            4'd5: rrc_coef_q14 = -16'sd346;
                            4'd6: rrc_coef_q14 = 16'sd159;
                            4'd7: rrc_coef_q14 = -16'sd49;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd6: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd20;
                            4'd1: rrc_coef_q14 = -16'sd57;
                            4'd2: rrc_coef_q14 = 16'sd63;
                            4'd3: rrc_coef_q14 = 16'sd79;
                            4'd4: rrc_coef_q14 = 16'sd2463;
                            4'd5: rrc_coef_q14 = -16'sd367;
                            4'd6: rrc_coef_q14 = 16'sd161;
                            4'd7: rrc_coef_q14 = -16'sd46;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd7: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd22;
                            4'd1: rrc_coef_q14 = -16'sd55;
                            4'd2: rrc_coef_q14 = 16'sd48;
                            4'd3: rrc_coef_q14 = 16'sd134;
                            4'd4: rrc_coef_q14 = 16'sd2435;
                            4'd5: rrc_coef_q14 = -16'sd386;
                            4'd6: rrc_coef_q14 = 16'sd162;
                            4'd7: rrc_coef_q14 = -16'sd43;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd8: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd24;
                            4'd1: rrc_coef_q14 = -16'sd52;
                            4'd2: rrc_coef_q14 = 16'sd32;
                            4'd3: rrc_coef_q14 = 16'sd192;
                            4'd4: rrc_coef_q14 = 16'sd2404;
                            4'd5: rrc_coef_q14 = -16'sd401;
                            4'd6: rrc_coef_q14 = 16'sd162;
                            4'd7: rrc_coef_q14 = -16'sd39;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd9: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd26;
                            4'd1: rrc_coef_q14 = -16'sd49;
                            4'd2: rrc_coef_q14 = 16'sd15;
                            4'd3: rrc_coef_q14 = 16'sd252;
                            4'd4: rrc_coef_q14 = 16'sd2369;
                            4'd5: rrc_coef_q14 = -16'sd414;
                            4'd6: rrc_coef_q14 = 16'sd162;
                            4'd7: rrc_coef_q14 = -16'sd36;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd10: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd28;
                            4'd1: rrc_coef_q14 = -16'sd46;
                            4'd2: rrc_coef_q14 = -16'sd3;
                            4'd3: rrc_coef_q14 = 16'sd315;
                            4'd4: rrc_coef_q14 = 16'sd2330;
                            4'd5: rrc_coef_q14 = -16'sd424;
                            4'd6: rrc_coef_q14 = 16'sd160;
                            4'd7: rrc_coef_q14 = -16'sd32;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd11: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd29;
                            4'd1: rrc_coef_q14 = -16'sd41;
                            4'd2: rrc_coef_q14 = -16'sd22;
                            4'd3: rrc_coef_q14 = 16'sd379;
                            4'd4: rrc_coef_q14 = 16'sd2288;
                            4'd5: rrc_coef_q14 = -16'sd431;
                            4'd6: rrc_coef_q14 = 16'sd157;
                            4'd7: rrc_coef_q14 = -16'sd28;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd12: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd30;
                            4'd1: rrc_coef_q14 = -16'sd37;
                            4'd2: rrc_coef_q14 = -16'sd41;
                            4'd3: rrc_coef_q14 = 16'sd445;
                            4'd4: rrc_coef_q14 = 16'sd2242;
                            4'd5: rrc_coef_q14 = -16'sd436;
                            4'd6: rrc_coef_q14 = 16'sd153;
                            4'd7: rrc_coef_q14 = -16'sd24;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd13: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd31;
                            4'd1: rrc_coef_q14 = -16'sd32;
                            4'd2: rrc_coef_q14 = -16'sd61;
                            4'd3: rrc_coef_q14 = 16'sd514;
                            4'd4: rrc_coef_q14 = 16'sd2193;
                            4'd5: rrc_coef_q14 = -16'sd438;
                            4'd6: rrc_coef_q14 = 16'sd149;
                            4'd7: rrc_coef_q14 = -16'sd20;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd14: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd32;
                            4'd1: rrc_coef_q14 = -16'sd26;
                            4'd2: rrc_coef_q14 = -16'sd82;
                            4'd3: rrc_coef_q14 = 16'sd584;
                            4'd4: rrc_coef_q14 = 16'sd2141;
                            4'd5: rrc_coef_q14 = -16'sd438;
                            4'd6: rrc_coef_q14 = 16'sd144;
                            4'd7: rrc_coef_q14 = -16'sd16;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd15: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd33;
                            4'd1: rrc_coef_q14 = -16'sd20;
                            4'd2: rrc_coef_q14 = -16'sd103;
                            4'd3: rrc_coef_q14 = 16'sd655;
                            4'd4: rrc_coef_q14 = 16'sd2085;
                            4'd5: rrc_coef_q14 = -16'sd436;
                            4'd6: rrc_coef_q14 = 16'sd139;
                            4'd7: rrc_coef_q14 = -16'sd12;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd16: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd33;
                            4'd1: rrc_coef_q14 = -16'sd13;
                            4'd2: rrc_coef_q14 = -16'sd124;
                            4'd3: rrc_coef_q14 = 16'sd728;
                            4'd4: rrc_coef_q14 = 16'sd2027;
                            4'd5: rrc_coef_q14 = -16'sd431;
                            4'd6: rrc_coef_q14 = 16'sd132;
                            4'd7: rrc_coef_q14 = -16'sd8;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd17: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd33;
                            4'd1: rrc_coef_q14 = -16'sd6;
                            4'd2: rrc_coef_q14 = -16'sd146;
                            4'd3: rrc_coef_q14 = 16'sd802;
                            4'd4: rrc_coef_q14 = 16'sd1966;
                            4'd5: rrc_coef_q14 = -16'sd424;
                            4'd6: rrc_coef_q14 = 16'sd125;
                            4'd7: rrc_coef_q14 = -16'sd4;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd18: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd32;
                            4'd1: rrc_coef_q14 = 16'sd1;
                            4'd2: rrc_coef_q14 = -16'sd167;
                            4'd3: rrc_coef_q14 = 16'sd876;
                            4'd4: rrc_coef_q14 = 16'sd1903;
                            4'd5: rrc_coef_q14 = -16'sd416;
                            4'd6: rrc_coef_q14 = 16'sd118;
                            4'd7: rrc_coef_q14 = 16'sd0;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd19: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd32;
                            4'd1: rrc_coef_q14 = 16'sd9;
                            4'd2: rrc_coef_q14 = -16'sd189;
                            4'd3: rrc_coef_q14 = 16'sd952;
                            4'd4: rrc_coef_q14 = 16'sd1838;
                            4'd5: rrc_coef_q14 = -16'sd406;
                            4'd6: rrc_coef_q14 = 16'sd111;
                            4'd7: rrc_coef_q14 = 16'sd4;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd20: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd31;
                            4'd1: rrc_coef_q14 = 16'sd17;
                            4'd2: rrc_coef_q14 = -16'sd211;
                            4'd3: rrc_coef_q14 = 16'sd1028;
                            4'd4: rrc_coef_q14 = 16'sd1770;
                            4'd5: rrc_coef_q14 = -16'sd394;
                            4'd6: rrc_coef_q14 = 16'sd103;
                            4'd7: rrc_coef_q14 = 16'sd7;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd21: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd30;
                            4'd1: rrc_coef_q14 = 16'sd25;
                            4'd2: rrc_coef_q14 = -16'sd232;
                            4'd3: rrc_coef_q14 = 16'sd1104;
                            4'd4: rrc_coef_q14 = 16'sd1700;
                            4'd5: rrc_coef_q14 = -16'sd380;
                            4'd6: rrc_coef_q14 = 16'sd94;
                            4'd7: rrc_coef_q14 = 16'sd11;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd22: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd28;
                            4'd1: rrc_coef_q14 = 16'sd33;
                            4'd2: rrc_coef_q14 = -16'sd253;
                            4'd3: rrc_coef_q14 = 16'sd1181;
                            4'd4: rrc_coef_q14 = 16'sd1629;
                            4'd5: rrc_coef_q14 = -16'sd365;
                            4'd6: rrc_coef_q14 = 16'sd86;
                            4'd7: rrc_coef_q14 = 16'sd14;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd23: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd27;
                            4'd1: rrc_coef_q14 = 16'sd42;
                            4'd2: rrc_coef_q14 = -16'sd274;
                            4'd3: rrc_coef_q14 = 16'sd1257;
                            4'd4: rrc_coef_q14 = 16'sd1557;
                            4'd5: rrc_coef_q14 = -16'sd349;
                            4'd6: rrc_coef_q14 = 16'sd77;
                            4'd7: rrc_coef_q14 = 16'sd17;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd24: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd24;
                            4'd1: rrc_coef_q14 = 16'sd51;
                            4'd2: rrc_coef_q14 = -16'sd294;
                            4'd3: rrc_coef_q14 = 16'sd1333;
                            4'd4: rrc_coef_q14 = 16'sd1483;
                            4'd5: rrc_coef_q14 = -16'sd332;
                            4'd6: rrc_coef_q14 = 16'sd68;
                            4'd7: rrc_coef_q14 = 16'sd20;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd25: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd22;
                            4'd1: rrc_coef_q14 = 16'sd59;
                            4'd2: rrc_coef_q14 = -16'sd313;
                            4'd3: rrc_coef_q14 = 16'sd1408;
                            4'd4: rrc_coef_q14 = 16'sd1408;
                            4'd5: rrc_coef_q14 = -16'sd313;
                            4'd6: rrc_coef_q14 = 16'sd59;
                            4'd7: rrc_coef_q14 = 16'sd22;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd26: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd20;
                            4'd1: rrc_coef_q14 = 16'sd68;
                            4'd2: rrc_coef_q14 = -16'sd332;
                            4'd3: rrc_coef_q14 = 16'sd1483;
                            4'd4: rrc_coef_q14 = 16'sd1333;
                            4'd5: rrc_coef_q14 = -16'sd294;
                            4'd6: rrc_coef_q14 = 16'sd51;
                            4'd7: rrc_coef_q14 = 16'sd24;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd27: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd17;
                            4'd1: rrc_coef_q14 = 16'sd77;
                            4'd2: rrc_coef_q14 = -16'sd349;
                            4'd3: rrc_coef_q14 = 16'sd1557;
                            4'd4: rrc_coef_q14 = 16'sd1257;
                            4'd5: rrc_coef_q14 = -16'sd274;
                            4'd6: rrc_coef_q14 = 16'sd42;
                            4'd7: rrc_coef_q14 = 16'sd27;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd28: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd14;
                            4'd1: rrc_coef_q14 = 16'sd86;
                            4'd2: rrc_coef_q14 = -16'sd365;
                            4'd3: rrc_coef_q14 = 16'sd1629;
                            4'd4: rrc_coef_q14 = 16'sd1181;
                            4'd5: rrc_coef_q14 = -16'sd253;
                            4'd6: rrc_coef_q14 = 16'sd33;
                            4'd7: rrc_coef_q14 = 16'sd28;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd29: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd11;
                            4'd1: rrc_coef_q14 = 16'sd94;
                            4'd2: rrc_coef_q14 = -16'sd380;
                            4'd3: rrc_coef_q14 = 16'sd1700;
                            4'd4: rrc_coef_q14 = 16'sd1104;
                            4'd5: rrc_coef_q14 = -16'sd232;
                            4'd6: rrc_coef_q14 = 16'sd25;
                            4'd7: rrc_coef_q14 = 16'sd30;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd30: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd7;
                            4'd1: rrc_coef_q14 = 16'sd103;
                            4'd2: rrc_coef_q14 = -16'sd394;
                            4'd3: rrc_coef_q14 = 16'sd1770;
                            4'd4: rrc_coef_q14 = 16'sd1028;
                            4'd5: rrc_coef_q14 = -16'sd211;
                            4'd6: rrc_coef_q14 = 16'sd17;
                            4'd7: rrc_coef_q14 = 16'sd31;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd31: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd4;
                            4'd1: rrc_coef_q14 = 16'sd111;
                            4'd2: rrc_coef_q14 = -16'sd406;
                            4'd3: rrc_coef_q14 = 16'sd1838;
                            4'd4: rrc_coef_q14 = 16'sd952;
                            4'd5: rrc_coef_q14 = -16'sd189;
                            4'd6: rrc_coef_q14 = 16'sd9;
                            4'd7: rrc_coef_q14 = 16'sd32;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd32: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd0;
                            4'd1: rrc_coef_q14 = 16'sd118;
                            4'd2: rrc_coef_q14 = -16'sd416;
                            4'd3: rrc_coef_q14 = 16'sd1903;
                            4'd4: rrc_coef_q14 = 16'sd876;
                            4'd5: rrc_coef_q14 = -16'sd167;
                            4'd6: rrc_coef_q14 = 16'sd1;
                            4'd7: rrc_coef_q14 = 16'sd32;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd33: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd4;
                            4'd1: rrc_coef_q14 = 16'sd125;
                            4'd2: rrc_coef_q14 = -16'sd424;
                            4'd3: rrc_coef_q14 = 16'sd1966;
                            4'd4: rrc_coef_q14 = 16'sd802;
                            4'd5: rrc_coef_q14 = -16'sd146;
                            4'd6: rrc_coef_q14 = -16'sd6;
                            4'd7: rrc_coef_q14 = 16'sd33;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd34: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd8;
                            4'd1: rrc_coef_q14 = 16'sd132;
                            4'd2: rrc_coef_q14 = -16'sd431;
                            4'd3: rrc_coef_q14 = 16'sd2027;
                            4'd4: rrc_coef_q14 = 16'sd728;
                            4'd5: rrc_coef_q14 = -16'sd124;
                            4'd6: rrc_coef_q14 = -16'sd13;
                            4'd7: rrc_coef_q14 = 16'sd33;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd35: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd12;
                            4'd1: rrc_coef_q14 = 16'sd139;
                            4'd2: rrc_coef_q14 = -16'sd436;
                            4'd3: rrc_coef_q14 = 16'sd2085;
                            4'd4: rrc_coef_q14 = 16'sd655;
                            4'd5: rrc_coef_q14 = -16'sd103;
                            4'd6: rrc_coef_q14 = -16'sd20;
                            4'd7: rrc_coef_q14 = 16'sd33;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd36: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd16;
                            4'd1: rrc_coef_q14 = 16'sd144;
                            4'd2: rrc_coef_q14 = -16'sd438;
                            4'd3: rrc_coef_q14 = 16'sd2141;
                            4'd4: rrc_coef_q14 = 16'sd584;
                            4'd5: rrc_coef_q14 = -16'sd82;
                            4'd6: rrc_coef_q14 = -16'sd26;
                            4'd7: rrc_coef_q14 = 16'sd32;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd37: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd20;
                            4'd1: rrc_coef_q14 = 16'sd149;
                            4'd2: rrc_coef_q14 = -16'sd438;
                            4'd3: rrc_coef_q14 = 16'sd2193;
                            4'd4: rrc_coef_q14 = 16'sd514;
                            4'd5: rrc_coef_q14 = -16'sd61;
                            4'd6: rrc_coef_q14 = -16'sd32;
                            4'd7: rrc_coef_q14 = 16'sd31;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd38: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd24;
                            4'd1: rrc_coef_q14 = 16'sd153;
                            4'd2: rrc_coef_q14 = -16'sd436;
                            4'd3: rrc_coef_q14 = 16'sd2242;
                            4'd4: rrc_coef_q14 = 16'sd445;
                            4'd5: rrc_coef_q14 = -16'sd41;
                            4'd6: rrc_coef_q14 = -16'sd37;
                            4'd7: rrc_coef_q14 = 16'sd30;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd39: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd28;
                            4'd1: rrc_coef_q14 = 16'sd157;
                            4'd2: rrc_coef_q14 = -16'sd431;
                            4'd3: rrc_coef_q14 = 16'sd2288;
                            4'd4: rrc_coef_q14 = 16'sd379;
                            4'd5: rrc_coef_q14 = -16'sd22;
                            4'd6: rrc_coef_q14 = -16'sd41;
                            4'd7: rrc_coef_q14 = 16'sd29;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd40: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd32;
                            4'd1: rrc_coef_q14 = 16'sd160;
                            4'd2: rrc_coef_q14 = -16'sd424;
                            4'd3: rrc_coef_q14 = 16'sd2330;
                            4'd4: rrc_coef_q14 = 16'sd315;
                            4'd5: rrc_coef_q14 = -16'sd3;
                            4'd6: rrc_coef_q14 = -16'sd46;
                            4'd7: rrc_coef_q14 = 16'sd28;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd41: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd36;
                            4'd1: rrc_coef_q14 = 16'sd162;
                            4'd2: rrc_coef_q14 = -16'sd414;
                            4'd3: rrc_coef_q14 = 16'sd2369;
                            4'd4: rrc_coef_q14 = 16'sd252;
                            4'd5: rrc_coef_q14 = 16'sd15;
                            4'd6: rrc_coef_q14 = -16'sd49;
                            4'd7: rrc_coef_q14 = 16'sd26;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd42: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd39;
                            4'd1: rrc_coef_q14 = 16'sd162;
                            4'd2: rrc_coef_q14 = -16'sd401;
                            4'd3: rrc_coef_q14 = 16'sd2404;
                            4'd4: rrc_coef_q14 = 16'sd192;
                            4'd5: rrc_coef_q14 = 16'sd32;
                            4'd6: rrc_coef_q14 = -16'sd52;
                            4'd7: rrc_coef_q14 = 16'sd24;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd43: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd43;
                            4'd1: rrc_coef_q14 = 16'sd162;
                            4'd2: rrc_coef_q14 = -16'sd386;
                            4'd3: rrc_coef_q14 = 16'sd2435;
                            4'd4: rrc_coef_q14 = 16'sd134;
                            4'd5: rrc_coef_q14 = 16'sd48;
                            4'd6: rrc_coef_q14 = -16'sd55;
                            4'd7: rrc_coef_q14 = 16'sd22;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd44: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd46;
                            4'd1: rrc_coef_q14 = 16'sd161;
                            4'd2: rrc_coef_q14 = -16'sd367;
                            4'd3: rrc_coef_q14 = 16'sd2463;
                            4'd4: rrc_coef_q14 = 16'sd79;
                            4'd5: rrc_coef_q14 = 16'sd63;
                            4'd6: rrc_coef_q14 = -16'sd57;
                            4'd7: rrc_coef_q14 = 16'sd20;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd45: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd49;
                            4'd1: rrc_coef_q14 = 16'sd159;
                            4'd2: rrc_coef_q14 = -16'sd346;
                            4'd3: rrc_coef_q14 = 16'sd2486;
                            4'd4: rrc_coef_q14 = 16'sd26;
                            4'd5: rrc_coef_q14 = 16'sd77;
                            4'd6: rrc_coef_q14 = -16'sd59;
                            4'd7: rrc_coef_q14 = 16'sd18;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd46: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd52;
                            4'd1: rrc_coef_q14 = 16'sd156;
                            4'd2: rrc_coef_q14 = -16'sd322;
                            4'd3: rrc_coef_q14 = 16'sd2505;
                            4'd4: rrc_coef_q14 = -16'sd24;
                            4'd5: rrc_coef_q14 = 16'sd91;
                            4'd6: rrc_coef_q14 = -16'sd60;
                            4'd7: rrc_coef_q14 = 16'sd15;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd47: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd54;
                            4'd1: rrc_coef_q14 = 16'sd152;
                            4'd2: rrc_coef_q14 = -16'sd295;
                            4'd3: rrc_coef_q14 = 16'sd2520;
                            4'd4: rrc_coef_q14 = -16'sd71;
                            4'd5: rrc_coef_q14 = 16'sd103;
                            4'd6: rrc_coef_q14 = -16'sd60;
                            4'd7: rrc_coef_q14 = 16'sd13;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd48: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd56;
                            4'd1: rrc_coef_q14 = 16'sd146;
                            4'd2: rrc_coef_q14 = -16'sd265;
                            4'd3: rrc_coef_q14 = 16'sd2530;
                            4'd4: rrc_coef_q14 = -16'sd116;
                            4'd5: rrc_coef_q14 = 16'sd114;
                            4'd6: rrc_coef_q14 = -16'sd60;
                            4'd7: rrc_coef_q14 = 16'sd10;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd49: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd58;
                            4'd1: rrc_coef_q14 = 16'sd140;
                            4'd2: rrc_coef_q14 = -16'sd232;
                            4'd3: rrc_coef_q14 = 16'sd2537;
                            4'd4: rrc_coef_q14 = -16'sd157;
                            4'd5: rrc_coef_q14 = 16'sd124;
                            4'd6: rrc_coef_q14 = -16'sd60;
                            4'd7: rrc_coef_q14 = 16'sd7;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    default: rrc_coef_q14 = 16'sd0;
                endcase
            end
            2'd2: begin // alpha=0.50
                case (phase)
                    6'd0: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd23;
                            4'd1: rrc_coef_q14 = 16'sd7;
                            4'd2: rrc_coef_q14 = 16'sd98;
                            4'd3: rrc_coef_q14 = -16'sd246;
                            4'd4: rrc_coef_q14 = 16'sd2634;
                            4'd5: rrc_coef_q14 = -16'sd246;
                            4'd6: rrc_coef_q14 = 16'sd98;
                            4'd7: rrc_coef_q14 = 16'sd7;
                            4'd8: rrc_coef_q14 = -16'sd23;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd1: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd23;
                            4'd1: rrc_coef_q14 = 16'sd3;
                            4'd2: rrc_coef_q14 = 16'sd99;
                            4'd3: rrc_coef_q14 = -16'sd216;
                            4'd4: rrc_coef_q14 = 16'sd2631;
                            4'd5: rrc_coef_q14 = -16'sd273;
                            4'd6: rrc_coef_q14 = 16'sd97;
                            4'd7: rrc_coef_q14 = 16'sd11;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd2: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd23;
                            4'd1: rrc_coef_q14 = -16'sd1;
                            4'd2: rrc_coef_q14 = 16'sd99;
                            4'd3: rrc_coef_q14 = -16'sd183;
                            4'd4: rrc_coef_q14 = 16'sd2624;
                            4'd5: rrc_coef_q14 = -16'sd296;
                            4'd6: rrc_coef_q14 = 16'sd94;
                            4'd7: rrc_coef_q14 = 16'sd14;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd3: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd23;
                            4'd1: rrc_coef_q14 = -16'sd5;
                            4'd2: rrc_coef_q14 = 16'sd98;
                            4'd3: rrc_coef_q14 = -16'sd146;
                            4'd4: rrc_coef_q14 = 16'sd2611;
                            4'd5: rrc_coef_q14 = -16'sd316;
                            4'd6: rrc_coef_q14 = 16'sd91;
                            4'd7: rrc_coef_q14 = 16'sd18;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd4: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd22;
                            4'd1: rrc_coef_q14 = -16'sd9;
                            4'd2: rrc_coef_q14 = 16'sd96;
                            4'd3: rrc_coef_q14 = -16'sd106;
                            4'd4: rrc_coef_q14 = 16'sd2594;
                            4'd5: rrc_coef_q14 = -16'sd333;
                            4'd6: rrc_coef_q14 = 16'sd87;
                            4'd7: rrc_coef_q14 = 16'sd21;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd5: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd21;
                            4'd1: rrc_coef_q14 = -16'sd13;
                            4'd2: rrc_coef_q14 = 16'sd93;
                            4'd3: rrc_coef_q14 = -16'sd62;
                            4'd4: rrc_coef_q14 = 16'sd2571;
                            4'd5: rrc_coef_q14 = -16'sd347;
                            4'd6: rrc_coef_q14 = 16'sd82;
                            4'd7: rrc_coef_q14 = 16'sd24;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd6: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd20;
                            4'd1: rrc_coef_q14 = -16'sd17;
                            4'd2: rrc_coef_q14 = 16'sd89;
                            4'd3: rrc_coef_q14 = -16'sd16;
                            4'd4: rrc_coef_q14 = 16'sd2544;
                            4'd5: rrc_coef_q14 = -16'sd358;
                            4'd6: rrc_coef_q14 = 16'sd77;
                            4'd7: rrc_coef_q14 = 16'sd27;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd7: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd19;
                            4'd1: rrc_coef_q14 = -16'sd21;
                            4'd2: rrc_coef_q14 = 16'sd84;
                            4'd3: rrc_coef_q14 = 16'sd34;
                            4'd4: rrc_coef_q14 = 16'sd2512;
                            4'd5: rrc_coef_q14 = -16'sd366;
                            4'd6: rrc_coef_q14 = 16'sd72;
                            4'd7: rrc_coef_q14 = 16'sd29;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd8: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd18;
                            4'd1: rrc_coef_q14 = -16'sd24;
                            4'd2: rrc_coef_q14 = 16'sd78;
                            4'd3: rrc_coef_q14 = 16'sd87;
                            4'd4: rrc_coef_q14 = 16'sd2475;
                            4'd5: rrc_coef_q14 = -16'sd371;
                            4'd6: rrc_coef_q14 = 16'sd66;
                            4'd7: rrc_coef_q14 = 16'sd32;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd9: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd16;
                            4'd1: rrc_coef_q14 = -16'sd28;
                            4'd2: rrc_coef_q14 = 16'sd70;
                            4'd3: rrc_coef_q14 = 16'sd144;
                            4'd4: rrc_coef_q14 = 16'sd2434;
                            4'd5: rrc_coef_q14 = -16'sd374;
                            4'd6: rrc_coef_q14 = 16'sd59;
                            4'd7: rrc_coef_q14 = 16'sd34;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd10: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd14;
                            4'd1: rrc_coef_q14 = -16'sd31;
                            4'd2: rrc_coef_q14 = 16'sd62;
                            4'd3: rrc_coef_q14 = 16'sd203;
                            4'd4: rrc_coef_q14 = 16'sd2389;
                            4'd5: rrc_coef_q14 = -16'sd374;
                            4'd6: rrc_coef_q14 = 16'sd53;
                            4'd7: rrc_coef_q14 = 16'sd35;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd11: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd12;
                            4'd1: rrc_coef_q14 = -16'sd34;
                            4'd2: rrc_coef_q14 = 16'sd52;
                            4'd3: rrc_coef_q14 = 16'sd265;
                            4'd4: rrc_coef_q14 = 16'sd2340;
                            4'd5: rrc_coef_q14 = -16'sd371;
                            4'd6: rrc_coef_q14 = 16'sd46;
                            4'd7: rrc_coef_q14 = 16'sd37;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd12: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd10;
                            4'd1: rrc_coef_q14 = -16'sd37;
                            4'd2: rrc_coef_q14 = 16'sd42;
                            4'd3: rrc_coef_q14 = 16'sd330;
                            4'd4: rrc_coef_q14 = 16'sd2286;
                            4'd5: rrc_coef_q14 = -16'sd367;
                            4'd6: rrc_coef_q14 = 16'sd39;
                            4'd7: rrc_coef_q14 = 16'sd38;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd13: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd8;
                            4'd1: rrc_coef_q14 = -16'sd39;
                            4'd2: rrc_coef_q14 = 16'sd30;
                            4'd3: rrc_coef_q14 = 16'sd398;
                            4'd4: rrc_coef_q14 = 16'sd2229;
                            4'd5: rrc_coef_q14 = -16'sd360;
                            4'd6: rrc_coef_q14 = 16'sd32;
                            4'd7: rrc_coef_q14 = 16'sd38;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd14: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd5;
                            4'd1: rrc_coef_q14 = -16'sd41;
                            4'd2: rrc_coef_q14 = 16'sd17;
                            4'd3: rrc_coef_q14 = 16'sd467;
                            4'd4: rrc_coef_q14 = 16'sd2169;
                            4'd5: rrc_coef_q14 = -16'sd351;
                            4'd6: rrc_coef_q14 = 16'sd25;
                            4'd7: rrc_coef_q14 = 16'sd39;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd15: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = -16'sd3;
                            4'd1: rrc_coef_q14 = -16'sd43;
                            4'd2: rrc_coef_q14 = 16'sd3;
                            4'd3: rrc_coef_q14 = 16'sd540;
                            4'd4: rrc_coef_q14 = 16'sd2105;
                            4'd5: rrc_coef_q14 = -16'sd341;
                            4'd6: rrc_coef_q14 = 16'sd19;
                            4'd7: rrc_coef_q14 = 16'sd39;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd16: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd0;
                            4'd1: rrc_coef_q14 = -16'sd44;
                            4'd2: rrc_coef_q14 = -16'sd12;
                            4'd3: rrc_coef_q14 = 16'sd614;
                            4'd4: rrc_coef_q14 = 16'sd2038;
                            4'd5: rrc_coef_q14 = -16'sd329;
                            4'd6: rrc_coef_q14 = 16'sd12;
                            4'd7: rrc_coef_q14 = 16'sd39;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd17: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd3;
                            4'd1: rrc_coef_q14 = -16'sd45;
                            4'd2: rrc_coef_q14 = -16'sd27;
                            4'd3: rrc_coef_q14 = 16'sd690;
                            4'd4: rrc_coef_q14 = 16'sd1968;
                            4'd5: rrc_coef_q14 = -16'sd315;
                            4'd6: rrc_coef_q14 = 16'sd5;
                            4'd7: rrc_coef_q14 = 16'sd38;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd18: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd6;
                            4'd1: rrc_coef_q14 = -16'sd46;
                            4'd2: rrc_coef_q14 = -16'sd44;
                            4'd3: rrc_coef_q14 = 16'sd768;
                            4'd4: rrc_coef_q14 = 16'sd1896;
                            4'd5: rrc_coef_q14 = -16'sd300;
                            4'd6: rrc_coef_q14 = -16'sd1;
                            4'd7: rrc_coef_q14 = 16'sd37;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd19: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd8;
                            4'd1: rrc_coef_q14 = -16'sd46;
                            4'd2: rrc_coef_q14 = -16'sd61;
                            4'd3: rrc_coef_q14 = 16'sd848;
                            4'd4: rrc_coef_q14 = 16'sd1821;
                            4'd5: rrc_coef_q14 = -16'sd284;
                            4'd6: rrc_coef_q14 = -16'sd7;
                            4'd7: rrc_coef_q14 = 16'sd36;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd20: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd11;
                            4'd1: rrc_coef_q14 = -16'sd45;
                            4'd2: rrc_coef_q14 = -16'sd79;
                            4'd3: rrc_coef_q14 = 16'sd928;
                            4'd4: rrc_coef_q14 = 16'sd1744;
                            4'd5: rrc_coef_q14 = -16'sd267;
                            4'd6: rrc_coef_q14 = -16'sd12;
                            4'd7: rrc_coef_q14 = 16'sd35;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd21: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd14;
                            4'd1: rrc_coef_q14 = -16'sd44;
                            4'd2: rrc_coef_q14 = -16'sd97;
                            4'd3: rrc_coef_q14 = 16'sd1010;
                            4'd4: rrc_coef_q14 = 16'sd1666;
                            4'd5: rrc_coef_q14 = -16'sd250;
                            4'd6: rrc_coef_q14 = -16'sd18;
                            4'd7: rrc_coef_q14 = 16'sd33;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd22: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd17;
                            4'd1: rrc_coef_q14 = -16'sd42;
                            4'd2: rrc_coef_q14 = -16'sd116;
                            4'd3: rrc_coef_q14 = 16'sd1092;
                            4'd4: rrc_coef_q14 = 16'sd1586;
                            4'd5: rrc_coef_q14 = -16'sd231;
                            4'd6: rrc_coef_q14 = -16'sd23;
                            4'd7: rrc_coef_q14 = 16'sd31;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd23: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd20;
                            4'd1: rrc_coef_q14 = -16'sd40;
                            4'd2: rrc_coef_q14 = -16'sd135;
                            4'd3: rrc_coef_q14 = 16'sd1175;
                            4'd4: rrc_coef_q14 = 16'sd1505;
                            4'd5: rrc_coef_q14 = -16'sd212;
                            4'd6: rrc_coef_q14 = -16'sd27;
                            4'd7: rrc_coef_q14 = 16'sd29;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd24: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd22;
                            4'd1: rrc_coef_q14 = -16'sd38;
                            4'd2: rrc_coef_q14 = -16'sd154;
                            4'd3: rrc_coef_q14 = 16'sd1258;
                            4'd4: rrc_coef_q14 = 16'sd1423;
                            4'd5: rrc_coef_q14 = -16'sd193;
                            4'd6: rrc_coef_q14 = -16'sd31;
                            4'd7: rrc_coef_q14 = 16'sd27;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd25: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd25;
                            4'd1: rrc_coef_q14 = -16'sd35;
                            4'd2: rrc_coef_q14 = -16'sd174;
                            4'd3: rrc_coef_q14 = 16'sd1341;
                            4'd4: rrc_coef_q14 = 16'sd1341;
                            4'd5: rrc_coef_q14 = -16'sd174;
                            4'd6: rrc_coef_q14 = -16'sd35;
                            4'd7: rrc_coef_q14 = 16'sd25;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd26: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd27;
                            4'd1: rrc_coef_q14 = -16'sd31;
                            4'd2: rrc_coef_q14 = -16'sd193;
                            4'd3: rrc_coef_q14 = 16'sd1423;
                            4'd4: rrc_coef_q14 = 16'sd1258;
                            4'd5: rrc_coef_q14 = -16'sd154;
                            4'd6: rrc_coef_q14 = -16'sd38;
                            4'd7: rrc_coef_q14 = 16'sd22;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd27: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd29;
                            4'd1: rrc_coef_q14 = -16'sd27;
                            4'd2: rrc_coef_q14 = -16'sd212;
                            4'd3: rrc_coef_q14 = 16'sd1505;
                            4'd4: rrc_coef_q14 = 16'sd1175;
                            4'd5: rrc_coef_q14 = -16'sd135;
                            4'd6: rrc_coef_q14 = -16'sd40;
                            4'd7: rrc_coef_q14 = 16'sd20;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd28: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd31;
                            4'd1: rrc_coef_q14 = -16'sd23;
                            4'd2: rrc_coef_q14 = -16'sd231;
                            4'd3: rrc_coef_q14 = 16'sd1586;
                            4'd4: rrc_coef_q14 = 16'sd1092;
                            4'd5: rrc_coef_q14 = -16'sd116;
                            4'd6: rrc_coef_q14 = -16'sd42;
                            4'd7: rrc_coef_q14 = 16'sd17;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd29: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd33;
                            4'd1: rrc_coef_q14 = -16'sd18;
                            4'd2: rrc_coef_q14 = -16'sd250;
                            4'd3: rrc_coef_q14 = 16'sd1666;
                            4'd4: rrc_coef_q14 = 16'sd1010;
                            4'd5: rrc_coef_q14 = -16'sd97;
                            4'd6: rrc_coef_q14 = -16'sd44;
                            4'd7: rrc_coef_q14 = 16'sd14;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd30: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd35;
                            4'd1: rrc_coef_q14 = -16'sd12;
                            4'd2: rrc_coef_q14 = -16'sd267;
                            4'd3: rrc_coef_q14 = 16'sd1744;
                            4'd4: rrc_coef_q14 = 16'sd928;
                            4'd5: rrc_coef_q14 = -16'sd79;
                            4'd6: rrc_coef_q14 = -16'sd45;
                            4'd7: rrc_coef_q14 = 16'sd11;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd31: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd36;
                            4'd1: rrc_coef_q14 = -16'sd7;
                            4'd2: rrc_coef_q14 = -16'sd284;
                            4'd3: rrc_coef_q14 = 16'sd1821;
                            4'd4: rrc_coef_q14 = 16'sd848;
                            4'd5: rrc_coef_q14 = -16'sd61;
                            4'd6: rrc_coef_q14 = -16'sd46;
                            4'd7: rrc_coef_q14 = 16'sd8;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd32: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd37;
                            4'd1: rrc_coef_q14 = -16'sd1;
                            4'd2: rrc_coef_q14 = -16'sd300;
                            4'd3: rrc_coef_q14 = 16'sd1896;
                            4'd4: rrc_coef_q14 = 16'sd768;
                            4'd5: rrc_coef_q14 = -16'sd44;
                            4'd6: rrc_coef_q14 = -16'sd46;
                            4'd7: rrc_coef_q14 = 16'sd6;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd33: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd38;
                            4'd1: rrc_coef_q14 = 16'sd5;
                            4'd2: rrc_coef_q14 = -16'sd315;
                            4'd3: rrc_coef_q14 = 16'sd1968;
                            4'd4: rrc_coef_q14 = 16'sd690;
                            4'd5: rrc_coef_q14 = -16'sd27;
                            4'd6: rrc_coef_q14 = -16'sd45;
                            4'd7: rrc_coef_q14 = 16'sd3;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd34: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd39;
                            4'd1: rrc_coef_q14 = 16'sd12;
                            4'd2: rrc_coef_q14 = -16'sd329;
                            4'd3: rrc_coef_q14 = 16'sd2038;
                            4'd4: rrc_coef_q14 = 16'sd614;
                            4'd5: rrc_coef_q14 = -16'sd12;
                            4'd6: rrc_coef_q14 = -16'sd44;
                            4'd7: rrc_coef_q14 = 16'sd0;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd35: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd39;
                            4'd1: rrc_coef_q14 = 16'sd19;
                            4'd2: rrc_coef_q14 = -16'sd341;
                            4'd3: rrc_coef_q14 = 16'sd2105;
                            4'd4: rrc_coef_q14 = 16'sd540;
                            4'd5: rrc_coef_q14 = 16'sd3;
                            4'd6: rrc_coef_q14 = -16'sd43;
                            4'd7: rrc_coef_q14 = -16'sd3;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd36: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd39;
                            4'd1: rrc_coef_q14 = 16'sd25;
                            4'd2: rrc_coef_q14 = -16'sd351;
                            4'd3: rrc_coef_q14 = 16'sd2169;
                            4'd4: rrc_coef_q14 = 16'sd467;
                            4'd5: rrc_coef_q14 = 16'sd17;
                            4'd6: rrc_coef_q14 = -16'sd41;
                            4'd7: rrc_coef_q14 = -16'sd5;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd37: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd38;
                            4'd1: rrc_coef_q14 = 16'sd32;
                            4'd2: rrc_coef_q14 = -16'sd360;
                            4'd3: rrc_coef_q14 = 16'sd2229;
                            4'd4: rrc_coef_q14 = 16'sd398;
                            4'd5: rrc_coef_q14 = 16'sd30;
                            4'd6: rrc_coef_q14 = -16'sd39;
                            4'd7: rrc_coef_q14 = -16'sd8;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd38: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd38;
                            4'd1: rrc_coef_q14 = 16'sd39;
                            4'd2: rrc_coef_q14 = -16'sd367;
                            4'd3: rrc_coef_q14 = 16'sd2286;
                            4'd4: rrc_coef_q14 = 16'sd330;
                            4'd5: rrc_coef_q14 = 16'sd42;
                            4'd6: rrc_coef_q14 = -16'sd37;
                            4'd7: rrc_coef_q14 = -16'sd10;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd39: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd37;
                            4'd1: rrc_coef_q14 = 16'sd46;
                            4'd2: rrc_coef_q14 = -16'sd371;
                            4'd3: rrc_coef_q14 = 16'sd2340;
                            4'd4: rrc_coef_q14 = 16'sd265;
                            4'd5: rrc_coef_q14 = 16'sd52;
                            4'd6: rrc_coef_q14 = -16'sd34;
                            4'd7: rrc_coef_q14 = -16'sd12;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd40: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd35;
                            4'd1: rrc_coef_q14 = 16'sd53;
                            4'd2: rrc_coef_q14 = -16'sd374;
                            4'd3: rrc_coef_q14 = 16'sd2389;
                            4'd4: rrc_coef_q14 = 16'sd203;
                            4'd5: rrc_coef_q14 = 16'sd62;
                            4'd6: rrc_coef_q14 = -16'sd31;
                            4'd7: rrc_coef_q14 = -16'sd14;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd41: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd34;
                            4'd1: rrc_coef_q14 = 16'sd59;
                            4'd2: rrc_coef_q14 = -16'sd374;
                            4'd3: rrc_coef_q14 = 16'sd2434;
                            4'd4: rrc_coef_q14 = 16'sd144;
                            4'd5: rrc_coef_q14 = 16'sd70;
                            4'd6: rrc_coef_q14 = -16'sd28;
                            4'd7: rrc_coef_q14 = -16'sd16;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd42: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd32;
                            4'd1: rrc_coef_q14 = 16'sd66;
                            4'd2: rrc_coef_q14 = -16'sd371;
                            4'd3: rrc_coef_q14 = 16'sd2475;
                            4'd4: rrc_coef_q14 = 16'sd87;
                            4'd5: rrc_coef_q14 = 16'sd78;
                            4'd6: rrc_coef_q14 = -16'sd24;
                            4'd7: rrc_coef_q14 = -16'sd18;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd43: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd29;
                            4'd1: rrc_coef_q14 = 16'sd72;
                            4'd2: rrc_coef_q14 = -16'sd366;
                            4'd3: rrc_coef_q14 = 16'sd2512;
                            4'd4: rrc_coef_q14 = 16'sd34;
                            4'd5: rrc_coef_q14 = 16'sd84;
                            4'd6: rrc_coef_q14 = -16'sd21;
                            4'd7: rrc_coef_q14 = -16'sd19;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd44: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd27;
                            4'd1: rrc_coef_q14 = 16'sd77;
                            4'd2: rrc_coef_q14 = -16'sd358;
                            4'd3: rrc_coef_q14 = 16'sd2544;
                            4'd4: rrc_coef_q14 = -16'sd16;
                            4'd5: rrc_coef_q14 = 16'sd89;
                            4'd6: rrc_coef_q14 = -16'sd17;
                            4'd7: rrc_coef_q14 = -16'sd20;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd45: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd24;
                            4'd1: rrc_coef_q14 = 16'sd82;
                            4'd2: rrc_coef_q14 = -16'sd347;
                            4'd3: rrc_coef_q14 = 16'sd2571;
                            4'd4: rrc_coef_q14 = -16'sd62;
                            4'd5: rrc_coef_q14 = 16'sd93;
                            4'd6: rrc_coef_q14 = -16'sd13;
                            4'd7: rrc_coef_q14 = -16'sd21;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd46: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd21;
                            4'd1: rrc_coef_q14 = 16'sd87;
                            4'd2: rrc_coef_q14 = -16'sd333;
                            4'd3: rrc_coef_q14 = 16'sd2594;
                            4'd4: rrc_coef_q14 = -16'sd106;
                            4'd5: rrc_coef_q14 = 16'sd96;
                            4'd6: rrc_coef_q14 = -16'sd9;
                            4'd7: rrc_coef_q14 = -16'sd22;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd47: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd18;
                            4'd1: rrc_coef_q14 = 16'sd91;
                            4'd2: rrc_coef_q14 = -16'sd316;
                            4'd3: rrc_coef_q14 = 16'sd2611;
                            4'd4: rrc_coef_q14 = -16'sd146;
                            4'd5: rrc_coef_q14 = 16'sd98;
                            4'd6: rrc_coef_q14 = -16'sd5;
                            4'd7: rrc_coef_q14 = -16'sd23;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd48: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd14;
                            4'd1: rrc_coef_q14 = 16'sd94;
                            4'd2: rrc_coef_q14 = -16'sd296;
                            4'd3: rrc_coef_q14 = 16'sd2624;
                            4'd4: rrc_coef_q14 = -16'sd183;
                            4'd5: rrc_coef_q14 = 16'sd99;
                            4'd6: rrc_coef_q14 = -16'sd1;
                            4'd7: rrc_coef_q14 = -16'sd23;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    6'd49: begin
                        case (tap)
                            4'd0: rrc_coef_q14 = 16'sd11;
                            4'd1: rrc_coef_q14 = 16'sd97;
                            4'd2: rrc_coef_q14 = -16'sd273;
                            4'd3: rrc_coef_q14 = 16'sd2631;
                            4'd4: rrc_coef_q14 = -16'sd216;
                            4'd5: rrc_coef_q14 = 16'sd99;
                            4'd6: rrc_coef_q14 = 16'sd3;
                            4'd7: rrc_coef_q14 = -16'sd23;
                            4'd8: rrc_coef_q14 = 16'sd0;
                            default: rrc_coef_q14 = 16'sd0;
                        endcase
                    end
                    default: rrc_coef_q14 = 16'sd0;
                endcase
            end
            default: begin
                rrc_coef_q14 = 16'sd0;
            end
        endcase
    end
endfunction

function signed [W-1:0] round_shift_q14;
    input signed [ACC_W-1:0] x;
    reg signed [ACC_W-1:0] xr;
    begin
        if (x >= 0) begin
            xr = x + ({{(ACC_W-COEF_Q){1'b0}}, 1'b1, {(COEF_Q-1){1'b0}}});
        end else begin
            xr = x - ({{(ACC_W-COEF_Q){1'b0}}, 1'b1, {(COEF_Q-1){1'b0}}});
        end
        round_shift_q14 = xr >>> COEF_Q;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        phase_idx <= 6'd0;
        m_i       <= {W{1'b0}};
        m_q       <= {W{1'b0}};
        m_valid   <= 1'b0;
        s1_valid  <= 1'b0;
        s2_valid  <= 1'b0;
        for (n = 0; n < SYM_TAPS; n = n + 1) begin
            hist_i[n] <= {W{1'b0}};
            hist_q[n] <= {W{1'b0}};
        end
    end else begin
        // stage3: 最终求和 + 四舍五入 + 输出寄存
        if (s3_accept) begin
            if (s2_valid) begin
                m_i <= round_shift_q14((s2_l2_i[0] + s2_l2_i[1]) + s2_l2_i[2]);
                m_q <= round_shift_q14((s2_l2_q[0] + s2_l2_q[1]) + s2_l2_q[2]);
                m_valid <= 1'b1;
            end else begin
                m_valid <= 1'b0;
            end
        end

        // stage2: 加法树中间级寄存
        if (s2_accept) begin
            if (s1_valid) begin
                s2_l2_i[0] <= (s1_prod_i[0] + s1_prod_i[1]) + (s1_prod_i[2] + s1_prod_i[3]);
                s2_l2_i[1] <= (s1_prod_i[4] + s1_prod_i[5]) + (s1_prod_i[6] + s1_prod_i[7]);
                s2_l2_i[2] <= s1_prod_i[8];

                s2_l2_q[0] <= (s1_prod_q[0] + s1_prod_q[1]) + (s1_prod_q[2] + s1_prod_q[3]);
                s2_l2_q[1] <= (s1_prod_q[4] + s1_prod_q[5]) + (s1_prod_q[6] + s1_prod_q[7]);
                s2_l2_q[2] <= s1_prod_q[8];
                s2_valid <= 1'b1;
            end else begin
                s2_valid <= 1'b0;
            end
        end

        // stage1: 系数查找 + 9 路乘法寄存
        if (s1_accept) begin
            if (launch_sample) begin
                for (k = 0; k < SYM_TAPS; k = k + 1) begin
                    coef_k = rrc_coef_q14(beta_sel, phase_idx, k[3:0]);
                    if (need_symbol) begin
                        if (k == 0) begin
                            sym_i_k = s_i;
                            sym_q_k = s_q;
                        end else begin
                            sym_i_k = hist_i[k-1];
                            sym_q_k = hist_q[k-1];
                        end
                    end else begin
                        sym_i_k = hist_i[k];
                        sym_q_k = hist_q[k];
                    end
                    s1_prod_i[k] <= $signed(sym_i_k) * $signed(coef_k);
                    s1_prod_q[k] <= $signed(sym_q_k) * $signed(coef_k);
                end
                s1_valid <= 1'b1;
            end else begin
                s1_valid <= 1'b0;
            end
        end

        // 仅在成功发起一个新样本计算时推进相位/历史符号
        if (launch_sample) begin
            if (phase_idx == 6'd49) begin
                phase_idx <= 6'd0;
            end else begin
                phase_idx <= phase_idx + 6'd1;
            end
            if (need_symbol) begin
                for (n = SYM_TAPS-1; n > 0; n = n - 1) begin
                    hist_i[n] <= hist_i[n-1];
                    hist_q[n] <= hist_q[n-1];
                end
                hist_i[0] <= s_i;
                hist_q[0] <= s_q;
            end
        end
    end
end

endmodule
