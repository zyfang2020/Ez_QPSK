// -----------------------------------------------------------------------------
// 模块: stream_pkt_gen
// 功能: 连续流按固定长度 PKT_LEN 打包，并在包尾拉高 m_last
// 说明: 适配 AXI DMA 对分包传输的使用习惯
// -----------------------------------------------------------------------------
module stream_pkt_gen #(
    parameter integer DW = 16,
    parameter integer PKT_LEN = 100000
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [DW-1:0] s_data,
    input  wire          s_valid,
    output wire          s_ready,
    output reg  [DW-1:0] m_data,
    output reg           m_valid,
    input  wire          m_ready,
    output reg           m_last
);

localparam integer CNT_W = (PKT_LEN <= 2) ? 1 : $clog2(PKT_LEN);
reg [CNT_W-1:0] beat_cnt;
wire out_fire;
wire in_fire;
wire last_this_beat;

assign s_ready = (~m_valid) | m_ready;
// 输出侧完成一次握手
assign out_fire = m_valid & m_ready;
// 输入侧完成一次握手
assign in_fire = s_valid & s_ready;
assign last_this_beat = (beat_cnt == PKT_LEN-1);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        beat_cnt <= {CNT_W{1'b0}};
        m_data <= {DW{1'b0}};
        m_valid <= 1'b0;
        m_last <= 1'b0;
    end else begin
        if (in_fire) begin
            m_data <= s_data;
            m_valid <= 1'b1;
            // 当前拍是否为该包最后一个采样
            m_last <= last_this_beat;
            if (last_this_beat) begin
                beat_cnt <= {CNT_W{1'b0}};
            end else begin
                beat_cnt <= beat_cnt + 1'b1;
            end
        end else if (out_fire) begin
            m_valid <= 1'b0;
            m_last <= 1'b0;
        end
    end
end

endmodule
