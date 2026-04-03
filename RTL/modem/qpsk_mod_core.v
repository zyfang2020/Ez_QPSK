// -----------------------------------------------------------------------------
// 模块: qpsk_mod_core
// 功能: 将 2bit 符号流映射为 QPSK 基带采样流（I/Q 交织输出到单路 DAC）
// 说明:
//   - 本模块保留为“最小联调/教学用 legacy 路径”
//   - 实际单DAC发射链请优先使用 qpsk_tx_single_dac
// 映射(Gray):
//   2'b00 -> I=+A, Q=+A
//   2'b01 -> I=-A, Q=+A
//   2'b11 -> I=-A, Q=-A
//   2'b10 -> I=+A, Q=-A
// 输出格式:
//   m_data 采用 offset-binary，按 I 后 Q 的顺序输出
// -----------------------------------------------------------------------------
module qpsk_mod_core #(
    parameter integer DW = 12,
    parameter [DW-1:0] OFFSET = (1 << (DW-1)),
    parameter [DW-1:0] AMP    = (1 << (DW-2))
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [1:0]    s_sym,
    input  wire          s_valid,
    output wire          s_ready,
    output reg  [DW-1:0] m_data,
    output reg           m_valid,
    input  wire          m_ready
);

localparam [1:0] ST_IDLE   = 2'd0;
localparam [1:0] ST_SEND_I = 2'd1;
localparam [1:0] ST_SEND_Q = 2'd2;

// 状态机: IDLE 等符号, SEND_I 发送I, SEND_Q 发送Q
reg [1:0] state;
// 锁存当前正在发送的符号，保证I/Q来自同一个符号
reg [1:0] sym_hold;

wire [DW-1:0] level_pos;
wire [DW-1:0] level_neg;
wire [DW-1:0] i_from_in;
wire [DW-1:0] q_from_hold;

assign level_pos = OFFSET + AMP;
assign level_neg = OFFSET - AMP;

// 输入符号最低位控制 I 分量正负，最高位控制 Q 分量正负
assign i_from_in   = s_sym[0]    ? level_neg : level_pos;
assign q_from_hold = sym_hold[1] ? level_neg : level_pos;

// 仅在空闲态接收上游新符号，避免覆盖未发送完成的符号
assign s_ready = (state == ST_IDLE);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= ST_IDLE;
        sym_hold   <= 2'b00;
        m_data     <= {DW{1'b0}};
        m_valid    <= 1'b0;
    end else begin
        case (state)
            ST_IDLE: begin
                // 空闲时默认不对下游宣告有效数据
                m_valid <= 1'b0;
                if (s_valid) begin
                    // 接收新符号，先发送 I 分量
                    sym_hold   <= s_sym;
                    m_data     <= i_from_in;
                    m_valid    <= 1'b1;
                    state      <= ST_SEND_I;
                end
            end

            ST_SEND_I: begin
                // I 拍在 valid/ready 握手成功后，切换到发送 Q 分量
                // 若下游回压(m_ready=0)，保持当前 m_data/m_valid 不变
                if (m_valid && m_ready) begin
                    m_data  <= q_from_hold;
                    m_valid <= 1'b1;
                    state   <= ST_SEND_Q;
                end
            end

            ST_SEND_Q: begin
                // Q 拍握手成功后，本符号发送完成，返回空闲
                // 返回 IDLE 后下一拍才能再次接收新符号
                if (m_valid && m_ready) begin
                    m_valid <= 1'b0;
                    state   <= ST_IDLE;
                end
            end

            default: begin
                state   <= ST_IDLE;
                m_valid <= 1'b0;
                m_data  <= {DW{1'b0}};
            end
        endcase
    end
end

endmodule
