`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Testbench: tb_qpsk_tx_chain_min
// 目的:
// 1) 验证 qpsk_test_gen -> qpsk_mod_core -> ad9762_driver 最小发送链路
// 2) 本用例保留为 legacy 映射链验证（推荐链路见 tb_qpsk_tx_single_dac_min）
// 3) 检查 Gray 映射与 I/Q 交织输出顺序（I 后 Q）
// 4) 检查回压时 qpsk_mod_core 输出保持稳定
// -----------------------------------------------------------------------------
module tb_qpsk_tx_chain_min;

localparam integer DW            = 12;
localparam integer TARGET_BEAT   = 64;
localparam [DW-1:0] LEVEL_POS    = 12'd3072; // 2048 + 1024
localparam [DW-1:0] LEVEL_NEG    = 12'd1024; // 2048 - 1024

reg                clk;
reg                rst_n;
reg                gen_en;
reg  [1:0]         gen_mode_sel;
reg  [1:0]         gen_cfg_sym;
wire [1:0]         gen_sym;
wire               gen_valid;
wire               gen_ready;

wire [DW-1:0]      mod_data;
wire               mod_valid;
reg                mod_ready;
wire [DW-1:0]      dac_data;

integer            recv_cnt;
integer            ready_cycle_cnt;
reg [DW-1:0]       expected_data;
reg [DW-1:0]       hold_data;
reg                hold_valid;
reg [DW-1:0]       hs_data_dly;
reg                hs_data_dly_valid;
// hold_*: 用于检测回压期间输出是否保持稳定
// hs_data_dly*: 用于比较 DAC 是否在下一拍输出“上一拍握手成功”的数据

task tb_fail;
    input [255:0] msg;
    begin
        $display("[TB_QPSK_TX][FAIL] %0t ns: %0s", $time, msg);
        $finish;
    end
endtask

function [DW-1:0] expected_seq;
    input integer idx;
    begin
        case (idx % 8)
            0: expected_seq = LEVEL_POS; // sym 00, I
            1: expected_seq = LEVEL_POS; // sym 00, Q
            2: expected_seq = LEVEL_NEG; // sym 01, I
            3: expected_seq = LEVEL_POS; // sym 01, Q
            4: expected_seq = LEVEL_NEG; // sym 11, I
            5: expected_seq = LEVEL_NEG; // sym 11, Q
            6: expected_seq = LEVEL_POS; // sym 10, I
            7: expected_seq = LEVEL_NEG; // sym 10, Q
            default: expected_seq = LEVEL_POS;
        endcase
    end
endfunction

// 100MHz
initial clk = 1'b0;
always #5 clk = ~clk;

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

qpsk_mod_core #(
    .DW(DW)
) u_qpsk_mod_core (
    .clk(clk),
    .rst_n(rst_n),
    .s_sym(gen_sym),
    .s_valid(gen_valid),
    .s_ready(gen_ready),
    .m_data(mod_data),
    .m_valid(mod_valid),
    .m_ready(mod_ready)
);

ad9762_driver #(
    .DW(DW),
    .HOLD_LAST(1)
) u_ad9762_driver (
    .clk_dac(clk),
    .rst_n(rst_n),
    .s_data(mod_data),
    .s_valid(mod_valid),
    .s_ready(),
    .dac_data(dac_data)
);

// 周期性回压，验证调制器在 ready=0 时保持输出
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ready_cycle_cnt <= 0;
        mod_ready <= 1'b0;
    end else begin
        ready_cycle_cnt <= ready_cycle_cnt + 1;
        mod_ready <= (ready_cycle_cnt % 7 != 0);
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        recv_cnt   <= 0;
        hold_data  <= {DW{1'b0}};
        hold_valid <= 1'b0;
        hs_data_dly <= {DW{1'b0}};
        hs_data_dly_valid <= 1'b0;
    end else begin
        // ad9762_driver 在时钟沿更新，因此这里比较“上一拍握手数据 -> 当前拍DAC输出”
        if (hs_data_dly_valid) begin
            if (dac_data !== hs_data_dly) begin
                tb_fail("DAC 输出与上一拍握手数据不一致");
            end
            hs_data_dly_valid <= 1'b0;
        end

        if (mod_valid && !mod_ready) begin
            if (!hold_valid) begin
                hold_valid <= 1'b1;
                hold_data  <= mod_data;
            end else if (mod_data !== hold_data) begin
                // 回压期间数据必须保持，不允许在未握手时跳变
                tb_fail("回压期间 m_data 不稳定");
            end
        end else begin
            hold_valid <= 1'b0;
        end

        if (mod_valid && mod_ready) begin
            // 握手成功时检查符号映射序列
            expected_data = expected_seq(recv_cnt);
            if (mod_data !== expected_data) begin
                tb_fail("QPSK 映射序列不符合预期");
            end

            // 记录本拍握手值，下一拍检查 DAC 是否正确更新
            hs_data_dly <= mod_data;
            hs_data_dly_valid <= 1'b1;

            recv_cnt <= recv_cnt + 1;
            if ((recv_cnt + 1) >= TARGET_BEAT) begin
                $display("[TB_QPSK_TX][PASS] %0t ns: QPSK TX 最小链路检查通过, beat=%0d", $time, (recv_cnt + 1));
                $finish;
            end
        end
    end
end

initial begin
    rst_n          = 1'b0;
    gen_en         = 1'b0;
    gen_mode_sel   = 2'd0;
    gen_cfg_sym    = 2'b00;
    mod_ready      = 1'b0;
    ready_cycle_cnt = 0;

    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    gen_en = 1'b1;
end

endmodule
