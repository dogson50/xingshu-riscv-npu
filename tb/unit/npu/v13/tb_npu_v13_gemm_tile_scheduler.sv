// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

module tb_npu_v13_gemm_tile_scheduler;
    localparam integer DIM_W = 16;
    localparam integer TAG_W = 8;
    localparam integer MAX_DIM = 128;
    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;

    reg clk;
    reg resetn;
    reg cmd_valid_i;
    wire cmd_ready_o;
    reg [DIM_W-1:0] cmd_m_i;
    reg [DIM_W-1:0] cmd_n_i;
    reg [DIM_W-1:0] cmd_k_i;
    reg [1:0] cmd_mode_i;
    reg [2:0] cmd_layout_i;
    reg [TAG_W-1:0] cmd_tag_i;
    wire cmd_error_o;
    wire tile_batch_valid_o;
    reg tile_batch_ready_i;
    wire [DIM_W-1:0] tile_batch_m_o;
    wire [DIM_W-1:0] tile_batch_n_o;
    wire [DIM_W-1:0] tile_batch_k_o;
    wire [DIM_W-1:0] tile_batch_m_base_o;
    wire [DIM_W-1:0] tile_batch_n_base_o;
    wire [1:0] tile_batch_cluster_mode_o;
    wire [2:0] tile_batch_layout_o;
    wire tile_batch_cmd_first_o;
    wire tile_batch_cmd_last_o;
    wire [TAG_W-1:0] tile_batch_tag_o;
    wire scheduler_busy_o;
    wire schedule_done_o;
    wire [TAG_W-1:0] schedule_done_tag_o;

    integer errors;
    integer cycle_count;
    integer coverage [0:MAX_DIM-1][0:MAX_DIM-1];

    npu_v13_gemm_tile_scheduler #(
        .DIM_W(DIM_W),
        .TAG_W(TAG_W)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .cmd_m_i(cmd_m_i),
        .cmd_n_i(cmd_n_i),
        .cmd_k_i(cmd_k_i),
        .cmd_mode_i(cmd_mode_i),
        .cmd_layout_i(cmd_layout_i),
        .cmd_tag_i(cmd_tag_i),
        .cmd_error_o(cmd_error_o),
        .tile_batch_valid_o(tile_batch_valid_o),
        .tile_batch_ready_i(tile_batch_ready_i),
        .tile_batch_m_o(tile_batch_m_o),
        .tile_batch_n_o(tile_batch_n_o),
        .tile_batch_k_o(tile_batch_k_o),
        .tile_batch_m_base_o(tile_batch_m_base_o),
        .tile_batch_n_base_o(tile_batch_n_base_o),
        .tile_batch_cluster_mode_o(tile_batch_cluster_mode_o),
        .tile_batch_layout_o(tile_batch_layout_o),
        .tile_batch_cmd_first_o(tile_batch_cmd_first_o),
        .tile_batch_cmd_last_o(tile_batch_cmd_last_o),
        .tile_batch_tag_o(tile_batch_tag_o),
        .scheduler_busy_o(scheduler_busy_o),
        .schedule_done_o(schedule_done_o),
        .schedule_done_tag_o(schedule_done_tag_o)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cycle_count = cycle_count + 1;

    task automatic geometry_t;
        input [1:0] mode;
        input [2:0] layout;
        output integer block_elements;
        output integer group_count;
        output integer group_rows;
        output integer group_cols;
        output integer step_m;
        output integer step_n;
        begin
            case (mode)
                MODE_16X16: begin
                    block_elements = 16;
                    group_count = 1;
                    group_rows = 1;
                    group_cols = 1;
                end
                MODE_4X8X8: begin
                    block_elements = 8;
                    group_count = 4;
                    case (layout)
                        0: begin group_rows = 1; group_cols = 4; end
                        1: begin group_rows = 2; group_cols = 2; end
                        default: begin group_rows = 4; group_cols = 1; end
                    endcase
                end
                default: begin
                    block_elements = 4;
                    group_count = 16;
                    case (layout)
                        0: begin group_rows = 1; group_cols = 16; end
                        1: begin group_rows = 2; group_cols = 8; end
                        2: begin group_rows = 4; group_cols = 4; end
                        3: begin group_rows = 8; group_cols = 2; end
                        default: begin group_rows = 16; group_cols = 1; end
                    endcase
                end
            endcase
            step_m = block_elements*group_rows;
            step_n = block_elements*group_cols;
        end
    endtask

    task automatic clear_coverage_t;
        input integer m_dim;
        input integer n_dim;
        integer r;
        integer c;
        begin
            for (r = 0; r < m_dim; r = r + 1)
                for (c = 0; c < n_dim; c = c + 1)
                    coverage[r][c] = 0;
        end
    endtask

    task automatic run_command_t;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input [1:0] mode;
        input [2:0] layout;
        input [TAG_W-1:0] tag_value;
        input integer enable_stalls;
        input integer expect_full_groups;

        integer block_elements;
        integer group_count;
        integer group_rows;
        integer group_cols;
        integer step_m;
        integer step_n;
        integer expected_base_m;
        integer expected_base_n;
        integer expected_batches;
        integer tile_batch_count;
        integer valid_group_count;
        integer group_r;
        integer group_c;
        integer group_m;
        integer group_n;
        integer active_rows;
        integer active_cols;
        integer r;
        integer c;
        integer expected_last;
        integer loop_count;
        integer fire_now;
        integer previous_fire_cycle;
        integer stall_active;
        reg [DIM_W-1:0] stalled_m;
        reg [DIM_W-1:0] stalled_n;
        reg [DIM_W-1:0] stalled_k;
        reg [DIM_W-1:0] stalled_m_base;
        reg [DIM_W-1:0] stalled_n_base;
        reg [1:0] stalled_mode;
        reg [2:0] stalled_layout;
        reg stalled_first;
        reg stalled_last;
        reg [TAG_W-1:0] stalled_tag;
        begin
            geometry_t(mode, layout, block_elements, group_count,
                       group_rows, group_cols, step_m, step_n);
            clear_coverage_t(m_dim, n_dim);
            expected_base_m = 0;
            expected_base_n = 0;
            expected_batches = ((m_dim + step_m - 1) / step_m) *
                               ((n_dim + step_n - 1) / step_n);
            tile_batch_count = 0;
            valid_group_count = 0;
            loop_count = 0;
            previous_fire_cycle = -1;
            stall_active = 0;

            @(negedge clk);
            while (!cmd_ready_o) @(negedge clk);
            cmd_m_i = m_dim;
            cmd_n_i = n_dim;
            cmd_k_i = k_dim;
            cmd_mode_i = mode;
            cmd_layout_i = layout;
            cmd_tag_i = tag_value;
            cmd_valid_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cmd_valid_i = 1'b0;

            while (tile_batch_count < expected_batches) begin
                if (enable_stalls &&
                    (((loop_count % 7) == 1) || ((loop_count % 11) == 4)))
                    tile_batch_ready_i = 1'b0;
                else
                    tile_batch_ready_i = 1'b1;
                #1;

                if (tile_batch_valid_o && !tile_batch_ready_i) begin
                    if (!stall_active) begin
                        stalled_m = tile_batch_m_o;
                        stalled_n = tile_batch_n_o;
                        stalled_k = tile_batch_k_o;
                        stalled_m_base = tile_batch_m_base_o;
                        stalled_n_base = tile_batch_n_base_o;
                        stalled_mode = tile_batch_cluster_mode_o;
                        stalled_layout = tile_batch_layout_o;
                        stalled_first = tile_batch_cmd_first_o;
                        stalled_last = tile_batch_cmd_last_o;
                        stalled_tag = tile_batch_tag_o;
                    end else if ((tile_batch_m_o !== stalled_m) ||
                                 (tile_batch_n_o !== stalled_n) ||
                                 (tile_batch_k_o !== stalled_k) ||
                                 (tile_batch_m_base_o !== stalled_m_base) ||
                                 (tile_batch_n_base_o !== stalled_n_base) ||
                                 (tile_batch_cluster_mode_o !== stalled_mode) ||
                                 (tile_batch_layout_o !== stalled_layout) ||
                                 (tile_batch_cmd_first_o !== stalled_first) ||
                                 (tile_batch_cmd_last_o !== stalled_last) ||
                                 (tile_batch_tag_o !== stalled_tag)) begin
                        $display("FAIL scheduler descriptor changed under backpressure tag=%0d cycle=%0d",
                                 tag_value, cycle_count);
                        errors = errors + 1;
                    end
                    stall_active = 1;
                end else begin
                    stall_active = 0;
                end

                fire_now = tile_batch_valid_o && tile_batch_ready_i;
                if (fire_now) begin
                    expected_last = ((expected_base_m + step_m) >= m_dim) &&
                                    ((expected_base_n + step_n) >= n_dim);
                    if ((tile_batch_m_o !== m_dim) ||
                        (tile_batch_n_o !== n_dim) ||
                        (tile_batch_k_o !== k_dim) ||
                        (tile_batch_m_base_o !== expected_base_m) ||
                        (tile_batch_n_base_o !== expected_base_n) ||
                        (tile_batch_cluster_mode_o !== mode) ||
                        (tile_batch_layout_o !== layout) ||
                        (tile_batch_cmd_first_o !== (tile_batch_count == 0)) ||
                        (tile_batch_cmd_last_o !== expected_last) ||
                        (tile_batch_tag_o !== tag_value)) begin
                        $display("FAIL scheduler descriptor tag=%0d tile_batch=%0d got_base=(%0d,%0d) expected_base=(%0d,%0d) first=%0b last=%0b expected_last=%0d",
                                 tag_value, tile_batch_count,
                                 tile_batch_m_base_o, tile_batch_n_base_o,
                                 expected_base_m, expected_base_n,
                                 tile_batch_cmd_first_o,
                                 tile_batch_cmd_last_o, expected_last);
                        errors = errors + 1;
                    end

                    // Reconstruct every logical group from the compact tile batch.
                    // This proves that the batch sequence covers C exactly once.
                    for (group_r = 0; group_r < group_rows;
                         group_r = group_r + 1)
                        for (group_c = 0; group_c < group_cols;
                             group_c = group_c + 1) begin
                            group_m = expected_base_m + group_r*block_elements;
                            group_n = expected_base_n + group_c*block_elements;
                            if ((group_m < m_dim) && (group_n < n_dim)) begin
                                active_rows = ((m_dim-group_m) >= block_elements) ?
                                              block_elements : (m_dim-group_m);
                                active_cols = ((n_dim-group_n) >= block_elements) ?
                                              block_elements : (n_dim-group_n);
                                valid_group_count = valid_group_count + 1;
                                for (r = group_m; r < group_m+active_rows;
                                     r = r + 1)
                                    for (c = group_n; c < group_n+active_cols;
                                         c = c + 1) begin
                                        if (coverage[r][c] != 0) begin
                                            $display("FAIL scheduler overlap tag=%0d C[%0d,%0d] count=%0d",
                                                     tag_value, r, c,
                                                     coverage[r][c]);
                                            errors = errors + 1;
                                        end
                                        coverage[r][c] = coverage[r][c] + 1;
                                    end
                            end
                        end

                    tile_batch_count = tile_batch_count + 1;
                    if (!expected_last) begin
                        if ((expected_base_n + step_n) >= n_dim) begin
                            expected_base_n = 0;
                            expected_base_m = expected_base_m + step_m;
                        end else begin
                            expected_base_n = expected_base_n + step_n;
                        end
                    end
                end

                @(posedge clk);
                #1;
                if (fire_now) begin
                    if (!enable_stalls && (previous_fire_cycle >= 0) &&
                        (cycle_count != previous_fire_cycle + 1)) begin
                        $display("FAIL scheduler tile batch bubble tag=%0d previous=%0d current=%0d",
                                 tag_value, previous_fire_cycle, cycle_count);
                        errors = errors + 1;
                    end
                    previous_fire_cycle = cycle_count;
                end
                @(negedge clk);
                loop_count = loop_count + 1;
            end

            tile_batch_ready_i = 1'b1;
            #1;
            if (!schedule_done_o ||
                (schedule_done_tag_o !== tag_value)) begin
                $display("FAIL scheduler done tag=%0d got_done=%0b got_tag=%0d",
                         tag_value, schedule_done_o, schedule_done_tag_o);
                errors = errors + 1;
            end
            for (r = 0; r < m_dim; r = r + 1)
                for (c = 0; c < n_dim; c = c + 1)
                    if (coverage[r][c] != 1) begin
                        $display("FAIL scheduler coverage tag=%0d C[%0d,%0d] count=%0d",
                                 tag_value, r, c, coverage[r][c]);
                        errors = errors + 1;
                    end

            if (tile_batch_count != expected_batches) begin
                $display("FAIL scheduler tile batch count tag=%0d got=%0d expected=%0d",
                         tag_value, tile_batch_count, expected_batches);
                errors = errors + 1;
            end
            if (expect_full_groups &&
                (valid_group_count != expected_batches*group_count)) begin
                $display("FAIL scheduler full utilization tag=%0d valid_groups=%0d capacity=%0d",
                         tag_value, valid_group_count,
                         expected_batches*group_count);
                errors = errors + 1;
            end
            $display("SCHEDULER_THROUGHPUT tag=%0d mode=%0d layout=%0d tile_batches=%0d groups_valid=%0d capacity=%0d utilization=%0.2f%% stalls=%0d II_no_stall=1",
                     tag_value, mode, layout, tile_batch_count,
                     valid_group_count, expected_batches*group_count,
                     100.0*valid_group_count/(expected_batches*group_count),
                     enable_stalls);
        end
    endtask

    task automatic invalid_command_t;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input [1:0] mode;
        input [2:0] layout;
        input [TAG_W-1:0] tag_value;
        begin
            @(negedge clk);
            while (!cmd_ready_o) @(negedge clk);
            cmd_m_i = m_dim;
            cmd_n_i = n_dim;
            cmd_k_i = k_dim;
            cmd_mode_i = mode;
            cmd_layout_i = layout;
            cmd_tag_i = tag_value;
            cmd_valid_i = 1'b1;
            @(posedge clk);
            #1;
            if (!cmd_error_o || tile_batch_valid_o) begin
                $display("FAIL scheduler invalid command tag=%0d error=%0b tile_batch_valid=%0b",
                         tag_value, cmd_error_o, tile_batch_valid_o);
                errors = errors + 1;
            end
            @(negedge clk);
            cmd_valid_i = 1'b0;
            @(posedge clk);
            #1;
            if (cmd_error_o) begin
                $display("FAIL scheduler cmd_error wider than one cycle tag=%0d",
                         tag_value);
                errors = errors + 1;
            end
        end
    endtask

    task automatic back_to_back_t;
        integer first_fire_cycle;
        integer second_fire_cycle;
        begin
            tile_batch_ready_i = 1'b1;
            @(negedge clk);
            while (!cmd_ready_o) @(negedge clk);
            cmd_m_i = 4;
            cmd_n_i = 64;
            cmd_k_i = 1;
            cmd_mode_i = MODE_16X4X4;
            cmd_layout_i = 0;
            cmd_tag_i = 8'hd1;
            cmd_valid_i = 1'b1;
            @(posedge clk);
            #1;

            @(negedge clk);
            if (!tile_batch_valid_o || !tile_batch_cmd_last_o ||
                !cmd_ready_o || (tile_batch_tag_o != 8'hd1)) begin
                $display("FAIL scheduler back-to-back first tile batch state");
                errors = errors + 1;
            end
            cmd_m_i = 16;
            cmd_n_i = 16;
            cmd_k_i = 3;
            cmd_mode_i = MODE_4X8X8;
            cmd_layout_i = 1;
            cmd_tag_i = 8'hd2;
            cmd_valid_i = 1'b1;
            @(posedge clk);
            #1;
            first_fire_cycle = cycle_count;
            if (!schedule_done_o || (schedule_done_tag_o != 8'hd1) ||
                !tile_batch_valid_o || (tile_batch_tag_o != 8'hd2) ||
                !tile_batch_cmd_first_o || !tile_batch_cmd_last_o) begin
                $display("FAIL scheduler back-to-back handoff done=%0b done_tag=%0d tile_batch_tag=%0d",
                         schedule_done_o, schedule_done_tag_o,
                         tile_batch_tag_o);
                errors = errors + 1;
            end

            @(negedge clk);
            cmd_valid_i = 1'b0;
            @(posedge clk);
            #1;
            second_fire_cycle = cycle_count;
            if ((second_fire_cycle != first_fire_cycle + 1) ||
                !schedule_done_o || (schedule_done_tag_o != 8'hd2)) begin
                $display("FAIL scheduler back-to-back bubble first=%0d second=%0d done=%0b tag=%0d",
                         first_fire_cycle, second_fire_cycle,
                         schedule_done_o, schedule_done_tag_o);
                errors = errors + 1;
            end
            $display("SCHEDULER_BACK_TO_BACK first_cycle=%0d second_cycle=%0d interval=%0d",
                     first_fire_cycle, second_fire_cycle,
                     second_fire_cycle-first_fire_cycle);
        end
    endtask

    initial begin
        clk = 1'b0;
        resetn = 1'b0;
        cmd_valid_i = 1'b0;
        cmd_m_i = 0;
        cmd_n_i = 0;
        cmd_k_i = 0;
        cmd_mode_i = 0;
        cmd_layout_i = 0;
        cmd_tag_i = 0;
        tile_batch_ready_i = 1'b1;
        errors = 0;
        cycle_count = 0;

        repeat (4) @(posedge clk);
        resetn = 1'b1;

        invalid_command_t(0, 16, 1, MODE_16X16, 0, 8'he0);
        invalid_command_t(16, 16, 0, MODE_16X16, 0, 8'he1);
        invalid_command_t(16, 16, 1, 2'b11, 0, 8'he2);
        invalid_command_t(16, 16, 1, MODE_4X8X8, 3, 8'he3);
        invalid_command_t(16, 16, 1, MODE_16X4X4, 5, 8'he4);

        run_command_t(37, 29, 5, MODE_16X16, 0, 8'h10, 1, 1);
        run_command_t(8, 64, 1, MODE_4X8X8, 0, 8'h20, 0, 1);
        run_command_t(23, 19, 3, MODE_4X8X8, 1, 8'h21, 1, 0);
        run_command_t(64, 8, 7, MODE_4X8X8, 2, 8'h22, 0, 1);
        run_command_t(4, 128, 1, MODE_16X4X4, 0, 8'h30, 0, 1);
        run_command_t(16, 64, 2, MODE_16X4X4, 1, 8'h31, 0, 1);
        run_command_t(19, 21, 9, MODE_16X4X4, 2, 8'h32, 1, 0);
        run_command_t(64, 16, 4, MODE_16X4X4, 3, 8'h33, 0, 1);
        run_command_t(128, 4, 11, MODE_16X4X4, 4, 8'h34, 0, 1);
        run_command_t(1, 1, 1, MODE_16X4X4, 2, 8'h35, 1, 0);

        back_to_back_t();

        if (errors != 0)
            $fatal(1, "NPU_V13_GEMM_TILE_SCHEDULER_TB_FAIL errors=%0d", errors);
        $display("NPU_V13_GEMM_TILE_SCHEDULER_TB_PASS");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "TB_TIMEOUT");
    end
endmodule
