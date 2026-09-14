// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// command_queue_dispatcher 单元自检。
// mock cluster 只实现与真实 runtime 相同的同步 cfg/active_mode/error 时序；
// mock executor 由 task 控制 ready 和 done，用于覆盖完整命令生命周期。
//////////////////////////////////////////////////////////////////////////////////
module tb_npu_v13_command_queue_dispatcher;
    localparam integer DIM_W = 8;
    localparam integer ADDR_W = 16;
    localparam integer BANK_W = 1;
    localparam integer OP_CFG_W = 12;
    localparam integer TAG_W = 8;
    localparam integer FIFO_DEPTH = 8;
    localparam integer LEVEL_W = $clog2(FIFO_DEPTH + 1);

    localparam [2:0] RSP_OK                = 3'b000;
    localparam [2:0] RSP_ILLEGAL_OPCODE    = 3'b001;
    localparam [2:0] RSP_ILLEGAL_MODE      = 3'b010;
    localparam [2:0] RSP_MODE_APPLY_ERROR  = 3'b011;
    localparam [2:0] RSP_EXECUTION_ERROR   = 3'b100;
    localparam [2:0] RSP_TAG_MISMATCH      = 3'b101;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;

    reg cmd_valid_i = 1'b0;
    wire cmd_ready_o;
    reg [1:0] cmd_opcode_i = 2'b00;
    reg [DIM_W-1:0] cmd_m_i = 0;
    reg [DIM_W-1:0] cmd_n_i = 0;
    reg [DIM_W-1:0] cmd_k_i = 0;
    reg [1:0] cmd_cluster_mode_i = 0;
    reg [2:0] cmd_layout_i = 0;
    reg [ADDR_W-1:0] cmd_a_base_i = 0;
    reg [ADDR_W-1:0] cmd_b_base_i = 0;
    reg [ADDR_W-1:0] cmd_c_base_i = 0;
    reg [BANK_W-1:0] cmd_a_bank_i = 0;
    reg [BANK_W-1:0] cmd_b_bank_i = 0;
    reg [BANK_W-1:0] cmd_c_bank_i = 0;
    reg [OP_CFG_W-1:0] cmd_op_cfg_i = 0;
    reg [TAG_W-1:0] cmd_tag_i = 0;

    wire cmd_rsp_valid_o;
    reg cmd_rsp_ready_i = 1'b0;
    wire [TAG_W-1:0] cmd_rsp_tag_o;
    wire [2:0] cmd_rsp_status_o;

    wire exec_cmd_valid_o;
    reg exec_cmd_ready_i = 1'b0;
    wire [1:0] exec_cmd_opcode_o;
    wire [DIM_W-1:0] exec_cmd_m_o;
    wire [DIM_W-1:0] exec_cmd_n_o;
    wire [DIM_W-1:0] exec_cmd_k_o;
    wire [1:0] exec_cmd_cluster_mode_o;
    wire [2:0] exec_cmd_layout_o;
    wire [ADDR_W-1:0] exec_cmd_a_base_o;
    wire [ADDR_W-1:0] exec_cmd_b_base_o;
    wire [ADDR_W-1:0] exec_cmd_c_base_o;
    wire [BANK_W-1:0] exec_cmd_a_bank_o;
    wire [BANK_W-1:0] exec_cmd_b_bank_o;
    wire [BANK_W-1:0] exec_cmd_c_bank_o;
    wire [OP_CFG_W-1:0] exec_cmd_op_cfg_o;
    wire [TAG_W-1:0] exec_cmd_tag_o;

    reg exec_done_valid_i = 1'b0;
    wire exec_done_ready_o;
    reg [TAG_W-1:0] exec_done_tag_i = 0;
    reg exec_done_error_i = 1'b0;

    wire cluster_cfg_valid_o;
    wire [1:0] cluster_cfg_mode_o;
    reg cluster_cfg_ready_i = 1'b1;
    reg cluster_cfg_error_i = 1'b0;
    reg [1:0] cluster_active_mode_i = 2'b00;
    reg mock_force_mode_error = 1'b0;

    wire queue_empty_o;
    wire queue_full_o;
    wire [LEVEL_W-1:0] queue_level_o;
    wire dispatcher_busy_o;
    wire exec_active_o;

    npu_v13_command_queue_dispatcher #(
        .DIM_W(DIM_W),
        .ADDR_W(ADDR_W),
        .BANK_W(BANK_W),
        .OP_CFG_W(OP_CFG_W),
        .TAG_W(TAG_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .resetn(resetn),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .cmd_opcode_i(cmd_opcode_i),
        .cmd_m_i(cmd_m_i),
        .cmd_n_i(cmd_n_i),
        .cmd_k_i(cmd_k_i),
        .cmd_cluster_mode_i(cmd_cluster_mode_i),
        .cmd_layout_i(cmd_layout_i),
        .cmd_a_base_i(cmd_a_base_i),
        .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i),
        .cmd_a_bank_i(cmd_a_bank_i),
        .cmd_b_bank_i(cmd_b_bank_i),
        .cmd_c_bank_i(cmd_c_bank_i),
        .cmd_op_cfg_i(cmd_op_cfg_i),
        .cmd_tag_i(cmd_tag_i),
        .cmd_rsp_valid_o(cmd_rsp_valid_o),
        .cmd_rsp_ready_i(cmd_rsp_ready_i),
        .cmd_rsp_tag_o(cmd_rsp_tag_o),
        .cmd_rsp_status_o(cmd_rsp_status_o),
        .exec_cmd_valid_o(exec_cmd_valid_o),
        .exec_cmd_ready_i(exec_cmd_ready_i),
        .exec_cmd_opcode_o(exec_cmd_opcode_o),
        .exec_cmd_m_o(exec_cmd_m_o),
        .exec_cmd_n_o(exec_cmd_n_o),
        .exec_cmd_k_o(exec_cmd_k_o),
        .exec_cmd_cluster_mode_o(exec_cmd_cluster_mode_o),
        .exec_cmd_layout_o(exec_cmd_layout_o),
        .exec_cmd_a_base_o(exec_cmd_a_base_o),
        .exec_cmd_b_base_o(exec_cmd_b_base_o),
        .exec_cmd_c_base_o(exec_cmd_c_base_o),
        .exec_cmd_a_bank_o(exec_cmd_a_bank_o),
        .exec_cmd_b_bank_o(exec_cmd_b_bank_o),
        .exec_cmd_c_bank_o(exec_cmd_c_bank_o),
        .exec_cmd_op_cfg_o(exec_cmd_op_cfg_o),
        .exec_cmd_tag_o(exec_cmd_tag_o),
        .exec_done_valid_i(exec_done_valid_i),
        .exec_done_ready_o(exec_done_ready_o),
        .exec_done_tag_i(exec_done_tag_i),
        .exec_done_error_i(exec_done_error_i),
        .cluster_cfg_valid_o(cluster_cfg_valid_o),
        .cluster_cfg_mode_o(cluster_cfg_mode_o),
        .cluster_cfg_ready_i(cluster_cfg_ready_i),
        .cluster_cfg_error_i(cluster_cfg_error_i),
        .cluster_active_mode_i(cluster_active_mode_i),
        .queue_empty_o(queue_empty_o),
        .queue_full_o(queue_full_o),
        .queue_level_o(queue_level_o),
        .dispatcher_busy_o(dispatcher_busy_o),
        .exec_active_o(exec_active_o)
    );

    // 八条定向命令。4/5 非法，6 的 mode 配置由 mock 主动拒绝。
    reg [1:0] op_v [0:7];
    reg [DIM_W-1:0] m_v [0:7];
    reg [DIM_W-1:0] n_v [0:7];
    reg [DIM_W-1:0] k_v [0:7];
    reg [1:0] mode_v [0:7];
    reg [2:0] layout_v [0:7];
    reg [ADDR_W-1:0] a_base_v [0:7];
    reg [ADDR_W-1:0] b_base_v [0:7];
    reg [ADDR_W-1:0] c_base_v [0:7];
    reg a_bank_v [0:7];
    reg b_bank_v [0:7];
    reg c_bank_v [0:7];
    reg [OP_CFG_W-1:0] cfg_v [0:7];
    reg [TAG_W-1:0] tag_v [0:7];

    integer errors = 0;
    integer cycle_count = 0;
    integer accepted_commands = 0;
    integer executed_commands = 0;
    integer response_count = 0;
    integer cfg_fire_count = 0;
    integer cfg_stall_count = 0;
    integer head_retire_count = 0;
    integer fifo_pop_count = 0;
    integer local_reject_count = 0;
    integer mode_failure_count = 0;

    // 保存所有真正完成 ready/valid 握手的 response，便于在 ready 持续为高时
    // 仍能逐项检查顺序和状态，而不是依赖某一拍恰好观察到的输出值。
    reg [TAG_W-1:0] seen_rsp_tag [0:15];
    reg [2:0] seen_rsp_status [0:15];
    reg [2:0] expected_rsp_status [0:7];

    reg previous_head_retire_r = 1'b0;
    reg previous_fifo_pop_r = 1'b0;
    reg previous_cfg_fire_r = 1'b0;
    integer level_before_edge;
    integer push_at_edge;
    integer pop_at_edge;

    reg exec_stalled_r = 1'b0;
    reg [193:0] stalled_exec_bundle_r;
    reg rsp_stalled_r = 1'b0;
    reg [TAG_W+3-1:0] stalled_rsp_bundle_r;
    reg cfg_stalled_r = 1'b0;
    reg [1:0] stalled_cfg_mode_r;

    wire [193:0] exec_bundle_w = {
        exec_cmd_opcode_o, exec_cmd_m_o, exec_cmd_n_o, exec_cmd_k_o,
        exec_cmd_cluster_mode_o, exec_cmd_layout_o,
        {{(32-ADDR_W){1'b0}}, exec_cmd_a_base_o},
        {{(32-ADDR_W){1'b0}}, exec_cmd_b_base_o},
        {{(32-ADDR_W){1'b0}}, exec_cmd_c_base_o},
        exec_cmd_a_bank_o, exec_cmd_b_bank_o, exec_cmd_c_bank_o,
        {{(32-OP_CFG_W){1'b0}}, exec_cmd_op_cfg_o}, exec_cmd_tag_o
    };

    task automatic report_error;
        input [8*200-1:0] message;
        begin
            errors = errors + 1;
            $display("ERROR command_dispatcher cycle=%0d %0s", cycle_count,
                     message);
        end
    endtask

    // mock runtime cfg 时序与真实模块一致：握手上升沿更新 active/error。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cluster_active_mode_i <= 2'b00;
            cluster_cfg_error_i <= 1'b0;
        end else begin
            cluster_cfg_error_i <= 1'b0;
            if (cluster_cfg_valid_o && cluster_cfg_ready_i) begin
                if (mock_force_mode_error)
                    cluster_cfg_error_i <= 1'b1;
                else
                    cluster_active_mode_i <= cluster_cfg_mode_o;
            end
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (resetn) begin
            // FIFO level 必须只由本拍 push/pop 决定。这里在 NBA 更新前取样，
            // 再于 #1 后检查更新结果，可覆盖注册 pop 的精确一拍延迟。
            level_before_edge = queue_level_o;
            push_at_edge = cmd_valid_i && cmd_ready_o;
            pop_at_edge = dut.fifo_pop_r && dut.fifo_head_valid_w;

            if (push_at_edge)
                accepted_commands = accepted_commands + 1;
            if (exec_cmd_valid_o && exec_cmd_ready_i)
                executed_commands = executed_commands + 1;
            if (cmd_rsp_valid_o && cmd_rsp_ready_i) begin
                seen_rsp_tag[response_count] = cmd_rsp_tag_o;
                seen_rsp_status[response_count] = cmd_rsp_status_o;
                response_count = response_count + 1;
            end
            if (cluster_cfg_valid_o && cluster_cfg_ready_i)
                cfg_fire_count = cfg_fire_count + 1;
            if (cluster_cfg_valid_o && !cluster_cfg_ready_i)
                cfg_stall_count = cfg_stall_count + 1;

            if (dut.head_retire_w)
                head_retire_count = head_retire_count + 1;
            if (pop_at_edge)
                fifo_pop_count = fifo_pop_count + 1;
            if (dut.local_reject_fire_w)
                local_reject_count = local_reject_count + 1;
            if (dut.mode_failure_fire_w)
                mode_failure_count = mode_failure_count + 1;

            // head_retire_w 只负责产生下一拍的 fifo_pop_r。二者若不严格
            // 相差一拍，可能造成命令重复执行或跳过下一条命令。
            if (dut.fifo_pop_r !== previous_head_retire_r)
                report_error("registered FIFO pop is not one cycle after head retire");
            if (pop_at_edge && previous_fifo_pop_r)
                report_error("FIFO pop remained asserted for consecutive cycles");
            if ((cluster_cfg_valid_o && cluster_cfg_ready_i) &&
                previous_cfg_fire_r)
                report_error("cluster cfg fired in consecutive cycles");

            // pop 周期还呈现旧 FIFO head，但 metadata 已经失效；任何控制动作
            // 若在这一拍再次发生，都会把同一条命令处理两次。
            if (dut.fifo_pop_r) begin
                if (!dut.fifo_head_valid_w)
                    report_error("registered FIFO pop asserted without a valid head");
                if (dut.head_meta_valid_r)
                    report_error("head metadata remained valid during FIFO pop");
                if (dut.head_meta_load_w)
                    report_error("head metadata reloaded old head during FIFO pop");
                if (dut.head_retire_w)
                    report_error("head retired again during delayed FIFO pop");
                if (exec_cmd_valid_o)
                    report_error("exec command repeated during delayed FIFO pop");
                if (dut.mode_req_valid_w)
                    report_error("mode request repeated during delayed FIFO pop");
            end

            previous_head_retire_r = dut.head_retire_w;
            previous_fifo_pop_r = pop_at_edge;
            previous_cfg_fire_r =
                cluster_cfg_valid_o && cluster_cfg_ready_i;
        end

        #1;
        if (!resetn) begin
            exec_stalled_r = 1'b0;
            rsp_stalled_r = 1'b0;
            cfg_stalled_r = 1'b0;
            previous_head_retire_r = 1'b0;
            previous_fifo_pop_r = 1'b0;
            previous_cfg_fire_r = 1'b0;
        end else begin
            if (queue_level_o !==
                (level_before_edge + push_at_edge - pop_at_edge))
                report_error("FIFO level did not follow push/pop accounting");

            if (exec_cmd_valid_o && !exec_cmd_ready_i) begin
                if (exec_stalled_r &&
                    (exec_bundle_w !== stalled_exec_bundle_r))
                    report_error("exec command changed during backpressure");
                exec_stalled_r = 1'b1;
                stalled_exec_bundle_r = exec_bundle_w;
            end else begin
                exec_stalled_r = 1'b0;
            end

            if (cmd_rsp_valid_o && !cmd_rsp_ready_i) begin
                if (rsp_stalled_r &&
                    ({cmd_rsp_tag_o, cmd_rsp_status_o} !==
                     stalled_rsp_bundle_r))
                    report_error("command response changed during backpressure");
                rsp_stalled_r = 1'b1;
                stalled_rsp_bundle_r = {cmd_rsp_tag_o, cmd_rsp_status_o};
            end else begin
                rsp_stalled_r = 1'b0;
            end

            if (cluster_cfg_valid_o && !cluster_cfg_ready_i) begin
                if (cfg_stalled_r &&
                    (cluster_cfg_mode_o !== stalled_cfg_mode_r))
                    report_error("cluster cfg mode changed during backpressure");
                cfg_stalled_r = 1'b1;
                stalled_cfg_mode_r = cluster_cfg_mode_o;
            end else begin
                cfg_stalled_r = 1'b0;
            end

            if (exec_active_o && cluster_cfg_valid_o)
                report_error("next mode request started while command RUNNING");
            if (cluster_cfg_valid_o && (cluster_cfg_mode_o == 2'b11))
                report_error("illegal mode reached mock cluster");
        end
    end

    task automatic enqueue_command;
        input integer idx;
        begin
            // 先对齐到下降沿再驱动，确保 valid 至少跨过一个完整上升沿。
            @(negedge clk);
            while (!cmd_ready_o) @(negedge clk);
            cmd_opcode_i = op_v[idx];
            cmd_m_i = m_v[idx];
            cmd_n_i = n_v[idx];
            cmd_k_i = k_v[idx];
            cmd_cluster_mode_i = mode_v[idx];
            cmd_layout_i = layout_v[idx];
            cmd_a_base_i = a_base_v[idx];
            cmd_b_base_i = b_base_v[idx];
            cmd_c_base_i = c_base_v[idx];
            cmd_a_bank_i = a_bank_v[idx];
            cmd_b_bank_i = b_bank_v[idx];
            cmd_c_bank_i = c_bank_v[idx];
            cmd_op_cfg_i = cfg_v[idx];
            cmd_tag_i = tag_v[idx];
            cmd_valid_i = 1'b1;
            @(posedge clk);
            while (!cmd_ready_o) @(posedge clk);
            @(negedge clk);
            cmd_valid_i = 1'b0;
        end
    endtask

    task automatic accept_exec;
        input integer idx;
        input integer stall_cycles;
        integer stall_i;
        integer executed_before;
        integer retire_before;
        integer pop_before;
        integer level_before;
        begin
            exec_cmd_ready_i = 1'b0;
            while (!exec_cmd_valid_o) @(negedge clk);
            for (stall_i = 0; stall_i < stall_cycles;
                 stall_i = stall_i + 1)
                @(negedge clk);

            if ((exec_cmd_opcode_o !== op_v[idx]) ||
                (exec_cmd_m_o !== m_v[idx]) ||
                (exec_cmd_n_o !== n_v[idx]) ||
                (exec_cmd_k_o !== k_v[idx]) ||
                (exec_cmd_cluster_mode_o !== mode_v[idx]) ||
                (exec_cmd_layout_o !== layout_v[idx]) ||
                (exec_cmd_a_base_o !== a_base_v[idx]) ||
                (exec_cmd_b_base_o !== b_base_v[idx]) ||
                (exec_cmd_c_base_o !== c_base_v[idx]) ||
                (exec_cmd_a_bank_o !== a_bank_v[idx]) ||
                (exec_cmd_b_bank_o !== b_bank_v[idx]) ||
                (exec_cmd_c_bank_o !== c_bank_v[idx]) ||
                (exec_cmd_op_cfg_o !== cfg_v[idx]) ||
                (exec_cmd_tag_o !== tag_v[idx]))
                report_error("exec command fields/order mismatch");

            executed_before = executed_commands;
            retire_before = head_retire_count;
            pop_before = fifo_pop_count;
            level_before = queue_level_o;

            // ready 连续保持三个完整周期：第一个周期接管命令，第二个周期
            // 执行注册 pop，第三个周期继续施压，确认 valid 不会重新冒出。
            @(negedge clk);
            exec_cmd_ready_i = 1'b1;
            repeat (3) @(negedge clk);
            exec_cmd_ready_i = 1'b0;

            if (executed_commands != (executed_before + 1))
                report_error("continuous exec ready caused missing/duplicate dispatch");
            if (head_retire_count != (retire_before + 1))
                report_error("legal exec did not retire head exactly once");
            if (fifo_pop_count != (pop_before + 1))
                report_error("legal exec did not pop FIFO exactly once");
            if (queue_level_o != (level_before - 1))
                report_error("legal exec did not decrement queue level exactly once");
            if (exec_cmd_valid_o)
                report_error("exec valid reasserted while ready stayed high");
            if (!exec_active_o)
                report_error("dispatcher did not enter RUNNING after dispatch");
        end
    endtask

    task automatic send_done;
        input [TAG_W-1:0] done_tag;
        input done_error;
        begin
            while (!exec_done_ready_o) @(negedge clk);
            @(negedge clk);
            exec_done_tag_i = done_tag;
            exec_done_error_i = done_error;
            exec_done_valid_i = 1'b1;
            @(posedge clk);
            while (!exec_done_ready_o) @(posedge clk);
            @(negedge clk);
            exec_done_valid_i = 1'b0;
            exec_done_error_i = 1'b0;
        end
    endtask

    task automatic consume_response;
        input [TAG_W-1:0] expected_tag;
        input [2:0] expected_status;
        input integer stall_cycles;
        integer stall_i;
        begin
            cmd_rsp_ready_i = 1'b0;
            while (!cmd_rsp_valid_o) @(negedge clk);
            for (stall_i = 0; stall_i < stall_cycles;
                 stall_i = stall_i + 1)
                @(negedge clk);
            if ((cmd_rsp_tag_o !== expected_tag) ||
                (cmd_rsp_status_o !== expected_status)) begin
                $display("ERROR response expected tag=%h status=%b actual tag=%h status=%b",
                         expected_tag, expected_status,
                         cmd_rsp_tag_o, cmd_rsp_status_o);
                errors = errors + 1;
            end
            @(negedge clk);
            cmd_rsp_ready_i = 1'b1;
            @(posedge clk);
            while (!cmd_rsp_valid_o) @(posedge clk);
            @(negedge clk);
            cmd_rsp_ready_i = 1'b0;
        end
    endtask

    integer i;
    integer cfg_before_invalid;
    integer rsp_before_continuous;
    integer retire_before_continuous;
    integer pop_before_continuous;
    integer reject_before_continuous;
    integer failure_before_continuous;
    integer level_before_continuous;
    integer cfg_before_failure;
    integer stable_rsp_count;
    integer executed_before_continuous;
    initial begin
        for (i = 0; i < 8; i = i + 1) begin
            op_v[i] = 2'b00;
            m_v[i] = 8'd10 + i;
            n_v[i] = 8'd20 + i;
            k_v[i] = 8'd30 + i;
            mode_v[i] = 2'b00;
            // 成功路径全部使用现有 scheduler 接受的 mode-local layout；
            // 本 TB 仍逐字段检查它们经过 FIFO 后不被改写。
            layout_v[i] = 3'd0;
            a_base_v[i] = 16'h1000 + i;
            b_base_v[i] = 16'h2000 + i;
            c_base_v[i] = 16'h3000 + i;
            a_bank_v[i] = i[0];
            b_bank_v[i] = ~i[0];
            c_bank_v[i] = i[0];
            cfg_v[i] = 12'h500 + i;
            tag_v[i] = 8'h40 + i;
        end
        mode_v[2] = 2'b01;
        layout_v[2] = 3'd2;
        mode_v[3] = 2'b01;
        layout_v[3] = 3'd1;
        op_v[3] = 2'b01;
        op_v[4] = 2'b10;
        mode_v[5] = 2'b11;
        mode_v[6] = 2'b10;
        layout_v[6] = 3'd2;
        mode_v[7] = 2'b10;
        layout_v[7] = 3'd4;

        expected_rsp_status[0] = RSP_OK;
        expected_rsp_status[1] = RSP_EXECUTION_ERROR;
        expected_rsp_status[2] = RSP_OK;
        expected_rsp_status[3] = RSP_OK;
        expected_rsp_status[4] = RSP_ILLEGAL_OPCODE;
        expected_rsp_status[5] = RSP_ILLEGAL_MODE;
        expected_rsp_status[6] = RSP_MODE_APPLY_ERROR;
        expected_rsp_status[7] = RSP_TAG_MISMATCH;

        repeat (4) @(posedge clk);
        #1;
        if (cmd_ready_o !== 1'b0)
            report_error("command ready asserted during reset");
        @(negedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (!queue_empty_o || queue_full_o || dispatcher_busy_o ||
            exec_cmd_valid_o || cmd_rsp_valid_o)
            report_error("reset state is not empty/idle");

        // executor 反压，使八条命令全部进入 FIFO 并形成 full。
        exec_cmd_ready_i = 1'b0;
        for (i = 0; i < 8; i = i + 1)
            enqueue_command(i);
        repeat (3) @(posedge clk);
        #1;
        if (!queue_full_o || cmd_ready_o || (queue_level_o != FIFO_DEPTH))
            report_error("eight queued commands did not fill FIFO");
        $display("DISPATCHER_TB_STAGE queue_full cycle=%0d", cycle_count);

        // cmd0：默认同模式，无 cfg；执行接口反压三拍后接管。
        accept_exec(0, 3);
        $display("DISPATCHER_TB_STAGE cmd0_issued cycle=%0d", cycle_count);
        if (cfg_fire_count != 0)
            report_error("same-mode command generated cfg transaction");
        repeat (3) @(posedge clk);
        if (exec_cmd_valid_o)
            report_error("next command issued before cmd0 exec_done");
        send_done(tag_v[0], 1'b0);
        $display("DISPATCHER_TB_STAGE cmd0_done cycle=%0d exec_valid=%0b state=%0d head_valid=%0b op=%0b mode=%0b active=%0b rsp_valid=%0b",
                 cycle_count, exec_cmd_valid_o, dut.state_r,
                 dut.fifo_head_valid_w, exec_cmd_opcode_o,
                 exec_cmd_cluster_mode_o, cluster_active_mode_i,
                 cmd_rsp_valid_o);

        // 保持 cmd0 response，同时 cmd1 可在下一完成边界下发。
        accept_exec(1, 0);
        $display("DISPATCHER_TB_STAGE cmd1_issued cycle=%0d", cycle_count);
        consume_response(tag_v[0], RSP_OK, 3);
        // 在 cmd1 完成前关闭 cfg；cmd1 done 后 dispatcher 即可预处理
        // cmd2，不能等 cmd1 response 被消费后才施加 cluster 反压。
        cluster_cfg_ready_i = 1'b0;
        send_done(tag_v[1], 1'b1);
        consume_response(tag_v[1], RSP_EXECUTION_ERROR, 0);
        $display("DISPATCHER_TB_STAGE cmd1_retired cycle=%0d", cycle_count);

        // cmd2：不同 mode。先等请求真实出现，再阻塞四拍检查保持；不能用
        // 固定延迟猜测 FIFO 预取和 mode controller 的状态到达时刻。
        while (cluster_cfg_valid_o !== 1'b1)
            @(negedge clk);
        repeat (4) begin
            @(posedge clk);
            #1;
            if (!cluster_cfg_valid_o || cluster_cfg_ready_i ||
                (cluster_cfg_mode_o != 2'b01))
                report_error("different-mode cfg request was not held");
        end
        @(negedge clk);
        cluster_cfg_ready_i = 1'b1;
        accept_exec(2, 2);
        $display("DISPATCHER_TB_STAGE cmd2_issued cycle=%0d", cycle_count);
        if (cluster_active_mode_i != 2'b01)
            report_error("mode 01 did not become active before exec");
        send_done(tag_v[2], 1'b0);
        consume_response(tag_v[2], RSP_OK, 0);
        $display("DISPATCHER_TB_STAGE cmd2_retired cycle=%0d", cycle_count);

        // cmd3：CONV opcode 作为完整命令原样转发，当前 mode 相同。
        // 从 cmd3 完成开始持续拉高 response ready，让 cmd3/cmd4/cmd5
        // 连续自动推进，专门检查弹性 response 槽和注册 pop 不会重复动作。
        accept_exec(3, 0);
        @(negedge clk);
        cluster_cfg_ready_i = 1'b0;
        cmd_rsp_ready_i = 1'b1;
        rsp_before_continuous = response_count;
        retire_before_continuous = head_retire_count;
        pop_before_continuous = fifo_pop_count;
        reject_before_continuous = local_reject_count;
        level_before_continuous = queue_level_o;
        executed_before_continuous = executed_commands;
        cfg_before_invalid = cfg_fire_count;
        send_done(tag_v[3], 1'b0);
        while ((response_count < (rsp_before_continuous + 3)) ||
               (fifo_pop_count < (pop_before_continuous + 2)))
            @(negedge clk);

        if (response_count != (rsp_before_continuous + 3))
            report_error("continuous response ready caused missing/duplicate responses");
        if ((seen_rsp_tag[rsp_before_continuous] !== tag_v[3]) ||
            (seen_rsp_status[rsp_before_continuous] !== RSP_OK))
            report_error("cmd3 response mismatch under continuous ready");
        if ((seen_rsp_tag[rsp_before_continuous + 1] !== tag_v[4]) ||
            (seen_rsp_status[rsp_before_continuous + 1] !==
             RSP_ILLEGAL_OPCODE))
            report_error("cmd4 response mismatch under continuous ready");
        if ((seen_rsp_tag[rsp_before_continuous + 2] !== tag_v[5]) ||
            (seen_rsp_status[rsp_before_continuous + 2] !==
             RSP_ILLEGAL_MODE))
            report_error("cmd5 response mismatch under continuous ready");
        if (head_retire_count != (retire_before_continuous + 2))
            report_error("local rejects did not retire exactly two heads");
        if (fifo_pop_count != (pop_before_continuous + 2))
            report_error("local rejects did not pop exactly two commands");
        if (local_reject_count != (reject_before_continuous + 2))
            report_error("local reject event count is not exactly two");
        if (queue_level_o != (level_before_continuous - 2))
            report_error("local rejects did not decrement queue level twice");
        if (executed_commands != executed_before_continuous)
            report_error("illegal command reached executor");
        if (cfg_fire_count != cfg_before_invalid)
            report_error("illegal commands reached cluster cfg");

        // ready 保持为高再观察三拍，防止已经消费的 response 重新出现。
        stable_rsp_count = response_count;
        repeat (3) @(negedge clk);
        if (response_count != stable_rsp_count)
            report_error("response repeated after cmd3/cmd4/cmd5 retired");
        cmd_rsp_ready_i = 1'b0;
        $display("DISPATCHER_TB_STAGE cmd3_to_cmd5_retired cycle=%0d",
                 cycle_count);

        // cmd6：合法 mode，但 mock cluster 主动报错，不应送执行器。错误注入
        // 必须在重新开放 cfg 握手前置位，避免与 mock 的握手沿发生竞态。
        mock_force_mode_error = 1'b1;
        while (cluster_cfg_valid_o !== 1'b1)
            @(negedge clk);
        if (cluster_cfg_mode_o !== 2'b10)
            report_error("cmd6 requested unexpected cluster mode");
        cmd_rsp_ready_i = 1'b1;
        rsp_before_continuous = response_count;
        retire_before_continuous = head_retire_count;
        pop_before_continuous = fifo_pop_count;
        failure_before_continuous = mode_failure_count;
        level_before_continuous = queue_level_o;
        executed_before_continuous = executed_commands;
        cfg_before_failure = cfg_fire_count;
        @(negedge clk);
        cluster_cfg_ready_i = 1'b1;
        // 仅允许 cmd6 的一次 cfg 握手，随后立即关闭错误注入和 cfg，
        // 防止 cmd6 response 反压期间误伤已经推进到 head 的 cmd7。
        @(posedge clk);
        #1;
        @(negedge clk);
        cluster_cfg_ready_i = 1'b0;
        mock_force_mode_error = 1'b0;
        while ((response_count < (rsp_before_continuous + 1)) ||
               (fifo_pop_count < (pop_before_continuous + 1)))
            @(negedge clk);
        if (response_count != (rsp_before_continuous + 1))
            report_error("mode failure did not produce exactly one response");
        if ((seen_rsp_tag[rsp_before_continuous] !== tag_v[6]) ||
            (seen_rsp_status[rsp_before_continuous] !==
             RSP_MODE_APPLY_ERROR))
            report_error("cmd6 mode failure response mismatch");
        if (head_retire_count != (retire_before_continuous + 1))
            report_error("mode failure did not retire exactly one head");
        if (fifo_pop_count != (pop_before_continuous + 1))
            report_error("mode failure did not pop exactly one command");
        if (mode_failure_count != (failure_before_continuous + 1))
            report_error("mode failure event count is not exactly one");
        if (queue_level_o != (level_before_continuous - 1))
            report_error("mode failure did not decrement queue level once");
        if (executed_commands != executed_before_continuous)
            report_error("mode-failed command reached executor");
        if (cfg_fire_count != (cfg_before_failure + 1))
            report_error("cmd6 mode request did not fire exactly once");

        stable_rsp_count = response_count;
        repeat (3) @(negedge clk);
        if (response_count != stable_rsp_count)
            report_error("mode failure response repeated while ready stayed high");
        cmd_rsp_ready_i = 1'b0;
        $display("DISPATCHER_TB_STAGE cmd6_rejected cycle=%0d", cycle_count);

        // cmd7：重试 mode 成功执行，但故意返回错误 tag。
        cluster_cfg_ready_i = 1'b1;
        accept_exec(7, 1);
        send_done(8'hfe, 1'b0);
        consume_response(tag_v[7], RSP_TAG_MISMATCH, 0);
        $display("DISPATCHER_TB_STAGE cmd7_retired cycle=%0d", cycle_count);

        repeat (4) @(posedge clk);
        #1;
        if (!queue_empty_o || dispatcher_busy_o || exec_active_o ||
            cmd_rsp_valid_o || exec_cmd_valid_o)
            report_error("dispatcher did not return to idle after all commands");
        if (accepted_commands != 8)
            report_error("unexpected accepted command count");
        if (executed_commands != 5)
            report_error("unexpected executed command count");
        if (response_count != 8)
            report_error("not every accepted command produced one response");
        if (head_retire_count != 8)
            report_error("not every command retired exactly once");
        if (fifo_pop_count != 8)
            report_error("not every command popped from FIFO exactly once");
        if (local_reject_count != 2)
            report_error("unexpected local reject count");
        if (mode_failure_count != 1)
            report_error("unexpected mode failure count");
        if (cfg_fire_count != 3)
            report_error("unexpected cluster cfg handshake count");
        if (queue_level_o != 0)
            report_error("queue level is not zero after all commands");
        if (cfg_stall_count < 4)
            report_error("cfg backpressure was not exercised");

        for (i = 0; i < 8; i = i + 1) begin
            if (seen_rsp_tag[i] !== tag_v[i])
                report_error("response tag order mismatch");
            if (seen_rsp_status[i] !== expected_rsp_status[i])
                report_error("response status order mismatch");
        end

        if (errors == 0)
            $display("NPU_V13_COMMAND_QUEUE_DISPATCHER_TB_PASS accepted=%0d executed=%0d responses=%0d retires=%0d pops=%0d cfg_fires=%0d cfg_stalls=%0d",
                     accepted_commands, executed_commands, response_count,
                     head_retire_count, fifo_pop_count, cfg_fire_count,
                     cfg_stall_count);
        else
            $display("NPU_V13_COMMAND_QUEUE_DISPATCHER_TB_FAIL errors=%0d",
                     errors);
        $finish;
    end

    initial begin
        #300000;
        $display("NPU_V13_COMMAND_QUEUE_DISPATCHER_TB_TIMEOUT");
        $finish;
    end
endmodule
