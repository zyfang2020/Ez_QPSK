// -----------------------------------------------------------------------------
// 模块: axis_to_dma_pkt
// 功能: 将工程内部流接口映射成 AXI-Stream（供 AXI DMA S2MM）
// 映射: data->tdata, valid->tvalid, ready<-tready, last->tlast
// -----------------------------------------------------------------------------
module axis_to_dma_pkt #(
    parameter integer DW = 16
) (
    input  wire [DW-1:0] s_data,
    input  wire          s_valid,
    output wire          s_ready,
    input  wire          s_last,
    output wire [DW-1:0] m_axis_tdata,
    output wire [((DW+7)/8)-1:0] m_axis_tkeep,
    output wire          m_axis_tvalid,
    input  wire          m_axis_tready,
    output wire          m_axis_tlast
);

assign s_ready = m_axis_tready;
assign m_axis_tdata = s_data;
// 每个字节都有效；当前最小版本不做稀疏字节掩码
assign m_axis_tkeep = {((DW+7)/8){1'b1}};
assign m_axis_tvalid = s_valid;
assign m_axis_tlast = s_last;

endmodule
