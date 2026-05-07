`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_pl_comm_top_fixed_cfg_loopback
// 目的:
// 1) 验证 pl_comm_top_fixed_cfg 在“无板回环”下的 TX -> ADC -> RX AXIS 闭环
// 2) 检查 RX AXIS 输出是否按 ADC 采样顺序转发，且高位零扩展正确
// 3) 检查固定包长对应的 tlast 节奏，以及回压期间 tdata/tlast 保持稳定
// 说明:
//   - 用独立的 clk_io / clk_axi 双时钟驱动 DUT
//   - 用 DUT 输出的 clk_adc 对 dac_data 做简化数字回灌，并右移 2bit 映射到 10bit adc_data
//   - 该用例聚焦 PL 数据链闭环，不尝试逼近真实模拟链路
// -----------------------------------------------------------------------------
module tb_pl_comm_top_fixed_cfg_loopback;

localparam integer ADC_DW        = 10;
localparam integer DAC_DW        = 12;
localparam integer RX_DW         = 16;
localparam integer FIFO_DEPTH    = 256;
localparam integer PKT_LEN       = 32;
localparam integer TARGET_BEAT   = 512;
localparam integer EXP_Q_DEPTH   = 4096;
localparam integer MIN_CHANGES   = TARGET_BEAT / 16;
localparam [((RX_DW+7)/8)-1:0] AXIS_KEEP_ALL = {((RX_DW+7)/8){1'b1}};

reg                       clk_io;
reg                       clk_axi;
reg                       rst_n;
reg  [ADC_DW-1:0]         adc_data;
wire                      clk_dac;
wire                      clk_adc;
wire [DAC_DW-1:0]         dac_data;
wire [RX_DW-1:0]          m_axis_rx_tdata;
wire [((RX_DW+7)/8)-1:0]  m_axis_rx_tkeep;
wire                      m_axis_rx_tvalid;
reg                       m_axis_rx_tready;
wire                      m_axis_rx_tlast;

reg [1:0]                 rst_sync_adc;
reg [1:0]                 rst_sync_axi;
wire                      tb_rst_n_adc;
wire                      tb_rst_n_axi;

reg [ADC_DW-1:0]          expected_q [0:EXP_Q_DEPTH-1];
integer                   exp_wr_idx;
integer                   exp_rd_idx;
integer                   axi_cycle_cnt;
integer                   recv_cnt;
integer                   beat_in_pkt;
integer                   change_cnt;
reg                       first_seen;
reg [ADC_DW-1:0]          prev_sample;
reg                       axis_hold_valid;
reg [RX_DW-1:0]           axis_hold_data;
reg                       axis_hold_last;
reg [ADC_DW-1:0]          expected_sample;
reg                       sample_changed;

assign tb_rst_n_adc = rst_sync_adc[1];
assign tb_rst_n_axi = rst_sync_axi[1];

task tb_fail;
    input [255:0] msg;
    begin
        $display("[TB_PL_LOOPBACK][FAIL] %0t ns: %0s", $time, msg);
        $finish;
    end
endtask

// 采样侧与 AXI 侧分别使用独立时钟，验证 async FIFO 跨域路径。
initial clk_io = 1'b0;
always #5 clk_io = ~clk_io;

initial clk_axi = 1'b0;
always #4 clk_axi = ~clk_axi;

pl_comm_top_fixed_cfg #(
    .ADC_DW(ADC_DW),
    .DAC_DW(DAC_DW),
    .RX_DW(RX_DW),
    .FIFO_DEPTH(FIFO_DEPTH),
    .PKT_LEN(PKT_LEN),
    .FIXED_TX_EN(1),
    .FIXED_RX_EN(1)
) u_dut (
    .clk_io(clk_io),
    .clk_adc(clk_adc),
    .clk_axi(clk_axi),
    .clk_dac(clk_dac),
    .rst_n(rst_n),
    .adc_data(adc_data),
    .dac_data(dac_data),
    .m_axis_rx_tdata(m_axis_rx_tdata),
    .m_axis_rx_tkeep(m_axis_rx_tkeep),
    .m_axis_rx_tvalid(m_axis_rx_tvalid),
    .m_axis_rx_tready(m_axis_rx_tready),
    .m_axis_rx_tlast(m_axis_rx_tlast)
);

// 在 testbench 侧镜像 reset_sync 的同步释放行为，便于和 DUT 内部时序对齐
always @(posedge clk_io or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync_adc <= 2'b00;
    end else begin
        rst_sync_adc <= {rst_sync_adc[0], 1'b1};
    end
end

always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync_axi <= 2'b00;
    end else begin
        rst_sync_axi <= {rst_sync_axi[0], 1'b1};
    end
end

// 简化数字回环:
// 1) 只有当 RX 写侧真的把样本送进 async FIFO 时，才把该样本记入期望队列
//    这样可以避开 FIFO reset busy/ready=0 时 ADC 不可回压导致的前几拍丢样
// 2) 用 DUT 输出给 ADC 的 clk_adc 在上升沿更新 adc_data，
//    DUT 在内部相反边沿采样，从而形成半个周期的采样错开
always @(posedge clk_adc or negedge rst_n) begin
    if (!rst_n) begin
        adc_data   <= {ADC_DW{1'b0}};
        exp_wr_idx <= 0;
    end else begin
        if (u_dut.u_pl_comm_top.cap_valid_gated && u_dut.u_pl_comm_top.cap_ready) begin
            if (exp_wr_idx >= EXP_Q_DEPTH) begin
                tb_fail("ERR_EXP_QUEUE_OVERFLOW");
            end
            expected_q[exp_wr_idx] <= u_dut.u_pl_comm_top.cap_data[ADC_DW-1:0];
            exp_wr_idx <= exp_wr_idx + 1;
        end

        adc_data <= dac_data[DAC_DW-1 -: ADC_DW];
    end
end

// AXIS 下游回压：大部分时间 ready=1，周期性拉低 1 拍
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        axi_cycle_cnt    <= 0;
        m_axis_rx_tready <= 1'b0;
    end else begin
        axi_cycle_cnt    <= axi_cycle_cnt + 1;
        m_axis_rx_tready <= (axi_cycle_cnt % 11 != 0);
    end
end

// AXIS 输出检查:
// 1) 回压时 tdata/tlast 保持稳定
// 2) 握手数据与 ADC 采样顺序一致
// 3) tkeep 全1，高位零扩展，tlast 按 PKT_LEN 周期出现
always @(posedge clk_axi or negedge rst_n) begin
    if (!rst_n) begin
        exp_rd_idx      <= 0;
        recv_cnt        <= 0;
        beat_in_pkt     <= 0;
        change_cnt      <= 0;
        first_seen      <= 1'b0;
        prev_sample     <= {ADC_DW{1'b0}};
        axis_hold_valid <= 1'b0;
        axis_hold_data  <= {RX_DW{1'b0}};
        axis_hold_last  <= 1'b0;
        sample_changed  <= 1'b0;
    end else begin
        if (tb_rst_n_axi && m_axis_rx_tvalid && !m_axis_rx_tready) begin
            if (!axis_hold_valid) begin
                axis_hold_valid <= 1'b1;
                axis_hold_data  <= m_axis_rx_tdata;
                axis_hold_last  <= m_axis_rx_tlast;
            end else begin
                if (m_axis_rx_tdata !== axis_hold_data) begin
                    tb_fail("ERR_AXIS_HOLD_TDATA");
                end
                if (m_axis_rx_tlast !== axis_hold_last) begin
                    tb_fail("ERR_AXIS_HOLD_TLAST");
                end
            end
        end else begin
            axis_hold_valid <= 1'b0;
        end

        if (tb_rst_n_axi && m_axis_rx_tvalid && m_axis_rx_tready) begin
            if (m_axis_rx_tkeep !== AXIS_KEEP_ALL) begin
                tb_fail("ERR_TKEEP_NOT_ALL1");
            end

            if (exp_rd_idx >= exp_wr_idx) begin
                tb_fail("ERR_EXP_QUEUE_UNDERFLOW");
            end
            expected_sample = expected_q[exp_rd_idx];

            if (m_axis_rx_tdata[RX_DW-1:ADC_DW] !== {(RX_DW-ADC_DW){1'b0}}) begin
                tb_fail("ERR_ADC_CONTAINER");
            end

            if (m_axis_rx_tdata[ADC_DW-1:0] !== expected_sample) begin
                tb_fail("ERR_ADC_MISMATCH");
            end

            sample_changed = first_seen && (expected_sample !== prev_sample);

            if (beat_in_pkt == PKT_LEN-1) begin
                if (!m_axis_rx_tlast) begin
                    tb_fail("ERR_TLAST_MISS");
                end
                beat_in_pkt <= 0;
            end else begin
                if (m_axis_rx_tlast) begin
                    tb_fail("ERR_TLAST_EARLY");
                end
                beat_in_pkt <= beat_in_pkt + 1;
            end

            if (sample_changed) begin
                change_cnt <= change_cnt + 1;
            end
            prev_sample <= expected_sample;
            first_seen  <= 1'b1;

            exp_rd_idx <= exp_rd_idx + 1;
            recv_cnt   <= recv_cnt + 1;
            if ((recv_cnt + 1) >= TARGET_BEAT) begin
                if ((change_cnt + sample_changed) < MIN_CHANGES) begin
                    tb_fail("ERR_SAMPLE_NOT_CHANGING");
                end
                $display("[TB_PL_LOOPBACK][PASS] %0t ns: 顶层无板回环检查通过, beat=%0d", $time, (recv_cnt + 1));
                $finish;
            end
        end
    end
end

initial begin
    rst_n           = 1'b0;
    adc_data        = {ADC_DW{1'b0}};
    m_axis_rx_tready = 1'b0;
    rst_sync_adc    = 2'b00;
    rst_sync_axi    = 2'b00;
    axi_cycle_cnt   = 0;

    repeat (12) @(posedge clk_axi);
    rst_n = 1'b1;
end

initial begin
    #200000;
    tb_fail("ERR_TIMEOUT");
end

endmodule
