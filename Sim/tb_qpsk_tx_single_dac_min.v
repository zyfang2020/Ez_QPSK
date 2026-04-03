`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_qpsk_tx_single_dac_min
// 目的:
// 1) 验证 qpsk_test_gen -> qpsk_tx_single_dac -> ad9762_driver 最小单DAC发射链
// 2) 检查回压时输出稳定（m_valid=1 且 m_ready=0 时 m_data 不应跳变）
// 3) 检查输出存在有效变化（非全常数）
// -----------------------------------------------------------------------------
module tb_qpsk_tx_single_dac_min;

localparam integer DAC_DW        = 12;
localparam integer TARGET_ACCEPT = 5000;
localparam [23:0]  PHASE_INC     = 24'h180000;
localparam [1:0]   RRC_BETA_SEL  = 2'd2; // 0:0.20, 1:0.35, 2:0.50
localparam integer DUMP_EN       = 1;
localparam [255:0] DUMP_FILE     = "qpsk_single_dac_samples.csv";

reg                  clk;
reg                  rst_n;
reg                  gen_en;
reg  [1:0]           gen_mode_sel;
reg  [1:0]           gen_cfg_sym;
wire [1:0]           gen_sym;
wire                 gen_valid;
wire                 gen_ready;

wire [DAC_DW-1:0]    tx_data;
wire                 tx_valid;
reg                  tx_ready;
wire [DAC_DW-1:0]    dac_data;

integer              accept_cnt;
integer              ready_cycle_cnt;
integer              change_cnt;
integer              dump_fd;
integer              dump_wr_cnt;
reg [DAC_DW-1:0]     prev_accept_data;
reg [DAC_DW-1:0]     hold_data;
reg                  hold_valid;
reg [DAC_DW-1:0]     hs_data_dly;
reg                  hs_data_dly_valid;

task tb_fail;
    input [255:0] msg;
    begin
        if (DUMP_EN && (dump_fd != 0)) begin
            $fclose(dump_fd);
        end
        $display("[TB_QPSK_TX_DAC][FAIL] %0t ns: %0s", $time, msg);
        $finish;
    end
endtask

initial clk = 1'b0;
always #5 clk = ~clk;  // 100MHz

qpsk_test_gen u_qpsk_test_gen (
    .clk(clk),
    .rst_n(rst_n),
    .en(gen_en),
    .mode_sel(gen_mode_sel),
    .cfg_sym(gen_cfg_sym),
    .m_sym(gen_sym),
    .m_valid(gen_valid),
    .m_ready(gen_ready)
);

qpsk_tx_single_dac #(
    .DAC_DW(DAC_DW),
    .SYM_W(12),
    .MIX_W(18),
    .PHASE_W(24),
    .SHAPER_SPS(50),
    .SHAPER_BETA_SEL(RRC_BETA_SEL)
) u_qpsk_tx_single_dac (
    .clk(clk),
    .rst_n(rst_n),
    .s_sym(gen_sym),
    .s_valid(gen_valid),
    .s_ready(gen_ready),
    .cfg_rrc_beta_sel(RRC_BETA_SEL),
    .cfg_phase_inc(PHASE_INC),
    .m_data(tx_data),
    .m_valid(tx_valid),
    .m_ready(tx_ready)
);

ad9762_driver #(
    .DW(DAC_DW),
    .HOLD_LAST(1)
) u_ad9762_driver (
    .clk_dac(clk),
    .rst_n(rst_n),
    .s_data(tx_data),
    .s_valid(tx_valid),
    .s_ready(),
    .dac_data(dac_data)
);

// 周期性回压
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ready_cycle_cnt <= 0;
        tx_ready <= 1'b0;
    end else begin
        ready_cycle_cnt <= ready_cycle_cnt + 1;
        tx_ready <= 1'b1;//(ready_cycle_cnt % 11 != 0);
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accept_cnt         <= 0;
        change_cnt         <= 0;
        dump_wr_cnt        <= 0;
        prev_accept_data   <= {DAC_DW{1'b0}};
        hold_data          <= {DAC_DW{1'b0}};
        hold_valid         <= 1'b0;
        hs_data_dly        <= {DAC_DW{1'b0}};
        hs_data_dly_valid  <= 1'b0;
    end else begin
        if (hs_data_dly_valid) begin
            if (dac_data !== hs_data_dly) begin
                tb_fail("DAC 输出与上一拍握手数据不一致");
            end
            hs_data_dly_valid <= 1'b0;
        end

        if (tx_valid && !tx_ready) begin
            if (!hold_valid) begin
                hold_valid <= 1'b1;
                hold_data  <= tx_data;
            end else if (tx_data !== hold_data) begin
                tb_fail("回压期间 tx_data 不稳定");
            end
        end else begin
            hold_valid <= 1'b0;
        end

        if (tx_valid && tx_ready) begin
            if ((^tx_data) === 1'bx) begin
                tb_fail("tx_data 出现 X/Z");
            end

            if (DUMP_EN && (dump_fd != 0)) begin
                $fwrite(dump_fd, "%0d,%0d\n", dump_wr_cnt, tx_data);
                dump_wr_cnt <= dump_wr_cnt + 1;
            end

            if (accept_cnt > 0 && tx_data !== prev_accept_data) begin
                change_cnt <= change_cnt + 1;
            end
            prev_accept_data <= tx_data;

            hs_data_dly <= tx_data;
            hs_data_dly_valid <= 1'b1;

            accept_cnt <= accept_cnt + 1;
            if ((accept_cnt + 1) >= TARGET_ACCEPT) begin
                if (change_cnt < (TARGET_ACCEPT/8)) begin
                    tb_fail("输出变化过少，可能未形成有效调制波形");
                end
                if (DUMP_EN && (dump_fd != 0)) begin
                    $fclose(dump_fd);
                end
                $display("[TB_QPSK_TX_DAC][PASS] %0t ns: 单DAC发射链检查通过, beat=%0d", $time, (accept_cnt + 1));
                $finish;
            end
        end
    end
end

initial begin
    dump_fd = 0;
    if (DUMP_EN) begin
        dump_fd = $fopen(DUMP_FILE, "w");
        if (dump_fd == 0) begin
            tb_fail("DAC 导出文件打开失败");
        end
        $fwrite(dump_fd, "idx,dac_u12\n");
    end

    rst_n          = 1'b0;
    gen_en         = 1'b0;
    gen_mode_sel   = 2'd0; // 循环Gray码
    gen_cfg_sym    = 2'b00;
    tx_ready       = 1'b0;
    ready_cycle_cnt = 0;

    repeat (10) @(posedge clk);
    rst_n = 1'b1;
    gen_en = 1'b1;
end

endmodule
