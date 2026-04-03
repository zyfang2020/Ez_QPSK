// -----------------------------------------------------------------------------
// 模块: qpsk_symbol_mapper
// 功能: QPSK 符号映射器（2bit -> 并行 I/Q 有符号符号值）
// 映射(Gray):
//   2'b00 -> I=+A, Q=+A
//   2'b01 -> I=-A, Q=+A
//   2'b11 -> I=-A, Q=-A
//   2'b10 -> I=+A, Q=-A
// 说明:
//   - 输出为有符号值，后续可直接进入成型滤波与上变频
//   - 采用标准 valid/ready 握手
// -----------------------------------------------------------------------------
module qpsk_symbol_mapper #(
    parameter integer SYM_W = 12,
    parameter signed [SYM_W-1:0] SYM_AMP = (1 << (SYM_W-2))
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire [1:0]                 s_sym,
    input  wire                       s_valid,
    output wire                       s_ready,
    output reg  signed [SYM_W-1:0]    m_i,
    output reg  signed [SYM_W-1:0]    m_q,
    output reg                        m_valid,
    input  wire                       m_ready
);

localparam signed [SYM_W-1:0] LEVEL_POS = SYM_AMP;
localparam signed [SYM_W-1:0] LEVEL_NEG = -SYM_AMP;

assign s_ready = (!m_valid) || m_ready;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        m_i     <= {SYM_W{1'b0}};
        m_q     <= {SYM_W{1'b0}};
        m_valid <= 1'b0;
    end else begin
        if (s_valid && s_ready) begin
            m_i <= s_sym[0] ? LEVEL_NEG : LEVEL_POS;
            m_q <= s_sym[1] ? LEVEL_NEG : LEVEL_POS;
            m_valid <= 1'b1;
        end else if (m_ready) begin
            m_valid <= 1'b0;
        end
    end
end

endmodule

