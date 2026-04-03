`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_rx_chain_min
// 目的:
// 1) 验证 ad9215_capture -> stream_async_fifo -> stream_pkt_gen -> axis_to_dma_pkt
// 2) 检查数据连续性（低10位递增）和固定分包 tlast 周期
// 说明: 默认用于 Vivado xsim 波形联调
// -----------------------------------------------------------------------------
module tb_rx_chain_min;

localparam integer ADC_DW      = 10;
localparam integer RX_DW       = 16;
localparam integer FIFO_DEPTH  = 128;
localparam integer PKT_LEN     = 32;
localparam integer TARGET_BEAT = 400;

reg                   clk_adc;
reg                   clk_axi;
reg                   rst_n;
reg  [ADC_DW-1:0]     adc_data;
wire [RX_DW-1:0]      cap_data;
wire                  cap_valid;
wire                  cap_ready;
wire [RX_DW-1:0]      fifo_data;
wire                  fifo_valid;
wire                  fifo_ready;
wire [RX_DW-1:0]      pkt_data;
wire                  pkt_valid;
wire                  pkt_ready;
wire                  pkt_last;
wire [RX_DW-1:0]      m_axis_tdata;
wire [((RX_DW+7)/8)-1:0] m_axis_tkeep;
wire                  m_axis_tvalid;
reg                   m_axis_tready;
wire                  m_axis_tlast;

integer               axi_cycle_cnt;
integer               recv_cnt;
integer               beat_in_pkt;
reg                   first_seen;
reg [9:0]             prev_low10;
reg [9:0]             expected_low10;

task tb_fail;
    input [255:0] msg;
    begin
        $display("[TB_RX][FAIL] %0t ns: %0s", $time, msg);
        $finish;
    end
endtask

// ADC 时钟 100MHz
initial clk_adc = 1'b0;
always #5 clk_adc = ~clk_adc;

// AXI 时钟约 166MHz，并且故意相位偏移，避免与 ADC 边沿重叠
initial begin
    clk_axi = 1'b0;
    #1;
    forever #3 clk_axi = ~clk_axi;
end

ad9215_capture #(
    .ADC_DW(ADC_DW),
    .OUT_DW(RX_DW)
) u_ad9215_capture (
    .clk_adc(clk_adc),
    .rst_n(rst_n),
    .adc_data(adc_data),
    .m_data(cap_data),
    .m_valid(cap_valid),
    .m_ready(cap_ready)
);

stream_async_fifo #(
    .DW(RX_DW),
    .DEPTH(FIFO_DEPTH)
) u_stream_async_fifo (
    .s_clk(clk_adc),
    .s_rst_n(rst_n),
    .s_data(cap_data),
    .s_valid(cap_valid),
    .s_ready(cap_ready),
    .m_clk(clk_axi),
    .m_rst_n(rst_n),
    .m_data(fifo_data),
    .m_valid(fifo_valid),
    .m_ready(fifo_ready)
);

stream_pkt_gen #(
    .DW(RX_DW),
    .PKT_LEN(PKT_LEN)
) u_stream_pkt_gen (
    .clk(clk_axi),
    .rst_n(rst_n),
    .s_data(fifo_data),
    .s_valid(fifo_valid),
    .s_ready(fifo_ready),
    .m_data(pkt_data),
    .m_valid(pkt_valid),
    .m_ready(pkt_ready),
    .m_last(pkt_last)
);

axis_to_dma_pkt #(
    .DW(RX_DW)
) u_axis_to_dma_pkt (
    .s_data(pkt_data),
    .s_valid(pkt_valid),
    .s_ready(pkt_ready),
    .s_last(pkt_last),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tlast(m_axis_tlast)
);

// ADC 激励：复位后每拍 +1
always @(posedge clk_adc or negedge rst_n) begin
    if (!rst_n) begin
        adc_data <= {ADC_DW{1'b0}};
    end else begin
        adc_data <= adc_data + 1'b1;
    end
end

// 下游回压：大部分时间 ready=1，周期性拉低 1 拍
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        axi_cycle_cnt <= 0;
        m_axis_tready <= 1'b0;
    end else begin
        axi_cycle_cnt <= axi_cycle_cnt + 1;
        m_axis_tready <= (axi_cycle_cnt % 9 != 0);
    end
end

// 检查器：连续性 + 包尾
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        recv_cnt    <= 0;
        beat_in_pkt <= 0;
        first_seen  <= 1'b0;
        prev_low10  <= 10'd0;
    end else if (m_axis_tvalid && m_axis_tready) begin
        if (m_axis_tkeep !== {((RX_DW+7)/8){1'b1}}) begin
            tb_fail("tkeep 不是全1");
        end

        if (m_axis_tdata[15:10] !== 6'd0) begin
            tb_fail("RX 数据高6位不是 0，和容器规范不一致");
        end

        if (!first_seen) begin
            first_seen <= 1'b1;
        end else begin
            expected_low10 = prev_low10 + 10'd1;
            if (m_axis_tdata[9:0] !== expected_low10) begin
                tb_fail("低10位样本不连续，存在乱序或丢样");
            end
        end
        prev_low10 <= m_axis_tdata[9:0];

        if (beat_in_pkt == PKT_LEN-1) begin
            if (!m_axis_tlast) begin
                tb_fail("包尾位置未拉高 tlast");
            end
            beat_in_pkt <= 0;
        end else begin
            if (m_axis_tlast) begin
                tb_fail("非包尾位置错误拉高 tlast");
            end
            beat_in_pkt <= beat_in_pkt + 1;
        end

        recv_cnt <= recv_cnt + 1;
        if ((recv_cnt + 1) >= TARGET_BEAT) begin
            $display("[TB_RX][PASS] %0t ns: RX 最小链路检查通过，接收拍数=%0d", $time, (recv_cnt + 1));
            $finish;
        end
    end
end

initial begin
    rst_n = 1'b0;
    adc_data = {ADC_DW{1'b0}};
    m_axis_tready = 1'b0;
    axi_cycle_cnt = 0;

    repeat (12) @(posedge clk_adc);
    rst_n = 1'b1;
end

endmodule
