// -----------------------------------------------------------------------------
// 模块: qpsk_test_gen
// 功能: 生成 QPSK 2bit 符号流，供 TX 调制链和 RX loopback 仿真使用
// 模式:
//   0: Gray 顺序循环 00->01->11->10
//   1: PRBS(7-bit LFSR) 输出低2位
//   2: 帧模式(前8符号训练序列 + 后24符号PRBS)
//   3: 常量 cfg_sym
// -----------------------------------------------------------------------------
module qpsk_test_gen (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,
    input  wire [1:0] mode_sel,
    input  wire [1:0] cfg_sym,
    output reg  [1:0] m_sym,
    output reg        m_valid,
    input  wire       m_ready
);

localparam [1:0] MODE_GRAY  = 2'd0;
localparam [1:0] MODE_PRBS  = 2'd1;
localparam [1:0] MODE_FRAME = 2'd2;
localparam [1:0] MODE_CONST = 2'd3;

localparam integer TRAIN_LEN = 8;
localparam integer FRAME_LEN = 32;

reg [1:0] seq_idx;
reg [6:0] lfsr;
reg [4:0] frame_pos;
// seq_idx: Gray循环索引
// lfsr: PRBS状态
// frame_pos: 帧内符号位置（用于训练段/数据段切换）

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

function [6:0] lfsr7_next;
    input [6:0] cur;
    begin
        // PRBS7: x^7 + x^6 + 1（按当前实现的移位方向）
        lfsr7_next = {cur[5:0], cur[6] ^ cur[5]};
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        seq_idx   <= 2'd0;
        lfsr      <= 7'h5D;
        frame_pos <= 5'd0;
        m_sym     <= 2'b00;
        m_valid   <= 1'b0;
    end else begin
        // en=1 时持续宣告符号有效；真正前进一步仍需 m_ready=1
        m_valid <= en;
        if (en && m_ready) begin
            case (mode_sel)
                MODE_GRAY: begin
                    // 固定 Gray 序列循环: 00->01->11->10
                    m_sym <= gray_seq4(seq_idx);
                    seq_idx <= seq_idx + 2'd1;
                    frame_pos <= 5'd0;
                end

                MODE_PRBS: begin
                    // 直接输出 PRBS 低2位，每次握手推进一次 LFSR
                    m_sym <= lfsr[1:0];
                    lfsr <= lfsr7_next(lfsr);
                    seq_idx <= seq_idx + 2'd1;
                    frame_pos <= 5'd0;
                end

                MODE_FRAME: begin
                    // 帧模式: 前 TRAIN_LEN 个符号使用固定训练序列，之后使用 PRBS
                    if (frame_pos < TRAIN_LEN) begin
                        m_sym <= gray_seq4(frame_pos[1:0]);
                    end else begin
                        m_sym <= lfsr[1:0];
                        lfsr <= lfsr7_next(lfsr);
                    end

                    if (frame_pos == (FRAME_LEN - 1)) begin
                        frame_pos <= 5'd0;
                    end else begin
                        frame_pos <= frame_pos + 5'd1;
                    end
                    seq_idx <= seq_idx + 2'd1;
                end

                MODE_CONST: begin
                    // 输出固定符号，便于单点联调
                    m_sym <= cfg_sym;
                    seq_idx <= seq_idx + 2'd1;
                    frame_pos <= 5'd0;
                end

                default: begin
                    // 兜底分支，避免非法模式导致状态不可预期
                    m_sym <= 2'b00;
                    seq_idx <= 2'd0;
                    frame_pos <= 5'd0;
                end
            endcase
        end else if (!en) begin
            // 关闭发生器时将帧位置归零，便于下次从帧头开始
            frame_pos <= 5'd0;
        end
    end
end

endmodule
