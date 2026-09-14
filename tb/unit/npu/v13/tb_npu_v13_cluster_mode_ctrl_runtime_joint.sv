// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// cluster_mode_ctrl + systolic_cluster_runtime_stream 联合自检。
//
// 本 TB 不重复完整矩阵数值回归，完整三模式计算由 runtime cluster 自身 TB
// 负责；这里重点验证两个真实模块之间的控制契约：
//   1. mode controller 的 cfg 输出直接连接 runtime cluster；
//   2. 计算 packet 尚未结束或结果尚未排空时，runtime cfg_ready 保持为 0；
//   3. mode controller 保存目标模式并保持 cfg 请求；
//   4. 原 packet 的结果正常返回后，模式才切换并产生成功 response；
//   5. 非法模式不会到达 runtime cluster，也不会触发其 cfg_error。
//////////////////////////////////////////////////////////////////////////////////
module tb_npu_v13_cluster_mode_ctrl_runtime_joint;
    localparam integer DATA_W = 8;
    localparam integer ACC_W = 32;
    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg resetn = 1'b0;

    reg         mode_req_valid_i = 1'b0;
    wire        mode_req_ready_o;
    reg  [1:0]  mode_req_mode_i = MODE_16X16;
    wire        mode_rsp_valid_o;
    reg         mode_rsp_ready_i = 1'b0;
    wire [1:0]  mode_rsp_mode_o;
    wire        mode_rsp_error_o;
    wire        mode_busy_o;

    wire        cluster_cfg_valid_w;
    wire [1:0]  cluster_cfg_mode_w;
    wire        cluster_cfg_ready_w;
    wire        cluster_cfg_error_w;
    wire [1:0]  cluster_active_mode_w;
    wire        cluster_idle_w;

    reg  [15:0] s_axis_tvalid_i = 16'b0;
    reg  [15:0] s_axis_tuser_i = 16'b0;
    reg  [15:0] s_axis_tlast_i = 16'b0;
    reg  [31:0] active_rows_m1_i = 32'b0;
    reg  [31:0] active_cols_m1_i = 32'b0;
    reg  [16*4*DATA_W-1:0] a_source_i = 0;
    reg  [16*4*DATA_W-1:0] b_source_i = 0;
    wire [15:0] c_tile_valid_o;
    wire [31:0] c_active_rows_m1_o;
    wire [31:0] c_active_cols_m1_o;
    wire [16*16*ACC_W-1:0] c_matrix_o;

    integer errors = 0;
    integer cfg_fire_count = 0;
    integer cfg_stall_cycles = 0;
    integer result_count = 0;

    npu_v13_cluster_mode_ctrl u_mode_ctrl (
        .clk                    (clk),
        .resetn                 (resetn),
        .mode_req_valid_i       (mode_req_valid_i),
        .mode_req_ready_o       (mode_req_ready_o),
        .mode_req_mode_i        (mode_req_mode_i),
        .mode_rsp_valid_o       (mode_rsp_valid_o),
        .mode_rsp_ready_i       (mode_rsp_ready_i),
        .mode_rsp_mode_o        (mode_rsp_mode_o),
        .mode_rsp_error_o       (mode_rsp_error_o),
        .mode_busy_o            (mode_busy_o),
        .cluster_cfg_valid_o    (cluster_cfg_valid_w),
        .cluster_cfg_mode_o     (cluster_cfg_mode_w),
        .cluster_cfg_ready_i    (cluster_cfg_ready_w),
        .cluster_cfg_error_i    (cluster_cfg_error_w),
        .cluster_active_mode_i  (cluster_active_mode_w)
    );

    npu_v13_systolic_cluster_runtime_stream #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_runtime_cluster (
        .clk                    (clk),
        .resetn                 (resetn),
        .cfg_valid_i            (cluster_cfg_valid_w),
        .cfg_mode_i             (cluster_cfg_mode_w),
        .cfg_ready_o            (cluster_cfg_ready_w),
        .cfg_error_o            (cluster_cfg_error_w),
        .active_mode_o          (cluster_active_mode_w),
        .cluster_idle_o         (cluster_idle_w),
        .s_axis_tvalid_i        (s_axis_tvalid_i),
        .s_axis_tuser_i         (s_axis_tuser_i),
        .s_axis_tlast_i         (s_axis_tlast_i),
        .active_rows_m1_i       (active_rows_m1_i),
        .active_cols_m1_i       (active_cols_m1_i),
        .a_source_i             (a_source_i),
        .b_source_i             (b_source_i),
        .c_tile_valid_o         (c_tile_valid_o),
        .c_active_rows_m1_o     (c_active_rows_m1_o),
        .c_active_cols_m1_o     (c_active_cols_m1_o),
        .c_matrix_o             (c_matrix_o)
    );

    task automatic report_error;
        input [8*180-1:0] message;
        begin
            $display("ERROR mode_ctrl_runtime_joint %0s", message);
            errors = errors + 1;
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

    task automatic submit_mode_request;
        input [1:0] requested_mode;
        begin
            @(negedge clk);
            mode_req_mode_i = requested_mode;
            mode_req_valid_i = 1'b1;
            while (mode_req_ready_o !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            #1;
            @(negedge clk);
            mode_req_valid_i = 1'b0;
        end
    endtask

    task automatic take_mode_response;
        input [1:0] expected_mode;
        input       expected_error;
        begin
            while (mode_rsp_valid_o !== 1'b1)
                @(negedge clk);
            if (mode_rsp_mode_o !== expected_mode)
                report_error("response mode mismatch");
            if (mode_rsp_error_o !== expected_error)
                report_error("response error mismatch");
            @(negedge clk);
            mode_rsp_ready_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mode_rsp_ready_i = 1'b0;
        end
    endtask

    // 在当前 4x8x8 模式的 group 0 上发送一个 beat。使用 1x1 shape 和零数据，
    // 数值结果必为 0；first/last 分开可以让 packet_open 跨周期保持为 1。
    task automatic drive_group0_beat;
        input first_beat;
        input last_beat;
        begin
            @(negedge clk);
            clear_cluster_input();
            s_axis_tvalid_i[0] = 1'b1;
            s_axis_tuser_i[0] = first_beat;
            s_axis_tlast_i[0] = last_beat;
            active_rows_m1_i[0 +: 3] = 3'd0;
            active_cols_m1_i[0 +: 3] = 3'd0;
            @(posedge clk);
            #1;
            @(negedge clk);
            clear_cluster_input();
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (resetn) begin
            if (cluster_cfg_valid_w && cluster_cfg_ready_w)
                cfg_fire_count = cfg_fire_count + 1;
            if (cluster_cfg_valid_w && !cluster_cfg_ready_w)
                cfg_stall_cycles = cfg_stall_cycles + 1;
            if (|c_tile_valid_o) begin
                result_count = result_count + 1;
                if (c_tile_valid_o !== 16'h0001)
                    report_error("unexpected tile-valid mask for 1x1 group-0 packet");
                if ((c_active_rows_m1_o[1:0] !== 2'd0) ||
                    (c_active_cols_m1_o[1:0] !== 2'd0))
                    report_error("result shape sideband mismatch");
                if ($signed(c_matrix_o[0 +: ACC_W]) !== 0)
                    report_error("zero-input packet returned nonzero result");
            end
            if (cluster_cfg_error_w)
                report_error("runtime cluster unexpectedly reported cfg_error");
            if (!cluster_idle_w && cluster_cfg_ready_w)
                report_error("runtime cfg_ready asserted before complete drain");
        end
    end

    initial begin
        clear_cluster_input();
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        repeat (2) @(posedge clk);

        // 默认已经是 16x16，同模式请求不应触发真实 cfg。
        submit_mode_request(MODE_16X16);
        take_mode_response(MODE_16X16, 1'b0);
        if (cfg_fire_count != 0)
            report_error("same-mode request reached runtime cfg");

        // 空闲状态下切换到 4x8x8。
        submit_mode_request(MODE_4X8X8);
        take_mode_response(MODE_4X8X8, 1'b0);
        if ((cluster_active_mode_w !== MODE_4X8X8) ||
            (cfg_fire_count != 1))
            report_error("idle mode switch failed");

        // 打开一个 K=2 packet，但先不发送 TLAST。
        drive_group0_beat(1'b1, 1'b0);
        if (cluster_idle_w)
            report_error("cluster stayed idle with an open packet");

        // 集群忙时提交下一模式。控制器应接收并保存，而 runtime 不得握手。
        submit_mode_request(MODE_16X4X4);
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!cluster_cfg_valid_w || cluster_cfg_ready_w ||
                (cluster_cfg_mode_w !== MODE_16X4X4))
                report_error("pending mode request not held while cluster busy");
            if (mode_rsp_valid_o)
                report_error("mode response arrived before old packet drained");
        end

        // 关闭旧 packet。mode 请求继续等待结果流水完全排空。
        drive_group0_beat(1'b0, 1'b1);
        while (mode_rsp_valid_o !== 1'b1)
            @(negedge clk);

        if (result_count != 1)
            report_error("old-mode packet result was lost during mode wait");
        if (cfg_stall_cycles < 10)
            report_error("mode cfg did not remain blocked through result drain");
        if ((cluster_active_mode_w !== MODE_16X4X4) ||
            mode_rsp_error_o || (cfg_fire_count != 2))
            report_error("busy-to-idle mode switch did not complete correctly");

        // 故意反压完成响应，确认真实 cluster 已切换后 response 仍能保持。
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!mode_rsp_valid_o || !mode_busy_o ||
                (mode_rsp_mode_o !== MODE_16X4X4) || mode_rsp_error_o)
                report_error("joint response was not held under backpressure");
        end
        take_mode_response(MODE_16X4X4, 1'b0);

        // 非法模式由 controller 本地消化，runtime 不应产生第三次 cfg。
        submit_mode_request(2'b11);
        take_mode_response(2'b11, 1'b1);
        if ((cfg_fire_count != 2) ||
            (cluster_active_mode_w !== MODE_16X4X4))
            report_error("illegal mode leaked into runtime cluster");

        repeat (4) @(posedge clk);
        if (errors == 0)
            $display("NPU_V13_CLUSTER_MODE_CTRL_RUNTIME_JOINT_TB_PASS cfg_fires=%0d cfg_stall_cycles=%0d results=%0d",
                     cfg_fire_count, cfg_stall_cycles, result_count);
        else
            $display("NPU_V13_CLUSTER_MODE_CTRL_RUNTIME_JOINT_TB_FAIL errors=%0d",
                     errors);
        $finish;
    end

    initial begin
        #30000;
        $display("TB_TIMEOUT mode_ctrl_runtime_joint");
        $finish;
    end
endmodule
