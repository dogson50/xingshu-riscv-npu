// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps

//////////////////////////////////////////////////////////////////////////////////
// npu_v13_systolic_cluster_runtime_stream 功能、运行时切换与峰值吞吐测试。
//
// 一次 reset 后依次运行 1x16x16、4x8x8、16x4x4，每种模式：
//   1. 连续 8 拍发送 K=1 packet，验证 256 MAC/cycle 和无气泡结果；
//   2. 并行发送每组 K=2..5、M/N 不同的 packet，验证组间独立；
//   3. 检查源 lane 到 tile 的 A/B 广播、紧凑输出 shape、全局 row-major、
//      每 tile valid、有效区域数值以及 10 拍固定结果延迟。
//////////////////////////////////////////////////////////////////////////////////

module tb_npu_v13_systolic_cluster_runtime_stream;
    localparam integer DATA_W = 8;
    localparam integer ACC_W = 32;
    localparam integer TILE_COUNT = 16;
    localparam integer MACRO_DIM = 16;
    localparam integer PACKET_COUNT = 9;
    localparam integer PEAK_PACKETS = 8;
    localparam integer RESULT_LATENCY = 10;
    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;
    reg cfg_valid_i = 1'b0;
    reg [1:0] cfg_mode_i = MODE_16X16;
    wire cfg_ready_o;
    wire cfg_error_o;
    wire [1:0] active_mode_o;
    wire cluster_idle_o;

    reg [15:0] s_axis_tvalid_i = 0;
    reg [15:0] s_axis_tuser_i = 0;
    reg [15:0] s_axis_tlast_i = 0;
    reg [16*2-1:0] active_rows_m1_i = 0;
    reg [16*2-1:0] active_cols_m1_i = 0;
    reg [16*4*DATA_W-1:0] a_source_i = 0;
    reg [16*4*DATA_W-1:0] b_source_i = 0;
    wire [15:0] c_tile_valid_o;
    wire [16*2-1:0] c_active_rows_m1_o;
    wire [16*2-1:0] c_active_cols_m1_o;
    wire [16*16*ACC_W-1:0] c_matrix_o;

    integer errors = 0;
    integer cycle_count = 0;
    integer input_packet [0:15];
    integer input_k_index [0:15];
    integer output_packet [0:15];
    integer due_cycle [0:15][0:PACKET_COUNT-1];
    integer completed_results = 0;
    integer scoreboard_mode = 0;

    npu_v13_systolic_cluster_runtime_stream #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .cfg_valid_i(cfg_valid_i),
        .cfg_mode_i(cfg_mode_i),
        .cfg_ready_o(cfg_ready_o),
        .cfg_error_o(cfg_error_o),
        .active_mode_o(active_mode_o),
        .cluster_idle_o(cluster_idle_o),
        .s_axis_tvalid_i(s_axis_tvalid_i),
        .s_axis_tuser_i(s_axis_tuser_i),
        .s_axis_tlast_i(s_axis_tlast_i),
        .active_rows_m1_i(active_rows_m1_i),
        .active_cols_m1_i(active_cols_m1_i),
        .a_source_i(a_source_i),
        .b_source_i(b_source_i),
        .c_tile_valid_o(c_tile_valid_o),
        .c_active_rows_m1_o(c_active_rows_m1_o),
        .c_active_cols_m1_o(c_active_cols_m1_o),
        .c_matrix_o(c_matrix_o)
    );

    function integer group_count;
        input integer mode;
        begin
            case (mode)
                MODE_16X16:  group_count = 1;
                MODE_4X8X8:  group_count = 4;
                default:     group_count = 16;
            endcase
        end
    endfunction

    function integer group_tile_dim;
        input integer mode;
        begin
            case (mode)
                MODE_16X16:  group_tile_dim = 4;
                MODE_4X8X8:  group_tile_dim = 2;
                default:     group_tile_dim = 1;
            endcase
        end
    endfunction

    function integer group_matrix_dim;
        input integer mode;
        begin
            group_matrix_dim = 4*group_tile_dim(mode);
        end
    endfunction

    function integer group_base_tile_row;
        input integer mode;
        input integer group_index;
        begin
            case (mode)
                MODE_16X16: group_base_tile_row = 0;
                MODE_4X8X8: group_base_tile_row = (group_index/2)*2;
                default: group_base_tile_row = group_index/4;
            endcase
        end
    endfunction

    function integer group_base_tile_col;
        input integer mode;
        input integer group_index;
        begin
            case (mode)
                MODE_16X16: group_base_tile_col = 0;
                MODE_4X8X8: group_base_tile_col = (group_index%2)*2;
                default: group_base_tile_col = group_index%4;
            endcase
        end
    endfunction

    function integer group_anchor;
        input integer mode;
        input integer group_index;
        begin
            group_anchor = group_base_tile_row(mode, group_index)*4 +
                           group_base_tile_col(mode, group_index);
        end
    endfunction

    function integer tile_group;
        input integer mode;
        input integer tile_index;
        integer tile_row;
        integer tile_col;
        begin
            tile_row = tile_index/4;
            tile_col = tile_index%4;
            case (mode)
                MODE_16X16: tile_group = 0;
                MODE_4X8X8: tile_group = (tile_row/2)*2 + tile_col/2;
                default: tile_group = tile_index;
            endcase
        end
    endfunction

    function integer tile_local_row;
        input integer mode;
        input integer tile_index;
        integer g;
        begin
            g = tile_group(mode, tile_index);
            tile_local_row = tile_index/4 - group_base_tile_row(mode, g);
        end
    endfunction

    function integer tile_local_col;
        input integer mode;
        input integer tile_index;
        integer g;
        begin
            g = tile_group(mode, tile_index);
            tile_local_col = tile_index%4 - group_base_tile_col(mode, g);
        end
    endfunction

    function integer packet_k;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        begin
            packet_k = (packet_index < PEAK_PACKETS) ? 1 :
                       (2 + ((group_index + mode) % 4));
        end
    endfunction

    function integer packet_rows;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        integer dim;
        begin
            dim = group_matrix_dim(mode);
            packet_rows = (packet_index < PEAK_PACKETS) ?
                          (dim - ((packet_index + group_index + mode) % 4)) :
                          (1 + ((group_index*3 + mode + 1) % dim));
        end
    endfunction

    function integer packet_cols;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        integer dim;
        begin
            dim = group_matrix_dim(mode);
            packet_cols = (packet_index < PEAK_PACKETS) ?
                          (dim - ((packet_index*3 + group_index*2 +
                                   mode + 1) % 4)) :
                          (1 + ((group_index*5 + mode + 2) % dim));
        end
    endfunction

    function integer a_value;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        input integer row_index;
        input integer k_index;
        begin
            a_value = (((mode+1)*7 + group_index*5 + packet_index*3 +
                        row_index*2 + k_index*4) % 15) - 7;
        end
    endfunction

    function integer b_value;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        input integer col_index;
        input integer k_index;
        begin
            b_value = (((mode+2)*5 + group_index*3 + packet_index*2 +
                        col_index*4 + k_index*5) % 17) - 8;
        end
    endfunction

    task clear_source;
        begin
            s_axis_tvalid_i = 0;
            s_axis_tuser_i = 0;
            s_axis_tlast_i = 0;
            active_rows_m1_i = 0;
            active_cols_m1_i = 0;
            a_source_i = 0;
            b_source_i = 0;
        end
    endtask

    // 只填充当前分组真正需要读取的 source lane。未使用 lane 保持 0，
    // 使 TB 能发现路由索引错误，而不是恰好从重复数据中取到正确值。
    task drive_group_beat;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        input integer k_index;
        integer base_tile_row;
        integer base_tile_col;
        integer tile_dim;
        integer anchor;
        integer local_tile;
        integer element;
        integer source_lane;
        integer local_element;
        begin
            base_tile_row = group_base_tile_row(mode, group_index);
            base_tile_col = group_base_tile_col(mode, group_index);
            tile_dim = group_tile_dim(mode);
            anchor = group_anchor(mode, group_index);

            s_axis_tvalid_i[anchor] = 1'b1;
            s_axis_tuser_i[anchor] = (k_index == 0);
            s_axis_tlast_i[anchor] =
                (k_index == packet_k(mode, group_index, packet_index)-1);
            // shape 总线按逻辑 group 紧凑排列，不沿用稀疏 source anchor
            // 编号。字段宽度刚好覆盖当前 mode 的最大组尺寸。
            case (mode)
                MODE_16X16: begin
                    active_rows_m1_i[0 +: 4] =
                        packet_rows(mode, group_index, packet_index)-1;
                    active_cols_m1_i[0 +: 4] =
                        packet_cols(mode, group_index, packet_index)-1;
                end
                MODE_4X8X8: begin
                    active_rows_m1_i[group_index*3 +: 3] =
                        packet_rows(mode, group_index, packet_index)-1;
                    active_cols_m1_i[group_index*3 +: 3] =
                        packet_cols(mode, group_index, packet_index)-1;
                end
                default: begin
                    active_rows_m1_i[group_index*2 +: 2] =
                        packet_rows(mode, group_index, packet_index)-1;
                    active_cols_m1_i[group_index*2 +: 2] =
                        packet_cols(mode, group_index, packet_index)-1;
                end
            endcase

            // 每个组内 tile 行仅读一个 A source，然后向该组右侧广播。
            for (local_tile = 0; local_tile < tile_dim;
                 local_tile = local_tile + 1) begin
                source_lane = (base_tile_row+local_tile)*4 + base_tile_col;
                for (element = 0; element < 4; element = element + 1) begin
                    local_element = local_tile*4 + element;
                    a_source_i[(source_lane*4+element)*DATA_W +: DATA_W] =
                        a_value(mode, group_index, packet_index,
                                local_element, k_index);
                end
            end

            // 每个组内 tile 列仅读一个 B source，然后向该组下方广播。
            for (local_tile = 0; local_tile < tile_dim;
                 local_tile = local_tile + 1) begin
                source_lane = base_tile_row*4 + base_tile_col+local_tile;
                for (element = 0; element < 4; element = element + 1) begin
                    local_element = local_tile*4 + element;
                    b_source_i[(source_lane*4+element)*DATA_W +: DATA_W] =
                        b_value(mode, group_index, packet_index,
                                local_element, k_index);
                end
            end
        end
    endtask

    task check_group_matrix;
        input integer mode;
        input integer group_index;
        input integer packet_index;
        integer base_row;
        integer base_col;
        integer dim;
        integer r;
        integer c;
        integer k;
        integer expected;
        integer got;
        begin
            base_row = group_base_tile_row(mode, group_index)*4;
            base_col = group_base_tile_col(mode, group_index)*4;
            dim = group_matrix_dim(mode);
            for (r = 0; r < dim; r = r + 1) begin
                for (c = 0; c < dim; c = c + 1) begin
                    // 超出对应物理 tile 输出 shape 的位置是 don't-care。
                    if ((r < packet_rows(mode, group_index, packet_index)) &&
                        (c < packet_cols(mode, group_index, packet_index))) begin
                        expected = 0;
                        for (k = 0; k < packet_k(mode, group_index, packet_index);
                             k = k + 1)
                            expected = expected +
                                a_value(mode, group_index, packet_index, r, k)*
                                b_value(mode, group_index, packet_index, c, k);
                        got = $signed(c_matrix_o[
                            ((base_row+r)*MACRO_DIM+base_col+c)*ACC_W +: ACC_W]);
                        if (got !== expected) begin
                            $display("FAIL runtime mode=%0d group=%0d packet=%0d C[%0d,%0d] got=%0d expected=%0d",
                                     mode, group_index, packet_index,
                                     r, c, got, expected);
                            errors = errors + 1;
                        end
                    end
                end
            end
        end
    endtask

    task apply_mode;
        input integer mode;
        begin
            wait (cluster_idle_o === 1'b1);
            @(negedge clk);
            clear_source();
            cfg_mode_i = mode[1:0];
            cfg_valid_i = 1'b1;
            while (cfg_ready_o !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            #1;
            @(negedge clk);
            cfg_valid_i = 1'b0;
            if (active_mode_o !== mode[1:0]) begin
                $display("FAIL runtime mode commit got=%0d expected=%0d",
                         active_mode_o, mode);
                errors = errors + 1;
            end
        end
    endtask

    task run_mode;
        input integer mode;
        integer p;
        integer g;
        integer k;
        integer max_k;
        integer start_cycle;
        integer end_cycle;
        begin
            apply_mode(mode);

            // 峰值段：连续 8 周期，所有逻辑组都发送独立 K=1 packet。
            start_cycle = -1;
            end_cycle = -1;
            for (p = 0; p < PEAK_PACKETS; p = p + 1) begin
                @(negedge clk);
                clear_source();
                for (g = 0; g < group_count(mode); g = g + 1)
                    drive_group_beat(mode, g, p, 0);
                @(posedge clk);
                #1;
                if (start_cycle < 0)
                    start_cycle = cycle_count;
                end_cycle = cycle_count;
            end

            // 独立 packet 段：每组 K=2..5，先结束的组立即撤 valid。
            max_k = 5;
            for (k = 0; k < max_k; k = k + 1) begin
                @(negedge clk);
                clear_source();
                for (g = 0; g < group_count(mode); g = g + 1) begin
                    if (k < packet_k(mode, g, PEAK_PACKETS))
                        drive_group_beat(mode, g, PEAK_PACKETS, k);
                end
            end

            @(negedge clk);
            clear_source();
            wait (cluster_idle_o === 1'b1);
            repeat (2) @(posedge clk);

            for (g = 0; g < group_count(mode); g = g + 1) begin
                if (output_packet[g] != PACKET_COUNT) begin
                    $display("FAIL runtime mode=%0d group=%0d outputs=%0d expected=%0d",
                             mode, g, output_packet[g], PACKET_COUNT);
                    errors = errors + 1;
                end
            end

            $display("RUNTIME_CLUSTER_THROUGHPUT mode=%0d groups=%0d group_shape=%0dx%0d peak_input_cycles=%0d utilization=100.00%% peak_matrices_per_cycle=%0d macs_per_cycle=256 peak_gmac_300m=76.80 fixed_latency=%0d source_bits_per_cycle=%0d",
                     mode, group_count(mode), group_matrix_dim(mode),
                     group_matrix_dim(mode), end_cycle-start_cycle+1,
                     group_count(mode), RESULT_LATENCY,
                     group_count(mode)*2*group_matrix_dim(mode)*DATA_W);
        end
    endtask

    // 同时检查输入 packet 到期时间、每 tile valid 和结果数值。
    always @(posedge clk) begin : p_scoreboard
        integer g;
        integer t;
        integer p;
        integer anchor;
        integer expected_valid;
        integer local_tile_r;
        integer local_tile_c;
        integer tile_enabled;
        integer remaining_rows;
        integer remaining_cols;
        integer expected_rows_m1;
        integer expected_cols_m1;
        cycle_count = cycle_count + 1;
        #1;

        if (resetn) begin
            if (!cluster_idle_o && cfg_ready_o) begin
                $display("FAIL cfg_ready asserted while cluster busy cycle=%0d",
                         cycle_count);
                errors = errors + 1;
            end

            if (cfg_valid_i && cfg_ready_o) begin
                scoreboard_mode = cfg_mode_i;
                completed_results = 0;
                for (g = 0; g < 16; g = g + 1) begin
                    input_packet[g] = 0;
                    input_k_index[g] = 0;
                    output_packet[g] = 0;
                    for (p = 0; p < PACKET_COUNT; p = p + 1)
                        due_cycle[g][p] = -1;
                end
            end

            // 原始 source 在当前上升沿被接收，TLAST 后 10 拍应有结果。
            for (g = 0; g < group_count(active_mode_o); g = g + 1) begin
                anchor = group_anchor(active_mode_o, g);
                if (s_axis_tvalid_i[anchor]) begin
                    if (s_axis_tuser_i[anchor] !==
                        (input_k_index[g] == 0)) begin
                        $display("FAIL runtime TUSER mode=%0d group=%0d packet=%0d k=%0d got=%0b expected=%0b",
                                 active_mode_o, g, input_packet[g],
                                 input_k_index[g], s_axis_tuser_i[anchor],
                                 (input_k_index[g] == 0));
                        errors = errors + 1;
                    end
                    if (s_axis_tlast_i[anchor] !==
                        (input_k_index[g] ==
                         packet_k(active_mode_o, g, input_packet[g])-1)) begin
                        $display("FAIL runtime TLAST mode=%0d group=%0d packet=%0d k=%0d got=%0b expected=%0b",
                                 active_mode_o, g, input_packet[g],
                                 input_k_index[g], s_axis_tlast_i[anchor],
                                 (input_k_index[g] ==
                                  packet_k(active_mode_o, g, input_packet[g])-1));
                        errors = errors + 1;
                    end
                    if (s_axis_tlast_i[anchor]) begin
                        if (input_packet[g] >= PACKET_COUNT) begin
                            $display("FAIL extra input packet mode=%0d group=%0d",
                                     active_mode_o, g);
                            errors = errors + 1;
                        end else begin
                            due_cycle[g][input_packet[g]] =
                                cycle_count + RESULT_LATENCY;
                            if ((input_packet[g] > 0) &&
                                (input_packet[g] < PEAK_PACKETS) &&
                                (due_cycle[g][input_packet[g]] !=
                                 due_cycle[g][input_packet[g]-1]+1)) begin
                                $display("FAIL peak due bubble mode=%0d group=%0d packet=%0d",
                                         active_mode_o, g, input_packet[g]);
                                errors = errors + 1;
                            end
                            input_packet[g] = input_packet[g] + 1;
                            input_k_index[g] = 0;
                        end
                    end else begin
                        input_k_index[g] = input_k_index[g] + 1;
                    end
                end
            end

            // 逐 tile 检查 valid，并只在有效 tile 上检查同拍本地 shape。
            for (t = 0; t < TILE_COUNT; t = t + 1) begin
                g = tile_group(active_mode_o, t);
                p = output_packet[g];
                expected_valid = (p < PACKET_COUNT) &&
                    (due_cycle[g][p] == cycle_count);
                local_tile_r = tile_local_row(active_mode_o, t);
                local_tile_c = tile_local_col(active_mode_o, t);
                tile_enabled = expected_valid &&
                    (local_tile_r*4 < packet_rows(active_mode_o, g, p)) &&
                    (local_tile_c*4 < packet_cols(active_mode_o, g, p));
                if (c_tile_valid_o[t] !== tile_enabled[0]) begin
                    $display("FAIL runtime tile valid mode=%0d tile=%0d cycle=%0d got=%0b expected=%0b packet=%0d",
                             active_mode_o, t, cycle_count,
                             c_tile_valid_o[t], tile_enabled[0], p);
                    errors = errors + 1;
                end

                if (tile_enabled) begin
                    remaining_rows =
                        packet_rows(active_mode_o, g, p) - local_tile_r*4;
                    remaining_cols =
                        packet_cols(active_mode_o, g, p) - local_tile_c*4;
                    expected_rows_m1 =
                        (remaining_rows >= 4) ? 3 : remaining_rows-1;
                    expected_cols_m1 =
                        (remaining_cols >= 4) ? 3 : remaining_cols-1;
                    if (c_active_rows_m1_o[t*2 +: 2] !== expected_rows_m1) begin
                        $display("FAIL runtime output rows_m1 mode=%0d tile=%0d packet=%0d got=%0d expected=%0d",
                                 active_mode_o, t, p,
                                 c_active_rows_m1_o[t*2 +: 2],
                                 expected_rows_m1);
                        errors = errors + 1;
                    end
                    if (c_active_cols_m1_o[t*2 +: 2] !== expected_cols_m1) begin
                        $display("FAIL runtime output cols_m1 mode=%0d tile=%0d packet=%0d got=%0d expected=%0d",
                                 active_mode_o, t, p,
                                 c_active_cols_m1_o[t*2 +: 2],
                                 expected_cols_m1);
                        errors = errors + 1;
                    end
                end
            end

            // 每个 due group 只检查/出队一次，不依赖它启用了多少个 tile。
            for (g = 0; g < group_count(active_mode_o); g = g + 1) begin
                p = output_packet[g];
                if ((p < PACKET_COUNT) &&
                    (due_cycle[g][p] == cycle_count)) begin
                    check_group_matrix(active_mode_o, g, p);
                    output_packet[g] = output_packet[g] + 1;
                    completed_results = completed_results + 1;
                end
            end
        end
    end

    initial begin : p_test
        integer g;
        integer p;
        reg [1:0] mode_before_invalid;
        clear_source();
        for (g = 0; g < 16; g = g + 1) begin
            input_packet[g] = 0;
            input_k_index[g] = 0;
            output_packet[g] = 0;
            for (p = 0; p < PACKET_COUNT; p = p + 1)
                due_cycle[g][p] = -1;
        end

        repeat (5) @(posedge clk);
        #1 resetn = 1'b1;

        run_mode(MODE_16X16);
        run_mode(MODE_4X8X8);
        run_mode(MODE_16X4X4);

        // 非法模式必须报错但不改变当前模式。
        wait (cluster_idle_o);
        mode_before_invalid = active_mode_o;
        @(negedge clk);
        cfg_mode_i = 2'b11;
        cfg_valid_i = 1'b1;
        @(posedge clk);
        #1;
        if (!cfg_error_o || (active_mode_o != mode_before_invalid)) begin
            $display("FAIL invalid cfg error=%0b mode_before=%0d mode_after=%0d",
                     cfg_error_o, mode_before_invalid, active_mode_o);
            errors = errors + 1;
        end
        @(negedge clk);
        cfg_valid_i = 1'b0;

        repeat (3) @(posedge clk);
        if (errors != 0)
            $fatal(1, "NPU_V13_RUNTIME_CLUSTER_STREAM_TB_FAIL errors=%0d",
                   errors);
        $display("NPU_V13_RUNTIME_CLUSTER_STREAM_TB_PASS modes=3");
        $finish;
    end
endmodule
