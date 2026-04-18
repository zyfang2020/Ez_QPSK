// -----------------------------------------------------------------------------
// 模块: ad9762_driver
// 功能: 将流接口数据直接送到 AD9762 DAC 数据口
// 说明: DAC 端默认每拍可接收，因此 s_ready 常为 1
// -----------------------------------------------------------------------------
module ad9762_driver #(
    parameter integer DW = 12,
    parameter integer HOLD_LAST = 0,
    parameter integer UPDATE_NEGEDGE = 1
) (
    // DAC 时钟域
    input  wire          clk_dac,
    // 低有效复位
    input  wire          rst_n,
    // 输入流
    input  wire [DW-1:0] s_data,
    input  wire          s_valid,
    output wire          s_ready,
    // DAC 并口输出
    output reg  [DW-1:0] dac_data
);

assign s_ready = 1'b1;

generate
    if (UPDATE_NEGEDGE != 0) begin : g_update_negedge
        // AD9762 在时钟上升沿锁存输入数据，驱动侧放在下降沿更新，
        // 可以为板级走线和器件建立时间留出半个周期裕量。
        always @(negedge clk_dac or negedge rst_n) begin
            if (!rst_n) begin
                dac_data <= {DW{1'b0}};
            end else begin
                if (s_valid) begin
                    dac_data <= s_data;
                end else if (HOLD_LAST == 0) begin
                    // 无有效输入且不保持时，回零
                    dac_data <= {DW{1'b0}};
                end
            end
        end
    end else begin : g_update_posedge
        always @(posedge clk_dac or negedge rst_n) begin
            if (!rst_n) begin
                dac_data <= {DW{1'b0}};
            end else begin
                if (s_valid) begin
                    dac_data <= s_data;
                end else if (HOLD_LAST == 0) begin
                    // 无有效输入且不保持时，回零
                    dac_data <= {DW{1'b0}};
                end
            end
        end
    end
endgenerate

endmodule
