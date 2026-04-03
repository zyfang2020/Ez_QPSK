// -----------------------------------------------------------------------------
// 模块: signed_to_offset_dac
// 功能: 将有符号样本转换为 DAC 所需 offset-binary 无符号输出
// 流程:
//   1) 饱和到 DAC 可表示范围
//   2) 加中点偏置 2^(DAC_DW-1)
// -----------------------------------------------------------------------------
module signed_to_offset_dac #(
    parameter integer IN_W = 18,
    parameter integer DAC_DW = 12
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire signed [IN_W-1:0]        s_data,
    input  wire                          s_valid,
    output wire                          s_ready,
    output reg  [DAC_DW-1:0]             m_data,
    output reg                           m_valid,
    input  wire                          m_ready
);

localparam signed [DAC_DW-1:0] DAC_MAX = {1'b0, {(DAC_DW-1){1'b1}}};
localparam signed [DAC_DW-1:0] DAC_MIN = {1'b1, {(DAC_DW-1){1'b0}}};
localparam [DAC_DW-1:0] DAC_OFFSET = {1'b1, {(DAC_DW-1){1'b0}}};

assign s_ready = (!m_valid) || m_ready;

function [DAC_DW-1:0] to_offset_binary;
    input signed [IN_W-1:0] din;
    reg signed [DAC_DW-1:0] sat;
    begin
        if (din > $signed(DAC_MAX)) begin
            sat = DAC_MAX;
        end else if (din < $signed(DAC_MIN)) begin
            sat = DAC_MIN;
        end else begin
            sat = din[DAC_DW-1:0];
        end
        // two's complement -> offset-binary: 翻转符号位
        to_offset_binary = sat ^ DAC_OFFSET;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        m_data  <= {DAC_DW{1'b0}};
        m_valid <= 1'b0;
    end else begin
        if (s_valid && s_ready) begin
            m_data  <= to_offset_binary(s_data);
            m_valid <= 1'b1;
        end else if (m_ready) begin
            m_valid <= 1'b0;
        end
    end
end

endmodule
