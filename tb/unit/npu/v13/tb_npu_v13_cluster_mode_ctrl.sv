// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// npu_v13_cluster_mode_ctrl 独立自检。
//
// 使用一个可控的 mock cluster 覆盖：
//   1. 目标 mode 已生效时不产生 cfg 事务；
//   2. cfg_ready 反压期间 cfg_valid/cfg_mode 保持稳定；
//   3. cfg 握手后等待 active_mode 确认，再返回成功 response；
//   4. response 反压期间所有响应字段保持稳定；
//   5. 非法 2'b11 在本地拒绝，不发送给 cluster；
//   6. cluster cfg_error 被转换成错误 response；
//   7. 等待 cfg 时复位能够取消 outstanding 请求。
//////////////////////////////////////////////////////////////////////////////////
module tb_npu_v13_cluster_mode_ctrl;
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

    wire        cluster_cfg_valid_o;
    wire [1:0]  cluster_cfg_mode_o;
    reg         cluster_cfg_ready_i = 1'b0;
    reg         cluster_cfg_error_i = 1'b0;
    reg  [1:0]  cluster_active_mode_i = MODE_16X16;

    reg mock_force_error = 1'b0;
    integer errors = 0;
    integer accepted_requests = 0;
    integer accepted_responses = 0;
    integer cluster_cfg_fires = 0;

    reg cfg_stalled_r = 1'b0;
    reg [1:0] stalled_cfg_mode_r = 2'b00;
    reg rsp_stalled_r = 1'b0;
    reg [1:0] stalled_rsp_mode_r = 2'b00;
    reg stalled_rsp_error_r = 1'b0;

    npu_v13_cluster_mode_ctrl dut (
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
        .cluster_cfg_valid_o    (cluster_cfg_valid_o),
        .cluster_cfg_mode_o     (cluster_cfg_mode_o),
        .cluster_cfg_ready_i    (cluster_cfg_ready_i),
        .cluster_cfg_error_i    (cluster_cfg_error_i),
        .cluster_active_mode_i  (cluster_active_mode_i)
    );

    task automatic report_error;
        input [8*160-1:0] message;
        begin
            $display("ERROR mode_ctrl %0s", message);
            errors = errors + 1;
        end
    endtask

    // 发送方只需要把请求保持到 ready/valid 握手；握手后即可立即修改输入。
    task automatic send_request;
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

    task automatic consume_response;
        input [1:0] expected_mode;
        input       expected_error;
        begin
            while (mode_rsp_valid_o !== 1'b1)
                @(negedge clk);
            if (mode_rsp_mode_o !== expected_mode)
                report_error("response mode mismatch");
            if (mode_rsp_error_o !== expected_error)
                report_error("response error flag mismatch");

            @(negedge clk);
            mode_rsp_ready_i = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mode_rsp_ready_i = 1'b0;
        end
    endtask

    // mock cluster：每次合法 cfg 握手后，要么更新 active_mode，要么在下一拍
    // 给出 cfg_error。非阻塞赋值保证其时序与真实 runtime cluster 相同。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cluster_active_mode_i <= MODE_16X16;
            cluster_cfg_error_i <= 1'b0;
        end else begin
            cluster_cfg_error_i <= 1'b0;
            if (cluster_cfg_valid_o && cluster_cfg_ready_i) begin
                if (mock_force_error)
                    cluster_cfg_error_i <= 1'b1;
                else
                    cluster_active_mode_i <= cluster_cfg_mode_o;
            end
        end
    end

    // 协议监视器：统计事务，并检查两个 ready/valid 接口在反压时保持稳定。
    always @(posedge clk) begin
        // ready/valid 握手必须在时钟沿瞬间采样；状态机可能在同一个沿后撤掉
        // valid，所以这些计数不能放到下面的 #1 之后。
        if (resetn) begin
            if (mode_req_valid_i && mode_req_ready_o)
                accepted_requests = accepted_requests + 1;
            if (mode_rsp_valid_o && mode_rsp_ready_i)
                accepted_responses = accepted_responses + 1;
            if (cluster_cfg_valid_o && cluster_cfg_ready_i)
                cluster_cfg_fires = cluster_cfg_fires + 1;
        end

        #1;
        if (!resetn) begin
            cfg_stalled_r = 1'b0;
            rsp_stalled_r = 1'b0;
        end else begin
            if (cluster_cfg_valid_o && !cluster_cfg_ready_i) begin
                if (cfg_stalled_r &&
                    (cluster_cfg_mode_o !== stalled_cfg_mode_r))
                    report_error("cfg_mode changed while cfg_ready was low");
                cfg_stalled_r = 1'b1;
                stalled_cfg_mode_r = cluster_cfg_mode_o;
            end else begin
                cfg_stalled_r = 1'b0;
            end

            if (mode_rsp_valid_o && !mode_rsp_ready_i) begin
                if (rsp_stalled_r &&
                    ((mode_rsp_mode_o !== stalled_rsp_mode_r) ||
                     (mode_rsp_error_o !== stalled_rsp_error_r)))
                    report_error("response changed while rsp_ready was low");
                rsp_stalled_r = 1'b1;
                stalled_rsp_mode_r = mode_rsp_mode_o;
                stalled_rsp_error_r = mode_rsp_error_o;
            end else begin
                rsp_stalled_r = 1'b0;
            end

            if ((cluster_cfg_valid_o === 1'b1) &&
                (cluster_cfg_mode_o === 2'b11))
                report_error("illegal mode reached cluster cfg interface");
        end
    end

    initial begin
        // Reset 后必须回到可接收请求、无伪 cfg/response 的状态。
        repeat (4) @(posedge clk);
        @(negedge clk);
        resetn = 1'b1;
        cluster_cfg_ready_i = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        if (!mode_req_ready_o || mode_busy_o || cluster_cfg_valid_o ||
            mode_rsp_valid_o)
            report_error("reset state is not idle");

        // 已经是 16x16：应直接成功，不访问 cluster cfg。
        send_request(MODE_16X16);
        consume_response(MODE_16X16, 1'b0);
        if (cluster_cfg_fires != 0)
            report_error("same-mode request generated cfg transaction");

        // 切换到 4x8x8，同时人为阻塞 cfg 三拍。
        cluster_cfg_ready_i = 1'b0;
        send_request(MODE_4X8X8);
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!cluster_cfg_valid_o ||
                (cluster_cfg_mode_o !== MODE_4X8X8))
                report_error("cfg request not held during backpressure");
            if (mode_rsp_valid_o)
                report_error("response arrived before cfg handshake");
        end
        @(negedge clk);
        cluster_cfg_ready_i = 1'b1;

        // 等 response 出现后继续反压三拍，检查字段保持和 busy 语义。
        while (mode_rsp_valid_o !== 1'b1)
            @(negedge clk);
        repeat (3) begin
            @(posedge clk);
            #1;
            if (!mode_rsp_valid_o || !mode_busy_o ||
                (mode_rsp_mode_o !== MODE_4X8X8) || mode_rsp_error_o)
                report_error("successful response was not held under backpressure");
        end
        consume_response(MODE_4X8X8, 1'b0);
        if (cluster_active_mode_i !== MODE_4X8X8)
            report_error("mock active mode did not update");
        if (cluster_cfg_fires != 1)
            report_error("unexpected cfg transaction count after legal switch");

        // 非法模式必须在本地报错，active_mode 和 cfg 计数都不能变化。
        send_request(2'b11);
        consume_response(2'b11, 1'b1);
        if ((cluster_active_mode_i !== MODE_4X8X8) ||
            (cluster_cfg_fires != 1))
            report_error("illegal request modified cluster state");

        // mock cluster 主动拒绝一次合法配置，控制器必须返回错误。
        mock_force_error = 1'b1;
        send_request(MODE_16X4X4);
        consume_response(MODE_16X4X4, 1'b1);
        mock_force_error = 1'b0;
        if (cluster_active_mode_i !== MODE_4X8X8)
            report_error("failed cfg changed active mode");

        // 同一个合法请求重试，确认错误事务不会锁死状态机。
        send_request(MODE_16X4X4);
        consume_response(MODE_16X4X4, 1'b0);
        if (cluster_active_mode_i !== MODE_16X4X4)
            report_error("retry did not update active mode");

        // 在 cfg_ready=0 的等待阶段复位，pending cfg 必须立即取消。
        cluster_cfg_ready_i = 1'b0;
        send_request(MODE_16X16);
        repeat (2) @(posedge clk);
        #1;
        if (!cluster_cfg_valid_o)
            report_error("reset test did not enter cfg wait state");
        @(negedge clk);
        resetn = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!mode_req_ready_o || mode_busy_o || cluster_cfg_valid_o ||
            mode_rsp_valid_o)
            report_error("reset did not cancel outstanding request");
        @(negedge clk);
        resetn = 1'b1;
        cluster_cfg_ready_i = 1'b1;

        repeat (3) @(posedge clk);
        if (accepted_requests != accepted_responses + 1)
            report_error("completed request/response accounting mismatch");

        if (errors == 0)
            $display("NPU_V13_CLUSTER_MODE_CTRL_TB_PASS requests=%0d responses=%0d cfg_fires=%0d",
                     accepted_requests, accepted_responses, cluster_cfg_fires);
        else
            $display("NPU_V13_CLUSTER_MODE_CTRL_TB_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #20000;
        $display("TB_TIMEOUT mode_ctrl");
        $finish;
    end
endmodule
