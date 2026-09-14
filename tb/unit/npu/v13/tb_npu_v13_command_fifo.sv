// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// npu_v13_command_fifo 自检：
//   1. reset 后 empty/level/valid；
//   2. 填满、满队列反压，以及 pop 释放后下一拍恢复 push；
//   3. 连续出队 II=1、顺序不乱；
//   4. 随机 ready/valid、指针多次回绕；
//   5. 输出反压时 data/valid 保持；
//   6. count=1 的 pop+push 稀疏碰撞边界不丢数据。
//   7. 非满稳态下连续 push+pop，每拍双握手且跨多轮指针回绕。
//   8. 两级预取内部始终满足 level=sequence_delta+raw_valid+out_valid。
//////////////////////////////////////////////////////////////////////////////////
module tb_npu_v13_command_fifo;
    localparam integer DATA_W = 37;
    localparam integer DEPTH = 8;
    localparam integer LEVEL_W = $clog2(DEPTH + 1);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg in_valid_i = 1'b0;
    wire in_ready_o;
    reg [DATA_W-1:0] in_data_i = {DATA_W{1'b0}};
    wire out_valid_o;
    reg out_ready_i = 1'b0;
    wire [DATA_W-1:0] out_data_o;
    wire empty_o;
    wire full_o;
    wire [LEVEL_W-1:0] level_o;

    npu_v13_command_fifo #(
        .DATA_W(DATA_W),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .in_valid_i(in_valid_i),
        .in_ready_o(in_ready_o),
        .in_data_i(in_data_i),
        .out_valid_o(out_valid_o),
        .out_ready_i(out_ready_i),
        .out_data_o(out_data_o),
        .empty_o(empty_o),
        .full_o(full_o),
        .level_o(level_o)
    );

    reg [DATA_W-1:0] expected [0:4095];
    integer expected_head = 0;
    integer expected_tail = 0;
    integer accepted_count = 0;
    integer retired_count = 0;
    integer errors = 0;
    integer cycle_count = 0;
    integer next_value = 1;

    reg stalled_r = 1'b0;
    reg [DATA_W-1:0] stalled_data_r = {DATA_W{1'b0}};

    task automatic report_error;
        input [8*180-1:0] message;
        begin
            errors = errors + 1;
            $display("ERROR command_fifo cycle=%0d %0s", cycle_count, message);
        end
    endtask

    // 握手必须按上升沿前的 valid/ready 采样；#1 后再检查 NBA 更新后的状态。
    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (resetn) begin
            if (in_valid_i && in_ready_o) begin
                expected[expected_tail] = in_data_i;
                expected_tail = expected_tail + 1;
                accepted_count = accepted_count + 1;
            end

            if (out_valid_o && out_ready_i) begin
                if (expected_head >= expected_tail) begin
                    report_error("output handshake occurred with empty scoreboard");
                end else if (out_data_o !== expected[expected_head]) begin
                    $display("ERROR command_fifo order expected=%h actual=%h",
                             expected[expected_head], out_data_o);
                    errors = errors + 1;
                end
                expected_head = expected_head + 1;
                retired_count = retired_count + 1;
            end
        end

        #1;
        if (!resetn) begin
            stalled_r = 1'b0;
        end else begin
            if (level_o !== (expected_tail - expected_head))
                report_error("level does not match scoreboard occupancy");
            if (empty_o !== ((expected_tail - expected_head) == 0))
                report_error("empty flag does not match occupancy");
            if (full_o !== ((expected_tail - expected_head) == DEPTH))
                report_error("full flag does not match occupancy");
            // 这是两级 BRAM 预取结构最关键的所有权守恒式：每条尚未退休的
            // 命令必须且只能位于 memory 未读区、raw stage 或 output stage 之一。
            // 外部 scoreboard 最终也能发现丢失/重复，但该断言可在出错的第一拍
            // 直接指出是预取级 valid/count 转移错误。
            if (level_o !== (dut.unread_count_r +
                             dut.ram_valid_r + dut.out_valid_r))
                report_error("internal prefetch ownership invariant failed");
            if (out_valid_o && !out_ready_i) begin
                if (stalled_r && (out_data_o !== stalled_data_r))
                    report_error("output data changed during backpressure");
                stalled_r = 1'b1;
                stalled_data_r = out_data_o;
            end else begin
                stalled_r = 1'b0;
            end
        end
    end

    integer i;
    integer full_release_push_cycle;
    integer continuous_pop_cycles;
    integer steady_both_cycles;
    localparam integer STEADY_OCCUPANCY = DEPTH/2;
    initial begin
        // valid 可以跨过 reset，但 reset 期间绝不能形成入口握手。
        in_valid_i = 1'b1;
        in_data_i = {DATA_W{1'b1}};
        repeat (4) begin
            @(posedge clk);
            #1;
            if (in_ready_o !== 1'b0)
                report_error("input ready asserted during reset");
        end
        @(negedge clk);
        in_valid_i = 1'b0;
        resetn = 1'b1;

        // 连续填满 FIFO；读端反压期间，head 必须稳定。
        out_ready_i = 1'b0;
        in_valid_i = 1'b1;
        for (i = 0; i < DEPTH; i = i + 1) begin
            in_data_i = next_value;
            next_value = next_value + 1;
            @(negedge clk);
        end
        in_valid_i = 1'b0;
        repeat (2) @(negedge clk);
        if (!full_o || in_ready_o)
            report_error("FIFO did not assert full backpressure");

        // 满队列不允许当前 pop 组合进入 BRAM 写使能；先 pop 释放空间，
        // 下一拍 ready 恢复并接收保持中的输入。valid/data 必须跨反压稳定。
        out_ready_i = 1'b1;
        in_valid_i = 1'b1;
        in_data_i = next_value;
        next_value = next_value + 1;
        #1;
        if (in_ready_o !== 1'b0)
            report_error("full FIFO ready depends combinationally on current pop");
        full_release_push_cycle = cycle_count + 1;
        while (!in_ready_o)
            @(negedge clk);
        @(posedge clk);
        #1;
        @(negedge clk);
        in_valid_i = 1'b0;
        if (full_o)
            report_error("FIFO stayed full after pop released one slot");

        // 预装队列持续出队必须每拍都有一次握手。
        continuous_pop_cycles = 0;
        while (!empty_o) begin
            if (!out_valid_o)
                report_error("preloaded FIFO inserted an output bubble");
            @(posedge clk);
            continuous_pop_cycles = continuous_pop_cycles + 1;
            #1;
            @(negedge clk);
        end
        if (continuous_pop_cycles != DEPTH-1)
            report_error("preloaded FIFO did not sustain continuous output");

        // 构造 count=1 的 pop+push；允许 valid 暂停，但新数据必须最终返回。
        out_ready_i = 1'b0;
        in_valid_i = 1'b1;
        in_data_i = next_value;
        next_value = next_value + 1;
        @(negedge clk);
        in_valid_i = 1'b0;
        while (!out_valid_o) @(negedge clk);
        out_ready_i = 1'b1;
        in_valid_i = 1'b1;
        in_data_i = next_value;
        next_value = next_value + 1;
        @(negedge clk);
        in_valid_i = 1'b0;
        while (!out_valid_o) @(negedge clk);
        @(negedge clk);
        out_ready_i = 1'b0;

        // 先预装半深度并等待 raw/output 两级都热身，再连续多轮同拍 push+pop。
        // 纯 drain 只能证明读侧 II=1；本段还会覆盖写指针、fetch 指针同时回绕，
        // 并抓住 raw stage 前移与下一次 BRAM read 同拍时的丢失/重复错误。
        in_valid_i = 1'b1;
        for (i = 0; i < STEADY_OCCUPANCY; i = i + 1) begin
            in_data_i = next_value;
            next_value = next_value + 1;
            @(posedge clk);
            #1;
            @(negedge clk);
        end
        in_valid_i = 1'b0;
        while (!(out_valid_o && dut.ram_valid_r))
            @(negedge clk);

        out_ready_i = 1'b1;
        in_valid_i = 1'b1;
        in_data_i = next_value;
        next_value = next_value + 1;
        steady_both_cycles = 0;
        for (i = 0; i < 4*DEPTH; i = i + 1) begin
            if (!in_ready_o || !out_valid_o)
                report_error("steady simultaneous push/pop handshake was not II=1");
            @(posedge clk);
            steady_both_cycles = steady_both_cycles + 1;
            #1;
            if (level_o != STEADY_OCCUPANCY)
                report_error("steady simultaneous push/pop changed occupancy");
            @(negedge clk);
            in_data_i = next_value;
            next_value = next_value + 1;
        end
        in_valid_i = 1'b0;
        while (!empty_o || out_valid_o)
            @(negedge clk);
        out_ready_i = 1'b0;
        if (steady_both_cycles != 4*DEPTH)
            report_error("steady simultaneous push/pop cycle count mismatch");

        // 随机压力测试；上游在 ready=0 时严格保持 valid/data。
        for (i = 0; i < 600; i = i + 1) begin
            @(negedge clk);
            out_ready_i = ($urandom_range(0, 99) < 63);
            if (!(in_valid_i && !in_ready_o)) begin
                in_valid_i = ($urandom_range(0, 99) < 67);
                if (in_valid_i) begin
                    in_data_i = next_value;
                    next_value = next_value + 1;
                end
            end
        end

        // 停止生产并完全排空。
        @(negedge clk);
        in_valid_i = 1'b0;
        out_ready_i = 1'b1;
        while (!empty_o || out_valid_o)
            @(negedge clk);
        repeat (3) @(posedge clk);

        if (expected_head != expected_tail)
            report_error("final scoreboard is not empty");
        if (accepted_count != retired_count)
            report_error("accepted and retired command counts differ");

        if (errors == 0)
            $display("NPU_V13_COMMAND_FIFO_TB_PASS accepted=%0d retired=%0d full_release_push_cycle=%0d",
                     accepted_count, retired_count, full_release_push_cycle);
        else
            $display("NPU_V13_COMMAND_FIFO_TB_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("NPU_V13_COMMAND_FIFO_TB_TIMEOUT");
        $finish;
    end
endmodule
