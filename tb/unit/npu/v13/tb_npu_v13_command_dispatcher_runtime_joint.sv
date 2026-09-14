// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// npu_v13_command_queue_dispatcher + runtime cluster 真实联合自检。
//
// 这个测试台只用一个很小的行为级 executor/feeder 补上尚未实现的系统部分：
//   * executor 通过 exec_cmd ready/valid 接收完整命令；
//   * feeder 按已生效的 mode，向逻辑 group 0 发送 K=2、1x1 数据包；
//   * 只有观察到真实 runtime cluster 的 c_tile_valid 后，才回送 exec_done。
//
// 被测 cfg 路径没有 mock：dispatcher 内部的 mode controller 逐线连接到真实
// npu_v13_systolic_cluster_runtime_stream。测试重点是跨模块契约，而不是重复已有
// runtime cluster 三模式全矩阵回归：
//   1. mode=01 和 mode=10 的命令可以提前进入 FIFO，且严格按序执行；
//   2. 当前命令处于 RUNNING 时，下一条不同 mode 命令不能提前发起 cfg；
//   3. 每次 exec_cmd 下发前，真实 active_mode 已经等于该命令目标 mode；
//   4. 两个 K=2 数据包都产生且只产生一次正确的 1x1 结果；
//   5. command response 被反压时 tag/status 保持，且不妨碍下一次合法 mode 切换；
//   6. 非法 mode 命令只在 dispatcher 本地退休，不到达 runtime cfg/执行接口。
//////////////////////////////////////////////////////////////////////////////////
module tb_npu_v13_command_dispatcher_runtime_joint;
    localparam integer DATA_W = 8;
    localparam integer ACC_W = 32;
    localparam integer DIM_W = 8;
    localparam integer ADDR_W = 16;
    localparam integer BANK_W = 1;
    localparam integer OP_CFG_W = 12;
    localparam integer TAG_W = 8;
    localparam integer FIFO_DEPTH = 8;
    localparam integer COMMAND_W =
        2 + (3 * DIM_W) + 2 + 3 + (3 * ADDR_W) +
        (3 * BANK_W) + OP_CFG_W + TAG_W;

    localparam [1:0] OPCODE_GEMM = 2'b00;
    localparam [1:0] MODE_4X8X8 = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;
    localparam [2:0] RSP_OK = 3'b000;
    localparam [2:0] RSP_ILLEGAL_MODE = 3'b010;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg resetn = 1'b0;

    // 完整命令入口。
    reg                              cmd_valid_i = 1'b0;
    wire                             cmd_ready_o;
    reg  [1:0]                       cmd_opcode_i = 2'b0;
    reg  [DIM_W-1:0]                 cmd_m_i = 0;
    reg  [DIM_W-1:0]                 cmd_n_i = 0;
    reg  [DIM_W-1:0]                 cmd_k_i = 0;
    reg  [1:0]                       cmd_cluster_mode_i = 2'b0;
    reg  [2:0]                       cmd_layout_i = 3'b0;
    reg  [ADDR_W-1:0]                cmd_a_base_i = 0;
    reg  [ADDR_W-1:0]                cmd_b_base_i = 0;
    reg  [ADDR_W-1:0]                cmd_c_base_i = 0;
    reg  [BANK_W-1:0]                cmd_a_bank_i = 0;
    reg  [BANK_W-1:0]                cmd_b_bank_i = 0;
    reg  [BANK_W-1:0]                cmd_c_bank_i = 0;
    reg  [OP_CFG_W-1:0]              cmd_op_cfg_i = 0;
    reg  [TAG_W-1:0]                 cmd_tag_i = 0;

    // 命令退休响应。
    wire                             cmd_rsp_valid_o;
    reg                              cmd_rsp_ready_i = 1'b0;
    wire [TAG_W-1:0]                 cmd_rsp_tag_o;
    wire [2:0]                       cmd_rsp_status_o;

    // 行为级 executor 接口。
    wire                             exec_cmd_valid_o;
    reg                              exec_cmd_ready_i = 1'b0;
    wire [1:0]                       exec_cmd_opcode_o;
    wire [DIM_W-1:0]                 exec_cmd_m_o;
    wire [DIM_W-1:0]                 exec_cmd_n_o;
    wire [DIM_W-1:0]                 exec_cmd_k_o;
    wire [1:0]                       exec_cmd_cluster_mode_o;
    wire [2:0]                       exec_cmd_layout_o;
    wire [ADDR_W-1:0]                exec_cmd_a_base_o;
    wire [ADDR_W-1:0]                exec_cmd_b_base_o;
    wire [ADDR_W-1:0]                exec_cmd_c_base_o;
    wire [BANK_W-1:0]                exec_cmd_a_bank_o;
    wire [BANK_W-1:0]                exec_cmd_b_bank_o;
    wire [BANK_W-1:0]                exec_cmd_c_bank_o;
    wire [OP_CFG_W-1:0]              exec_cmd_op_cfg_o;
    wire [TAG_W-1:0]                 exec_cmd_tag_o;

    reg                              exec_done_valid_i = 1'b0;
    wire                             exec_done_ready_o;
    reg  [TAG_W-1:0]                 exec_done_tag_i = 0;
    reg                              exec_done_error_i = 1'b0;

    // dispatcher 与 runtime cluster 之间的真实 cfg 连线。
    wire                             cluster_cfg_valid_w;
    wire [1:0]                       cluster_cfg_mode_w;
    wire                             cluster_cfg_ready_w;
    wire                             cluster_cfg_error_w;
    wire [1:0]                       cluster_active_mode_w;
    wire                             cluster_idle_w;

    wire                             queue_empty_o;
    wire                             queue_full_o;
    wire [$clog2(FIFO_DEPTH+1)-1:0]  queue_level_o;
    wire                             dispatcher_busy_o;
    wire                             exec_active_o;

    // runtime cluster 数据输入/结果输出。所有模式的 group 0 锚点都是 lane 0；
    // shape 全零表示有效区域为 1x1，因此只检查全局 C[0,0]。
    reg  [15:0]                      s_axis_tvalid_i = 16'b0;
    reg  [15:0]                      s_axis_tuser_i = 16'b0;
    reg  [15:0]                      s_axis_tlast_i = 16'b0;
    reg  [31:0]                      active_rows_m1_i = 32'b0;
    reg  [31:0]                      active_cols_m1_i = 32'b0;
    reg  [16*4*DATA_W-1:0]           a_source_i = 0;
    reg  [16*4*DATA_W-1:0]           b_source_i = 0;
    wire [15:0]                      c_tile_valid_o;
    wire [31:0]                      c_active_rows_m1_o;
    wire [31:0]                      c_active_cols_m1_o;
    wire [16*16*ACC_W-1:0]           c_matrix_o;

    npu_v13_command_queue_dispatcher #(
        .DIM_W(DIM_W),
        .ADDR_W(ADDR_W),
        .BANK_W(BANK_W),
        .OP_CFG_W(OP_CFG_W),
        .TAG_W(TAG_W),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_dispatcher (
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
        .cluster_cfg_valid_o(cluster_cfg_valid_w),
        .cluster_cfg_mode_o(cluster_cfg_mode_w),
        .cluster_cfg_ready_i(cluster_cfg_ready_w),
        .cluster_cfg_error_i(cluster_cfg_error_w),
        .cluster_active_mode_i(cluster_active_mode_w),
        .queue_empty_o(queue_empty_o),
        .queue_full_o(queue_full_o),
        .queue_level_o(queue_level_o),
        .dispatcher_busy_o(dispatcher_busy_o),
        .exec_active_o(exec_active_o)
    );

    npu_v13_systolic_cluster_runtime_stream #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_runtime_cluster (
        .clk(clk),
        .resetn(resetn),
        .cfg_valid_i(cluster_cfg_valid_w),
        .cfg_mode_i(cluster_cfg_mode_w),
        .cfg_ready_o(cluster_cfg_ready_w),
        .cfg_error_o(cluster_cfg_error_w),
        .active_mode_o(cluster_active_mode_w),
        .cluster_idle_o(cluster_idle_w),
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

    // 三条命令：两条合法且 mode 不同，第三条 mode=11，必须本地拒绝。
    reg [1:0]          op_v [0:2];
    reg [DIM_W-1:0]    m_v [0:2];
    reg [DIM_W-1:0]    n_v [0:2];
    reg [DIM_W-1:0]    k_v [0:2];
    reg [1:0]          mode_v [0:2];
    reg [2:0]          layout_v [0:2];
    reg [ADDR_W-1:0]   a_base_v [0:2];
    reg [ADDR_W-1:0]   b_base_v [0:2];
    reg [ADDR_W-1:0]   c_base_v [0:2];
    reg                a_bank_v [0:2];
    reg                b_bank_v [0:2];
    reg                c_bank_v [0:2];
    reg [OP_CFG_W-1:0] op_cfg_v [0:2];
    reg [TAG_W-1:0]    tag_v [0:2];

    integer errors = 0;
    integer cycle_count = 0;
    integer accepted_count = 0;
    integer executed_count = 0;
    integer done_count = 0;
    integer response_count = 0;
    integer cfg_fire_count = 0;
    integer result_count = 0;
    integer response_stall_cycles = 0;

    wire [COMMAND_W-1:0] exec_bundle_w = {
        exec_cmd_opcode_o, exec_cmd_m_o, exec_cmd_n_o, exec_cmd_k_o,
        exec_cmd_cluster_mode_o, exec_cmd_layout_o,
        exec_cmd_a_base_o, exec_cmd_b_base_o, exec_cmd_c_base_o,
        exec_cmd_a_bank_o, exec_cmd_b_bank_o, exec_cmd_c_bank_o,
        exec_cmd_op_cfg_o, exec_cmd_tag_o
    };
    reg [COMMAND_W-1:0] stalled_exec_bundle_r;
    reg exec_stalled_r = 1'b0;
    reg [TAG_W+3-1:0] stalled_response_bundle_r;
    reg response_stalled_r = 1'b0;
    reg [1:0] stalled_cfg_mode_r;
    reg cfg_stalled_r = 1'b0;

    task automatic report_error;
        input [8*200-1:0] message;
        begin
            errors = errors + 1;
            $display("ERROR command_dispatcher_runtime_joint cycle=%0d %0s",
                     cycle_count, message);
        end
    endtask

    task automatic clear_cluster_input;
        begin
            s_axis_tvalid_i = 16'b0;
            s_axis_tuser_i = 16'b0;
            s_axis_tlast_i = 16'b0;
            active_rows_m1_i = 32'b0;
            active_cols_m1_i = 32'b0;
            a_source_i = 0;
            b_source_i = 0;
        end
    endtask

    // 向 FIFO 送一条完整命令。所有 payload 字段至少跨过一个有效上升沿。
    task automatic enqueue_command;
        input integer idx;
        begin
            @(negedge clk);
            while (cmd_ready_o !== 1'b1)
                @(negedge clk);
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
            cmd_op_cfg_i = op_cfg_v[idx];
            cmd_tag_i = tag_v[idx];
            cmd_valid_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cmd_valid_i = 1'b0;
        end
    endtask

    // 检查 head 的全部字段，并在若干拍反压后让行为级 executor 接管命令。
    task automatic accept_exec_command;
        input integer idx;
        input integer stall_cycles;
        integer stall_i;
        begin
            exec_cmd_ready_i = 1'b0;
            while (exec_cmd_valid_o !== 1'b1)
                @(negedge clk);

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
                (exec_cmd_op_cfg_o !== op_cfg_v[idx]) ||
                (exec_cmd_tag_o !== tag_v[idx]))
                report_error("exec command fields/order mismatch");

            if (cluster_active_mode_w !== mode_v[idx])
                report_error("exec command became valid before requested mode was active");

            exec_cmd_ready_i = 1'b1;
            @(posedge clk);
            #1;
            if (!exec_active_o)
                report_error("dispatcher did not enter RUNNING after exec handshake");
            @(negedge clk);
            exec_cmd_ready_i = 1'b0;
        end
    endtask

    // lane 0 的向量元素 0 分别承载 A[0,k] 与 B[k,0]；其余元素无效。
    // 两拍连续有效，第一拍 TUSER 初始化，第二拍 TLAST 关闭 packet。
    task automatic drive_k2_1x1_packet;
        input signed [DATA_W-1:0] a_k0;
        input signed [DATA_W-1:0] b_k0;
        input signed [DATA_W-1:0] a_k1;
        input signed [DATA_W-1:0] b_k1;
        begin
            @(negedge clk);
            clear_cluster_input();
            s_axis_tvalid_i[0] = 1'b1;
            s_axis_tuser_i[0] = 1'b1;
            a_source_i[0 +: DATA_W] = a_k0;
            b_source_i[0 +: DATA_W] = b_k0;

            @(negedge clk);
            s_axis_tuser_i[0] = 1'b0;
            s_axis_tlast_i[0] = 1'b1;
            a_source_i[0 +: DATA_W] = a_k1;
            b_source_i[0 +: DATA_W] = b_k1;

            @(negedge clk);
            clear_cluster_input();
        end
    endtask

    // 真实结果到达才产生 done。这样测试中的 RUNNING 生命周期与未来 collector
    // 契约相同，而不是把 scheduler 的“描述符已发完”误当成计算完成。
    task automatic wait_result_and_send_done;
        input [TAG_W-1:0] expected_tag;
        input signed [ACC_W-1:0] expected_c00;
        begin
            while (c_tile_valid_o === 16'b0)
                @(negedge clk);

            if (c_tile_valid_o !== 16'h0001)
                report_error("1x1 group-0 packet produced unexpected tile-valid mask");
            if ((c_active_rows_m1_o[1:0] !== 2'b00) ||
                (c_active_cols_m1_o[1:0] !== 2'b00))
                report_error("1x1 result shape sideband mismatch");
            if ($signed(c_matrix_o[0 +: ACC_W]) !== expected_c00) begin
                $display("ERROR command_dispatcher_runtime_joint C00 expected=%0d actual=%0d",
                         expected_c00, $signed(c_matrix_o[0 +: ACC_W]));
                errors = errors + 1;
            end
            if (cluster_idle_w)
                report_error("runtime reported idle while result valid was asserted");
            if (!exec_done_ready_o)
                report_error("dispatcher could not accept done for completed command");

            exec_done_tag_i = expected_tag;
            exec_done_error_i = 1'b0;
            exec_done_valid_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            exec_done_valid_i = 1'b0;
        end
    endtask

    task automatic consume_response;
        input [TAG_W-1:0] expected_tag;
        input [2:0] expected_status;
        input integer stall_cycles;
        integer stall_i;
        begin
            cmd_rsp_ready_i = 1'b0;
            while (cmd_rsp_valid_o !== 1'b1)
                @(negedge clk);
            for (stall_i = 0; stall_i < stall_cycles;
                 stall_i = stall_i + 1)
                @(negedge clk);
            if ((cmd_rsp_tag_o !== expected_tag) ||
                (cmd_rsp_status_o !== expected_status)) begin
                $display("ERROR command_dispatcher_runtime_joint response expected tag=%h status=%b actual tag=%h status=%b",
                         expected_tag, expected_status,
                         cmd_rsp_tag_o, cmd_rsp_status_o);
                errors = errors + 1;
            end
            cmd_rsp_ready_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            cmd_rsp_ready_i = 1'b0;
        end
    endtask

    // 统一协议监视器。握手在上升沿前采样，稳定性在 NBA 更新后检查。
    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (resetn) begin
            if (cmd_valid_i && cmd_ready_o)
                accepted_count = accepted_count + 1;
            if (exec_cmd_valid_o && exec_cmd_ready_i)
                executed_count = executed_count + 1;
            if (exec_done_valid_i && exec_done_ready_o)
                done_count = done_count + 1;
            if (cmd_rsp_valid_o && cmd_rsp_ready_i)
                response_count = response_count + 1;
            if (cluster_cfg_valid_w && cluster_cfg_ready_w) begin
                if ((cfg_fire_count == 0) &&
                    (cluster_cfg_mode_w !== MODE_4X8X8))
                    report_error("first cfg transaction was not mode 01");
                if ((cfg_fire_count == 1) &&
                    (cluster_cfg_mode_w !== MODE_16X4X4))
                    report_error("second cfg transaction was not mode 10");
                if (cfg_fire_count >= 2)
                    report_error("unexpected extra runtime cfg transaction");
                cfg_fire_count = cfg_fire_count + 1;
            end
            if (|c_tile_valid_o)
                result_count = result_count + 1;

            if (exec_active_o && cluster_cfg_valid_w)
                report_error("next mode request started while current command was RUNNING");
            if (cluster_cfg_valid_w && (cluster_cfg_mode_w == 2'b11))
                report_error("illegal mode reached runtime cfg interface");
            if (cluster_cfg_error_w)
                report_error("real runtime cluster unexpectedly reported cfg_error");
        end

        #1;
        if (!resetn) begin
            exec_stalled_r = 1'b0;
            response_stalled_r = 1'b0;
            cfg_stalled_r = 1'b0;
        end else begin
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
                response_stall_cycles = response_stall_cycles + 1;
                if (response_stalled_r &&
                    ({cmd_rsp_tag_o, cmd_rsp_status_o} !==
                     stalled_response_bundle_r))
                    report_error("command response changed during backpressure");
                response_stalled_r = 1'b1;
                stalled_response_bundle_r =
                    {cmd_rsp_tag_o, cmd_rsp_status_o};
            end else begin
                response_stalled_r = 1'b0;
            end

            if (cluster_cfg_valid_w && !cluster_cfg_ready_w) begin
                if (cfg_stalled_r &&
                    (cluster_cfg_mode_w !== stalled_cfg_mode_r))
                    report_error("runtime cfg mode changed during backpressure");
                cfg_stalled_r = 1'b1;
                stalled_cfg_mode_r = cluster_cfg_mode_w;
            end else begin
                cfg_stalled_r = 1'b0;
            end
        end
    end

    integer i;
    integer cfg_before_invalid;
    initial begin
        clear_cluster_input();

        for (i = 0; i < 3; i = i + 1) begin
            op_v[i] = OPCODE_GEMM;
            m_v[i] = 8'd1;
            n_v[i] = 8'd1;
            k_v[i] = 8'd2;
            layout_v[i] = 3'd0;
            a_base_v[i] = 16'h1000 + i*16;
            b_base_v[i] = 16'h2000 + i*16;
            c_base_v[i] = 16'h3000 + i*16;
            a_bank_v[i] = i[0];
            b_bank_v[i] = ~i[0];
            c_bank_v[i] = i[0];
            op_cfg_v[i] = 12'h600 + i;
            tag_v[i] = 8'h31 + i;
        end
        mode_v[0] = MODE_4X8X8;
        mode_v[1] = MODE_16X4X4;
        mode_v[2] = 2'b11;

        // reset 期间不能接收伪命令，也不能产生 cfg/exec/response。
        cmd_valid_i = 1'b1;
        repeat (4) @(posedge clk);
        #1;
        if (cmd_ready_o || exec_cmd_valid_o || cmd_rsp_valid_o ||
            cluster_cfg_valid_w)
            report_error("reset exposed an active command handshake");
        @(negedge clk);
        cmd_valid_i = 1'b0;
        resetn = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (!queue_empty_o || queue_full_o || dispatcher_busy_o ||
            exec_active_o || !cluster_idle_w)
            report_error("joint subsystem did not enter idle state after reset");

        // executor 暂停时三条命令仍可先进入 FIFO，证明入口与执行生命周期解耦。
        enqueue_command(0);
        enqueue_command(1);
        enqueue_command(2);
        repeat (2) @(posedge clk);
        if (accepted_count != 3)
            report_error("not all queued commands were accepted");

        // command 0：runtime 先切到 mode 01，执行端再接收完整命令。
        accept_exec_command(0, 2);
        if (cfg_fire_count != 1)
            report_error("mode 01 command did not generate exactly one cfg transaction");

        // command 1 已经位于 FIFO head，但 command 0 RUNNING 时不允许申请 mode 10。
        repeat (4) begin
            @(posedge clk);
            #1;
            if (cluster_cfg_valid_w || exec_cmd_valid_o)
                report_error("next command advanced before first exec_done");
        end

        // C00 = 2*3 + (-4)*5 = -14。真实结果出现后才退休 command 0。
        drive_k2_1x1_packet(8'sd2, 8'sd3, -8'sd4, 8'sd5);
        wait_result_and_send_done(tag_v[0], -32'sd14);

        // 故意不接收 command 0 response。dispatcher 仍应完成下一次 mode 切换并
        // 给出 command 1；response 的一深槽只在下一次 done 时才形成反压。
        while (cmd_rsp_valid_o !== 1'b1)
            @(negedge clk);
        accept_exec_command(1, 2);
        if (cfg_fire_count != 2)
            report_error("mode 10 command did not generate exactly one cfg transaction");
        if ((cmd_rsp_tag_o !== tag_v[0]) ||
            (cmd_rsp_status_o !== RSP_OK))
            report_error("first response was not held while second command issued");
        consume_response(tag_v[0], RSP_OK, 0);

        // C00 = (-3)*(-2) + 6*4 = 30。该结果不能被模式切换或前一响应反压丢失。
        drive_k2_1x1_packet(-8'sd3, -8'sd2, 8'sd6, 8'sd4);
        wait_result_and_send_done(tag_v[1], 32'sd30);

        // command 2 已经是非法 head。消费 command 1 response 的同一拍允许错误
        // response 弹性替换，但非法命令绝不能产生第三次 cfg 或 exec。
        cfg_before_invalid = cfg_fire_count;
        consume_response(tag_v[1], RSP_OK, 2);
        consume_response(tag_v[2], RSP_ILLEGAL_MODE, 2);
        if (cfg_fire_count != cfg_before_invalid)
            report_error("illegal mode command reached real runtime cfg");

        repeat (5) @(posedge clk);
        #1;
        if (!queue_empty_o || queue_full_o || dispatcher_busy_o ||
            exec_active_o || exec_cmd_valid_o || cmd_rsp_valid_o)
            report_error("dispatcher did not return to empty idle state");
        if (!cluster_idle_w ||
            (cluster_active_mode_w !== MODE_16X4X4))
            report_error("runtime did not finish idle in the last legal mode");
        if (accepted_count != 3)
            report_error("accepted command count mismatch");
        if (executed_count != 2)
            report_error("illegal command reached executor or legal command was lost");
        if (done_count != 2)
            report_error("done handshake count mismatch");
        if (response_count != 3)
            report_error("not every accepted command produced one response");
        if (cfg_fire_count != 2)
            report_error("runtime cfg transaction count mismatch");
        if (result_count != 2)
            report_error("one of the two real runtime results was lost or duplicated");
        if (response_stall_cycles < 3)
            report_error("command response backpressure was not exercised");

        if (errors == 0) begin
            $display("NPU_V13_COMMAND_DISPATCHER_RUNTIME_JOINT_TB_PASS accepted=%0d executed=%0d responses=%0d cfg_fires=%0d results=%0d rsp_stalls=%0d",
                     accepted_count, executed_count, response_count,
                     cfg_fire_count, result_count, response_stall_cycles);
        end else begin
            $display("NPU_V13_COMMAND_DISPATCHER_RUNTIME_JOINT_TB_FAIL errors=%0d",
                     errors);
            $fatal(1, "command dispatcher/runtime joint self-check failed");
        end
        $finish;
    end

    initial begin
        #400000;
        $display("NPU_V13_COMMAND_DISPATCHER_RUNTIME_JOINT_TB_TIMEOUT");
        $fatal(1, "command dispatcher/runtime joint timeout");
    end
endmodule
