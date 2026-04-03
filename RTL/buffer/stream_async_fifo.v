// -----------------------------------------------------------------------------
// 模块: stream_async_fifo
// 功能: 跨时钟域流式 FIFO（s_clk -> m_clk）
// 实现: 基于 Xilinx xpm_fifo_async，接口统一为 data/valid/ready
// -----------------------------------------------------------------------------
module stream_async_fifo #(
    parameter integer DW = 16,
    parameter integer DEPTH = 1024
) (
    input  wire          s_clk,
    input  wire          s_rst_n,
    input  wire [DW-1:0] s_data,
    input  wire          s_valid,
    output wire          s_ready,
    input  wire          m_clk,
    input  wire          m_rst_n,
    output wire [DW-1:0] m_data,
    output wire          m_valid,
    input  wire          m_ready
);

localparam integer CNT_W = (DEPTH <= 2) ? 2 : $clog2(DEPTH) + 1;
wire rst;
wire full;
wire empty;
wire wr_rst_busy;
wire rd_rst_busy;
wire [DW-1:0] dout;
wire [CNT_W-1:0] wr_data_count;
wire [CNT_W-1:0] rd_data_count;

assign rst = (~s_rst_n) | (~m_rst_n);
// 写端可接收条件：FIFO 未满且未处于复位忙
assign s_ready = (~full) & (~wr_rst_busy);
// 读端有数据条件：FIFO 非空且未处于复位忙
assign m_valid = (~empty) & (~rd_rst_busy);
assign m_data = dout;

xpm_fifo_async #(
    .CASCADE_HEIGHT(0),
    .CDC_SYNC_STAGES(2),
    .DOUT_RESET_VALUE("0"),
    .ECC_MODE("no_ecc"),
    .FIFO_MEMORY_TYPE("auto"),
    .FIFO_READ_LATENCY(0),
    .FIFO_WRITE_DEPTH(DEPTH),
    .FULL_RESET_VALUE(0),
    .PROG_EMPTY_THRESH(10),
    .PROG_FULL_THRESH(10),
    .RD_DATA_COUNT_WIDTH(CNT_W),
    .READ_DATA_WIDTH(DW),
    .READ_MODE("fwft"),
    .RELATED_CLOCKS(0),
    .SIM_ASSERT_CHK(0),
    .USE_ADV_FEATURES("0000"),
    .WAKEUP_TIME(0),
    .WRITE_DATA_WIDTH(DW),
    .WR_DATA_COUNT_WIDTH(CNT_W)
) u_xpm_fifo_async (
    .sleep(1'b0),
    .rst(rst),
    .wr_clk(s_clk),
    .wr_en(s_valid & s_ready),
    .din(s_data),
    .full(full),
    .prog_full(),
    .wr_data_count(wr_data_count),
    .overflow(),
    .wr_rst_busy(wr_rst_busy),
    .rd_clk(m_clk),
    .rd_en(m_ready & m_valid),
    .dout(dout),
    .empty(empty),
    .prog_empty(),
    .rd_data_count(rd_data_count),
    .underflow(),
    .rd_rst_busy(rd_rst_busy),
    .injectsbiterr(1'b0),
    .injectdbiterr(1'b0),
    .sbiterr(),
    .dbiterr()
);

endmodule
