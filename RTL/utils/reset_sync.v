// -----------------------------------------------------------------------------
// 模块: reset_sync
// 功能: 低有效复位同步器（异步拉低、同步释放）
// 用途: 为每个时钟域生成本域可安全使用的 rst_n 信号
// -----------------------------------------------------------------------------
module reset_sync #(
    parameter integer STAGES = 2
) (
    // 目标时钟域
    input  wire clk,
    // 全局低有效复位输入（可异步）
    input  wire rst_n_in,
    // 本时钟域同步后的低有效复位输出
    output wire rst_n_out
);

localparam integer STAGES_SAFE = (STAGES < 2) ? 2 : STAGES;
reg [STAGES_SAFE-1:0] sync_ff;

always @(posedge clk or negedge rst_n_in) begin
    if (!rst_n_in) begin
        // 异步断言：立即清零同步寄存器
        sync_ff <= {STAGES_SAFE{1'b0}};
    end else begin
        // 同步释放：打拍移位到全 1 后输出 rst_n_out=1
        sync_ff <= {sync_ff[STAGES_SAFE-2:0], 1'b1};
    end
end

assign rst_n_out = sync_ff[STAGES_SAFE-1];

endmodule
