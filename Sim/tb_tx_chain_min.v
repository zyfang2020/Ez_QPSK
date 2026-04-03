`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_tx_chain_min
// 目的:
// 1) 验证 tx_test_pattern + ad9762_driver 最小发送链路
// 2) 检查 const/ramp/square/sine 四种模式是否工作
// -----------------------------------------------------------------------------
module tb_tx_chain_min;

localparam integer DW = 12;
// 方波由 ramp_cnt 的最高位产生，需要观察超过 2^(DW-1) 拍才能看到翻转
localparam integer SQUARE_OBS_CYCLES = (1 << (DW-1)) + 64;

reg                 clk;
reg                 rst_n;
reg                 tx_en;
reg  [1:0]          mode_sel;
reg  [DW-1:0]       cfg_const;
wire [DW-1:0]       tx_data;
wire                tx_valid;
wire                tx_ready;
wire [DW-1:0]       dac_data;

integer             i;
reg [DW-1:0]        prev_data;
reg                 square_seen_hi;
reg                 square_seen_lo;
reg                 sine_changed;

// 100MHz 时钟
initial clk = 1'b0;
always #5 clk = ~clk;

task tb_fail;
    input [255:0] msg;
    begin
        $display("[TB_TX][FAIL] %0t ns: %0s", $time, msg);
        $finish;
    end
endtask

tx_test_pattern #(
    .DW(DW)
) u_tx_test_pattern (
    .clk(clk),
    .rst_n(rst_n),
    .en(tx_en),
    .mode_sel(mode_sel),
    .cfg_const(cfg_const),
    .m_data(tx_data),
    .m_valid(tx_valid),
    .m_ready(tx_ready)
);

ad9762_driver #(
    .DW(DW),
    .HOLD_LAST(1)
) u_ad9762_driver (
    .clk_dac(clk),
    .rst_n(rst_n),
    .s_data(tx_data),
    .s_valid(tx_valid),
    .s_ready(tx_ready),
    .dac_data(dac_data)
);

initial begin
    rst_n         = 1'b0;
    tx_en         = 1'b0;
    mode_sel      = 2'd0;
    cfg_const     = 12'h456;
    prev_data     = {DW{1'b0}};
    square_seen_hi = 1'b0;
    square_seen_lo = 1'b0;
    sine_changed   = 1'b0;

    // 上电复位
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    tx_en = 1'b1;

    // 模式0: 常数输出
    mode_sel = 2'd0;
    repeat (4) @(posedge clk); // 等待管线稳定
    for (i = 0; i < SQUARE_OBS_CYCLES; i = i + 1) begin
        @(posedge clk);
        if (dac_data !== cfg_const) begin
            tb_fail("const 模式输出不等于 cfg_const");
        end
    end

    // 模式1: ramp，检查相邻样本 +1
    mode_sel = 2'd1;
    repeat (3) @(posedge clk);
    prev_data = dac_data;
    for (i = 0; i < SQUARE_OBS_CYCLES; i = i + 1) begin
        @(posedge clk);
        if (dac_data !== (prev_data + 1'b1)) begin
            tb_fail("ramp 模式相邻样本没有按 +1 递增");
        end
        prev_data = dac_data;
    end

    // 模式2: 方波，检查是否同时出现全0和全1
    mode_sel = 2'd2;
    repeat (2) @(posedge clk);
    for (i = 0; i < SQUARE_OBS_CYCLES; i = i + 1) begin
        @(posedge clk);
        if (dac_data == {DW{1'b1}}) square_seen_hi = 1'b1;
        if (dac_data == {DW{1'b0}}) square_seen_lo = 1'b1;
    end
    if (!(square_seen_hi && square_seen_lo)) begin
        tb_fail("square 模式未观察到高/低两个电平");
    end

    // 模式3: 正弦LUT，检查输出是否发生变化
    mode_sel = 2'd3;
    repeat (2) @(posedge clk);
    prev_data = dac_data;
    for (i = 0; i < SQUARE_OBS_CYCLES; i = i + 1) begin
        @(posedge clk);
        if (dac_data !== prev_data) sine_changed = 1'b1;
        prev_data = dac_data;
    end
    if (!sine_changed) begin
        tb_fail("sine 模式输出没有变化");
    end

    $display("[TB_TX][PASS] %0t ns: TX 最小链路检查通过", $time);
    $finish;
end

endmodule
