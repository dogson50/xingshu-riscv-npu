// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps

//////////////////////////////////////////////////////////////////////////////////
// npu_v13_systolic_cluster_16x4x4_stream 专用学习/回归 TB。
//
// 这个 TB 有意把 16 个 lane 的数据全部显式写出来：lane 0..15 分别对应
// 4×4 tile 网格的 tile(row,col)，从而可以直观看出“每 lane 一个 4×4 核”
// 和最终 16×16 row-major 输出之间的关系。
//
// 测试分两段：
//   1) 8 个连续 K=1 packet：16 个 lane 每拍都有效且每拍切换 M/N，验证
//      16 矩阵/拍的稳态吞吐和连续 shape sideband；K=1 时首尾同拍。
//   2) 1 个连续 K=2 packet：每个 lane 使用不同的 M/N 尾块形状，验证
//      与结果同拍的 2-bit count-1 shape sideband。
//
// DUT 没有 ready，TB 也不插入空拍；从输入 TLAST 到 c_valid_o 的固定延迟
// 为 10 拍（边界寄存器 1 拍 + 4×4 子核协议延迟）。
//////////////////////////////////////////////////////////////////////////////////
module tb_npu_v13_systolic_cluster_16x4x4_stream;
    localparam integer DATA_W = 8;
    localparam integer ACC_W  = 32;
    localparam integer TILE_COUNT = 16;
    localparam integer MACRO_ROWS = 16;
    localparam integer MACRO_COLS = 16;
    localparam integer MATRIX_W = MACRO_ROWS*MACRO_COLS*ACC_W;
    localparam integer PEAK_PACKETS = 8;
    localparam integer PACKET_COUNT = 9;
    localparam integer RESULT_LATENCY = 10;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg [15:0] s_axis_tvalid = 16'b0;
    reg [15:0] s_axis_tuser  = 16'b0;
    reg [15:0] s_axis_tlast  = 16'b0;
    reg [16*2-1:0] active_rows_m1_i = 0;
    reg [16*2-1:0] active_cols_m1_i = 0;
    reg [16*4*DATA_W-1:0] a_rows_i = 0;
    reg [16*4*DATA_W-1:0] b_cols_i = 0;
    wire [15:0] c_valid_o;
    wire [16*2-1:0] c_active_rows_m1_o;
    wire [16*2-1:0] c_active_cols_m1_o;
    wire [MATRIX_W-1:0] c_matrix_o;

    integer errors = 0;
    integer cycle_count = 0;
    integer accepted_beats = 0;
    integer produced_matrices = 0;
    integer expected_packet = 0;
    integer packet_last_cycle [0:PACKET_COUNT-1];
    integer result_due_cycle [0:PACKET_COUNT-1];
    integer first_input_cycle = -1;
    integer last_input_cycle = -1;
    integer first_result_cycle = -1;
    integer last_result_cycle = -1;
    integer previous_result_cycle = -1;
    integer input_bubbles = 0;

    npu_v13_systolic_cluster_16x4x4_stream #(
        .DATA_W(DATA_W), .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tuser(s_axis_tuser),
        .s_axis_tlast(s_axis_tlast),
        .active_rows_m1_i(active_rows_m1_i),
        .active_cols_m1_i(active_cols_m1_i),
        .a_rows_i(a_rows_i),
        .b_cols_i(b_cols_i),
        .c_valid_o(c_valid_o),
        .c_active_rows_m1_o(c_active_rows_m1_o),
        .c_active_cols_m1_o(c_active_cols_m1_o),
        .c_matrix_o(c_matrix_o)
    );

    // 保持在有符号 INT8 小范围，避免 TB 期望值自身溢出。
    function integer a_value;
        input integer packet_index;
        input integer lane;
        input integer row;
        input integer k;
        begin
            a_value = (((packet_index+1)*3 + lane*5 + row*2 + k*7) % 15) - 7;
        end
    endfunction

    function integer b_value;
        input integer packet_index;
        input integer lane;
        input integer col;
        input integer k;
        begin
            b_value = (((packet_index+2)*2 + lane*3 + col*4 + k*5) % 17) - 8;
        end
    endfunction

    // 峰值段也逐拍改变每 lane 的 shape，以覆盖连续 sideband 对齐。
    function integer lane_rows;
        input integer packet_index;
        input integer lane;
        begin
            lane_rows = (packet_index < PEAK_PACKETS) ?
                        (1 + ((packet_index + lane) % 4)) :
                        (1 + (lane % 4));
        end
    endfunction

    function integer lane_cols;
        input integer packet_index;
        input integer lane;
        begin
            lane_cols = (packet_index < PEAK_PACKETS) ?
                        (1 + ((packet_index*3 + lane/4) % 4)) :
                        (1 + ((lane / 4) % 4));
        end
    endfunction

    function integer packet_k_count;
        input integer packet_index;
        begin
            packet_k_count = (packet_index < PEAK_PACKETS) ? 1 : 2;
        end
    endfunction

    // 在一个 lane 的输入切片中写入 4 个 A 行元素、4 个 B 列元素和
    // 与子核相同的 2-bit count-1 M/N。所有 lane 都在同一拍调用此 task。
    task drive_lane;
        input integer packet_index;
        input integer lane;
        input integer k;
        integer r;
        integer c;
        begin
            s_axis_tvalid[lane] = 1'b1;
            s_axis_tuser[lane]  = (k == 0);
            s_axis_tlast[lane]  = (k == packet_k_count(packet_index)-1);
            active_rows_m1_i[lane*2 +: 2] = lane_rows(packet_index, lane)-1;
            active_cols_m1_i[lane*2 +: 2] = lane_cols(packet_index, lane)-1;
            for (r = 0; r < 4; r = r + 1)
                a_rows_i[(lane*4+r)*DATA_W +: DATA_W] =
                    a_value(packet_index, lane, r, k);
            for (c = 0; c < 4; c = c + 1)
                b_cols_i[(lane*4+c)*DATA_W +: DATA_W] =
                    b_value(packet_index, lane, c, k);
        end
    endtask

    task check_matrix;
        input integer packet_index;
        integer lane;
        integer tile_row;
        integer tile_col;
        integer lr;
        integer lc;
        integer global_row;
        integer global_col;
        integer k;
        integer expected;
        integer got;
        begin
            for (lane = 0; lane < TILE_COUNT; lane = lane + 1) begin
                tile_row = lane / 4;
                tile_col = lane % 4;
                if (c_active_rows_m1_o[lane*2 +: 2] !==
                    lane_rows(packet_index, lane)-1) begin
                    $display("FAIL packet=%0d lane=%0d rows_m1 got=%0d expected=%0d",
                             packet_index, lane,
                             c_active_rows_m1_o[lane*2 +: 2],
                             lane_rows(packet_index, lane)-1);
                    errors = errors + 1;
                end
                if (c_active_cols_m1_o[lane*2 +: 2] !==
                    lane_cols(packet_index, lane)-1) begin
                    $display("FAIL packet=%0d lane=%0d cols_m1 got=%0d expected=%0d",
                             packet_index, lane,
                             c_active_cols_m1_o[lane*2 +: 2],
                             lane_cols(packet_index, lane)-1);
                    errors = errors + 1;
                end
                for (lr = 0; lr < 4; lr = lr + 1) begin
                    for (lc = 0; lc < 4; lc = lc + 1) begin
                        global_row = tile_row*4 + lr;
                        global_col = tile_col*4 + lc;
                        // 超出同拍 shape 的元素是 don't-care，不进入比较。
                        if ((lr < lane_rows(packet_index, lane)) &&
                            (lc < lane_cols(packet_index, lane))) begin
                            expected = 0;
                            for (k = 0; k < packet_k_count(packet_index);
                                 k = k + 1)
                                expected = expected +
                                    a_value(packet_index, lane, lr, k)*
                                    b_value(packet_index, lane, lc, k);
                            got = $signed(c_matrix_o[
                                (global_row*MACRO_COLS+global_col)*ACC_W +:
                                ACC_W]);
                            if (got !== expected) begin
                                $display("FAIL packet=%0d lane=%0d local=(%0d,%0d) global=(%0d,%0d) got=%0d expected=%0d",
                                         packet_index, lane, lr, lc,
                                         global_row, global_col, got, expected);
                                errors = errors + 1;
                            end
                        end
                    end
                end
            end
            produced_matrices = produced_matrices + 1;
        end
    endtask

    // 结果 valid 应严格出现在相应 packet TLAST+10 拍，且 16 lane 同时有效。
    always @(posedge clk) begin
        integer result_latency;
        cycle_count = cycle_count + 1;
        if (resetn) begin
            if (c_valid_o !== 16'h0000 && c_valid_o !== 16'hffff) begin
                $display("FAIL partial c_valid cycle=%0d value=%h",
                         cycle_count, c_valid_o);
                errors = errors + 1;
            end
            if (s_axis_tvalid !== 16'h0000 && s_axis_tvalid !== 16'hffff) begin
                $display("FAIL partial input valid cycle=%0d value=%h",
                         cycle_count, s_axis_tvalid);
                errors = errors + 1;
            end

            if (s_axis_tvalid != 16'h0000) begin
                accepted_beats = accepted_beats + 1;
                if (first_input_cycle < 0)
                    first_input_cycle = cycle_count;
                if ((last_input_cycle >= 0) &&
                    (cycle_count != last_input_cycle+1)) begin
                    input_bubbles = input_bubbles + 1;
                    $display("FAIL input bubble previous=%0d current=%0d",
                             last_input_cycle, cycle_count);
                    errors = errors + 1;
                end
                last_input_cycle = cycle_count;
            end

            if (c_valid_o === 16'hffff) begin
                if (expected_packet >= PACKET_COUNT) begin
                    $display("FAIL unexpected result cycle=%0d", cycle_count);
                    errors = errors + 1;
                end else begin
                    result_latency = cycle_count -
                                     packet_last_cycle[expected_packet];
                    if (result_latency != RESULT_LATENCY) begin
                        $display("FAIL result latency packet=%0d got=%0d expected=%0d",
                                 expected_packet, result_latency,
                                 RESULT_LATENCY);
                        errors = errors + 1;
                    end
                    if (first_result_cycle < 0)
                        first_result_cycle = cycle_count;
                    // 只有前 8 个 K=1 packet 构成稳态峰值段；K=2 packet
                    // 的 TLAST 晚一拍到达，因此它与前一段结果之间允许有
                    // 一个由 packet 长度自然产生的空档。
                    if ((expected_packet < PEAK_PACKETS) &&
                        (previous_result_cycle >= 0) &&
                        (cycle_count != previous_result_cycle+1)) begin
                        $display("FAIL peak result bubble previous=%0d current=%0d",
                                 previous_result_cycle, cycle_count);
                        errors = errors + 1;
                    end
                    previous_result_cycle = cycle_count;
                    last_result_cycle = cycle_count;
                    check_matrix(expected_packet);
                    expected_packet = expected_packet + 1;
                end
            end
        end
    end

    initial begin : p_test
        integer p;
        integer k;
        integer lane;
        integer wait_cycles;

        for (p = 0; p < PACKET_COUNT; p = p + 1) begin
            packet_last_cycle[p] = -1;
            result_due_cycle[p] = -1;
        end

        repeat (4) @(posedge clk);
        #1 resetn = 1'b1;

        // 连续 8 个 K=1 packet，16 lane 每拍都接收。
        for (p = 0; p < PEAK_PACKETS; p = p + 1) begin
            @(negedge clk);
            s_axis_tvalid = 16'b0;
            s_axis_tuser = 16'b0;
            s_axis_tlast = 16'b0;
            for (lane = 0; lane < TILE_COUNT; lane = lane + 1)
                drive_lane(p, lane, 0);
            @(posedge clk);
            #1;
            packet_last_cycle[p] = cycle_count;
            result_due_cycle[p] = cycle_count + RESULT_LATENCY;
        end

        // 最后一个 packet 为 K=2，两个 beat 之间不插泡；各 lane 形状不同。
        p = PEAK_PACKETS;
        for (k = 0; k < 2; k = k + 1) begin
            @(negedge clk);
            s_axis_tvalid = 16'b0;
            s_axis_tuser = 16'b0;
            s_axis_tlast = 16'b0;
            for (lane = 0; lane < TILE_COUNT; lane = lane + 1)
                drive_lane(p, lane, k);
            @(posedge clk);
            #1;
            if (k == 1) begin
                packet_last_cycle[p] = cycle_count;
                result_due_cycle[p] = cycle_count + RESULT_LATENCY;
            end
        end

        @(negedge clk);
        s_axis_tvalid = 16'b0;
        s_axis_tuser = 16'b0;
        s_axis_tlast = 16'b0;
        a_rows_i = 0;
        b_cols_i = 0;
        active_rows_m1_i = 0;
        active_cols_m1_i = 0;

        wait_cycles = 0;
        while ((expected_packet < PACKET_COUNT) && (wait_cycles < 100)) begin
            @(posedge clk);
            wait_cycles = wait_cycles + 1;
        end
        repeat (3) @(posedge clk);

        if (accepted_beats != PEAK_PACKETS+2) begin
            $display("FAIL accepted_beats=%0d expected=%0d",
                     accepted_beats, PEAK_PACKETS+2);
            errors = errors + 1;
        end
        if (produced_matrices != PACKET_COUNT) begin
            $display("FAIL produced_matrices=%0d expected=%0d",
                     produced_matrices, PACKET_COUNT);
            errors = errors + 1;
        end
        if (expected_packet != PACKET_COUNT) begin
            $display("FAIL expected_packet=%0d expected=%0d",
                     expected_packet, PACKET_COUNT);
            errors = errors + 1;
        end
        if (input_bubbles != 0) begin
            $display("FAIL input_bubbles=%0d expected=0", input_bubbles);
            errors = errors + 1;
        end

        $display("CLUSTER_16X4X4_THROUGHPUT cores=16 tiles=4x4 beats=%0d matrices=%0d input_window=%0d utilization=%0.2f%% interval=1 macs_per_cycle=256 peak_gmac_300m=76.80 fixed_latency=%0d",
                 accepted_beats, produced_matrices,
                 last_input_cycle-first_input_cycle+1,
                 (100.0*accepted_beats)/
                 (last_input_cycle-first_input_cycle+1), RESULT_LATENCY);
        $display("CLUSTER_16X4X4_RESULT_RUN first_cycle=%0d last_cycle=%0d matrices=%0d",
                 first_result_cycle, last_result_cycle, produced_matrices);

        if (errors != 0)
            $fatal(1, "NPU_V13_CLUSTER_16X4X4_TB_FAIL errors=%0d", errors);
        $display("NPU_V13_CLUSTER_16X4X4_TB_PASS");
        $finish;
    end
endmodule
