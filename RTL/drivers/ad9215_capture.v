// -----------------------------------------------------------------------------
// 模块: ad9215_capture
// 功能: AD9215 并口采样适配为统一流接口
// 说明: ADC 是不可回压源，每个 clk_adc 周期都产生样本
// -----------------------------------------------------------------------------
module ad9215_capture #(
    parameter integer ADC_DW = 10,
    parameter integer OUT_DW = 16,
    parameter integer SAMPLE_NEGEDGE = 0
) (
    // ADC 采样时钟域
    input  wire                clk_adc,
    // 低有效复位
    input  wire                rst_n,
    // ADC 原始并口数据
    input  wire [ADC_DW-1:0]   adc_data,
    // 输出流（统一到 OUT_DW 容器宽度）
    output reg  [OUT_DW-1:0]   m_data,
    output reg                 m_valid,
    input  wire                m_ready
);

wire unused_m_ready;
assign unused_m_ready = m_ready;

generate
    if (SAMPLE_NEGEDGE != 0) begin : g_sample_negedge
        // 当 ADC 由 FPGA 输出时钟驱动时，可在相反边沿采样，
        // 以获得半个周期的建立/保持窗口。
        always @(negedge clk_adc or negedge rst_n) begin
            if (!rst_n) begin
                m_data <= {OUT_DW{1'b0}};
                m_valid <= 1'b0;
            end else begin
                // AD9215 不支持回压：每拍采样，直接送出
                m_data <= {{(OUT_DW-ADC_DW){1'b0}}, adc_data};
                m_valid <= 1'b1;
            end
        end
    end else begin : g_sample_posedge
        always @(posedge clk_adc or negedge rst_n) begin
            if (!rst_n) begin
                m_data <= {OUT_DW{1'b0}};
                m_valid <= 1'b0;
            end else begin
                // AD9215 不支持回压：每拍采样，直接送出
                m_data <= {{(OUT_DW-ADC_DW){1'b0}}, adc_data};
                m_valid <= 1'b1;
            end
        end
    end
endgenerate

endmodule
