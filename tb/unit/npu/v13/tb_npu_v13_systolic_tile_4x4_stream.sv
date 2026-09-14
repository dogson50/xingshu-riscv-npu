// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps

// npu_v13_systolic_tile_4x4_stream 连续流饱和测试。
//
// 整段输入跨 packet 保持 TVALID=1，验证无 ready 接口能做到每拍接收一个
// beat。所有 packet 都令 K>=2，使 TUSER（首 beat）和 TLAST（尾 beat）在
// 波形中均表现为有低电平间隔的单周期脉冲，同时输入数据流仍然没有空拍。
// 注意：若连续发送 K=1 packet，同一 beat 必须同时置 TUSER/TLAST，相邻包的
// 单拍事件会在电平波形上连成高电平；要插入低电平就必然牺牲连续吞吐。
module tb_npu_v13_systolic_tile_4x4_stream;
    localparam integer DATA_W = 8;
    localparam integer ACC_W = 32;
    localparam integer PACKET_COUNT = 10;
    localparam integer TOTAL_BEATS = 31;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;
    reg [1:0] active_rows_i = 2'b11;
    reg [1:0] active_cols_i = 2'b11;
    reg s_axis_tvalid = 1'b0;
    reg [63:0] s_axis_tdata = 64'd0;
    reg s_axis_tlast = 1'b0;
    reg s_axis_tuser = 1'b0;
    wire c_valid_o;
    wire [1:0] c_active_rows_m1_o;
    wire [1:0] c_active_cols_m1_o;
    wire [511:0] c_matrix_o;

    integer errors = 0;
    integer cycle_count = 0;
    integer accepted_beats = 0;
    integer produced_matrices = 0;
    integer expected_packet = 0;
    integer first_fire_cycle = -1;
    integer final_fire_cycle = -1;
    integer previous_fire_cycle = -1;
    integer bubble_count = 0;
    integer first_k2_result_cycle = -1;
    integer previous_k2_result_cycle = -1;
    integer fixed_result_latency = -1;
    integer input_packet_index = 0;
    integer input_k_index = 0;
    integer packet_last_cycle [0:PACKET_COUNT-1];
    reg source_saturating = 1'b0;
    reg previous_tuser = 1'b0;
    reg previous_tlast = 1'b0;

    npu_v13_systolic_tile_4x4_stream dut (
        .clk(clk), .resetn(resetn),
        .active_rows_i(active_rows_i), .active_cols_i(active_cols_i),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tdata(s_axis_tdata), .s_axis_tlast(s_axis_tlast),
        .s_axis_tuser(s_axis_tuser), .c_valid_o(c_valid_o),
        .c_active_rows_m1_o(c_active_rows_m1_o),
        .c_active_cols_m1_o(c_active_cols_m1_o),
        .c_matrix_o(c_matrix_o)
    );

    function integer packet_rows;
        input integer p;
        begin case (p) 0: packet_rows=1; 1: packet_rows=2; 2: packet_rows=3; 3: packet_rows=4; 4: packet_rows=1; 5: packet_rows=2; 6: packet_rows=4; 7: packet_rows=3; 8: packet_rows=4; default: packet_rows=2; endcase end
    endfunction
    function integer packet_cols;
        input integer p;
        begin case (p) 0: packet_cols=1; 1: packet_cols=2; 2: packet_cols=3; 3: packet_cols=4; 4: packet_cols=4; 5: packet_cols=3; 6: packet_cols=2; 7: packet_cols=4; 8: packet_cols=4; default: packet_cols=3; endcase end
    endfunction
    function integer packet_k_count;
        input integer p;
        begin case (p) 8: packet_k_count=3; 9: packet_k_count=12; default: packet_k_count=2; endcase end
    endfunction
    function integer a_value;
        input integer p; input integer r; input integer k;
        begin a_value = ((p+1)*(r+2) + 3*k) - 9; end
    endfunction
    function integer b_value;
        input integer p; input integer c; input integer k;
        begin b_value = ((p+2)*(c+1) - 2*k) - 7; end
    endfunction
    function [3:0] count_to_mask;
        input integer count_v;
        begin case (count_v) 1: count_to_mask=4'b0001; 2: count_to_mask=4'b0011; 3: count_to_mask=4'b0111; default: count_to_mask=4'b1111; endcase end
    endfunction

    task drive_packets;
        integer p; integer k; integer r; integer c;
        begin
            source_saturating = 1'b1;
            for (p=0; p<PACKET_COUNT; p=p+1) begin
                active_rows_i = packet_rows(p)-1;
                active_cols_i = packet_cols(p)-1;
                for (k=0; k<packet_k_count(p); k=k+1) begin
                    @(negedge clk);
                    for (r=0; r<4; r=r+1)
                        s_axis_tdata[r*DATA_W +: DATA_W] = a_value(p,r,k);
                    for (c=0; c<4; c=c+1)
                        s_axis_tdata[(4+c)*DATA_W +: DATA_W] = b_value(p,c,k);
                    // TUSER/TLAST 都是事件脉冲，而不是需要跨多拍保持的状态。
                    // 先给默认低电平，再只在精确的首/尾 beat 上各置位一拍。
                    s_axis_tuser = 1'b0;
                    s_axis_tlast = 1'b0;
                    if (k == 0)
                        s_axis_tuser = 1'b1;
                    if (k == packet_k_count(p)-1)
                        s_axis_tlast = 1'b1;
                    s_axis_tvalid = 1'b1;
                    @(posedge clk);
                    #1;
                end
            end
            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tlast = 1'b0;
            s_axis_tuser = 1'b0;
            source_saturating = 1'b0;
        end
    endtask

    task check_result;
        input integer p;
        integer r; integer c; integer k; integer expected; integer got;
        begin
            if (!c_valid_o) begin
                $display("FAIL missing result packet=%0d cycle=%0d", p, cycle_count);
                errors = errors + 1;
            end else begin
                if (c_active_rows_m1_o !== packet_rows(p)-1) begin
                    $display("FAIL packet=%0d output rows_m1 got=%0d expected=%0d",
                             p, c_active_rows_m1_o, packet_rows(p)-1);
                    errors = errors + 1;
                end
                if (c_active_cols_m1_o !== packet_cols(p)-1) begin
                    $display("FAIL packet=%0d output cols_m1 got=%0d expected=%0d",
                             p, c_active_cols_m1_o, packet_cols(p)-1);
                    errors = errors + 1;
                end
                for (r=0; r<4; r=r+1) begin
                    for (c=0; c<4; c=c+1) begin
                        // 未激活元素是 don't-care；collector 依据同拍 shape
                        // 只读取左上有效区域，因此这里只检查协议可观察元素。
                        if (r < packet_rows(p) && c < packet_cols(p)) begin
                            expected = 0;
                            for (k=0; k<packet_k_count(p); k=k+1)
                                expected = expected + a_value(p,r,k)*b_value(p,c,k);
                            got = $signed(c_matrix_o[(r*4+c)*ACC_W +: ACC_W]);
                            if (got !== expected) begin
                                $display("FAIL packet=%0d C[%0d,%0d] got=%0d expected=%0d",p,r,c,got,expected);
                                errors = errors + 1;
                            end
                        end
                    end
                end
                produced_matrices = produced_matrices + 1;
            end
        end
    endtask

    always @(posedge clk) begin
        integer result_latency;
        cycle_count = cycle_count + 1;
        if (resetn) begin
            // c_matrix_o 只在 c_valid_o=1 时属于协议状态。结果/掩码数据链
            // 不复位，故复位释放后的无效窗口允许保留旧值或 X；下面仍会
            // 严格检查伪 valid、首个有效结果、尾块清零和固定延迟。
            if (source_saturating && !s_axis_tvalid) begin
                $display("FAIL source dropped TVALID cycle=%0d",cycle_count);
                errors = errors + 1;
            end
            if (s_axis_tvalid) begin
                accepted_beats = accepted_beats + 1;
                if (first_fire_cycle < 0) first_fire_cycle = cycle_count;
                final_fire_cycle = cycle_count;
                if (previous_fire_cycle >= 0 && cycle_count != previous_fire_cycle+1) begin
                    $display("FAIL input bubble previous=%0d current=%0d",previous_fire_cycle,cycle_count);
                    bubble_count = bubble_count + 1;
                    errors = errors + 1;
                end
                previous_fire_cycle = cycle_count;

                // 连续流版协议：每个 packet 必须显式给出一个首拍 TUSER 和
                // 一个尾拍 TLAST。本 TB 的 packet 均为 K>=2，因此两个信号
                // 各自都不得连续两个采样沿为高。
                if (s_axis_tuser !== (input_k_index == 0)) begin
                    $display("FAIL TUSER placement packet=%0d k=%0d got=%0b expected=%0b",
                             input_packet_index, input_k_index, s_axis_tuser,
                             (input_k_index == 0));
                    errors = errors + 1;
                end
                if (s_axis_tlast !==
                    (input_k_index == packet_k_count(input_packet_index)-1)) begin
                    $display("FAIL TLAST placement packet=%0d k=%0d got=%0b expected=%0b",
                             input_packet_index, input_k_index, s_axis_tlast,
                             (input_k_index == packet_k_count(input_packet_index)-1));
                    errors = errors + 1;
                end
                if (s_axis_tuser && previous_tuser) begin
                    $display("FAIL TUSER wider than one cycle cycle=%0d", cycle_count);
                    errors = errors + 1;
                end
                if (s_axis_tlast && previous_tlast) begin
                    $display("FAIL TLAST wider than one cycle cycle=%0d", cycle_count);
                    errors = errors + 1;
                end
                if (s_axis_tlast) begin
                    packet_last_cycle[input_packet_index] = cycle_count;
                    input_packet_index = input_packet_index + 1;
                    input_k_index = 0;
                end else begin
                    input_k_index = input_k_index + 1;
                end
            end
            previous_tuser = s_axis_tvalid && s_axis_tuser;
            previous_tlast = s_axis_tvalid && s_axis_tlast;
            if (c_valid_o) begin
                if (expected_packet >= input_packet_index) begin
                    $display("FAIL result without completed input packet cycle=%0d",cycle_count);
                    errors = errors + 1;
                end else begin
                    result_latency = cycle_count - packet_last_cycle[expected_packet];
                    if (fixed_result_latency < 0)
                        fixed_result_latency = result_latency;
                    else if (result_latency != fixed_result_latency) begin
                        $display("FAIL variable result latency packet=%0d got=%0d expected=%0d",
                                 expected_packet,result_latency,fixed_result_latency);
                        errors = errors + 1;
                    end
                end
                if (expected_packet < 8) begin
                    if (first_k2_result_cycle < 0)
                        first_k2_result_cycle = cycle_count;
                    if (previous_k2_result_cycle >= 0 &&
                        cycle_count != previous_k2_result_cycle + 2) begin
                        $display("FAIL K=2 result interval previous=%0d current=%0d",
                                 previous_k2_result_cycle, cycle_count);
                        errors = errors + 1;
                    end
                    previous_k2_result_cycle = cycle_count;
                end
                check_result(expected_packet);
                expected_packet = expected_packet + 1;
            end
        end
    end

    initial begin
        integer wait_cycles;
        repeat(3) @(posedge clk);
        #1;
        resetn = 1'b1;
        fork
            drive_packets();
            begin
                wait_cycles = 0;
                while ((expected_packet < PACKET_COUNT) && wait_cycles < 300) begin
                    @(posedge clk);
                    wait_cycles = wait_cycles + 1;
                end
            end
        join
        repeat(4) @(posedge clk);
        if (accepted_beats != TOTAL_BEATS) begin
            $display("FAIL accepted_beats=%0d expected=%0d",accepted_beats,TOTAL_BEATS);
            errors = errors + 1;
        end
        if (produced_matrices != PACKET_COUNT) begin
            $display("FAIL produced_matrices=%0d expected=%0d",produced_matrices,PACKET_COUNT);
            errors = errors + 1;
        end
        $display("STREAM_THROUGHPUT beats=%0d matrices=%0d input_window=%0d cycles utilization=%0.2f%% bubbles=%0d fixed_result_latency=%0d",accepted_beats,produced_matrices,final_fire_cycle-first_fire_cycle+1,(100.0*accepted_beats)/(final_fire_cycle-first_fire_cycle+1),bubble_count,fixed_result_latency);
        $display("STREAM_K2_RESULT_RUN first_cycle=%0d last_cycle=%0d count=8 interval=2",
                 first_k2_result_cycle, previous_k2_result_cycle);
        if (errors != 0) $fatal(1,"NPU_V13_TILE_STREAM_TB_FAIL errors=%0d",errors);
        $display("NPU_V13_TILE_STREAM_TB_PASS");
        $finish;
    end
endmodule
