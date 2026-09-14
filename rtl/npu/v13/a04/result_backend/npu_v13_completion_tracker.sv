// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 只跟踪生命周期，不缓存数据。计数单位是物理tile结果，不是P4字或整个packet。
// pending=预约-返回；outstanding=预约-最终退休。schedule_finished不能代替排空。
module npu_v13_completion_tracker #(parameter integer CW=16)(
    input wire clk, // 所有事件均已同步到本时钟。
    input wire resetn, // 与执行器/缓存一起复位。
    input wire start_i, // 新任务开始脉冲；要求上一任务完成响应已经消费。
    input wire [15:0] tag_i, // start同拍采样的命令标识。
    input wire [4:0] reserve_count_i, // 本拍预约的有效tile数，0..16。
    input wire [4:0] capture_count_i, // 本拍计算返回的tile数，0..16。
    input wire [2:0] retire_count_i, // 四组本拍最终消费tile末字数，0..4。
    input wire schedule_finished_i, // 本命令描述符已经全部交付。
    input wire issue_idle_i, // issue没有暂存/尚未交付的描述符。
    input wire feeder_idle_i, // A/B请求和返回流水都为空。
    input wire results_empty_i, // 四组槽池全部为空。
    input wire backend_error_i, // 后端错误累计到完成回报；错误也必须安全排空。
    output wire done_valid_o, // 安全完成响应，等待ready期间保持。
    input wire done_ready_i, // 执行器接受完成响应。
    output wire [15:0] done_tag_o, // 原始命令tag。
    output wire done_error_o, // 任意协议/后端错误。
    output wire busy_o, // 包含完成响应等待。
    output wire [CW-1:0] pending_o,outstanding_o // 调试守恒计数，不参与数据选择。
);
    reg active_r,done_r,error_r;
    reg [15:0] tag_r;
    reg [CW-1:0] pending_r,outstanding_r;
    // 用定宽全1常量，避免(1<<CW)在CW>=32时受宿主integer宽度影响。
    localparam [CW:0] MAX_COUNT={1'b0,{CW{1'b1}}};
    assign busy_o=active_r;
    assign done_valid_o=resetn && done_r;
    assign done_tag_o=tag_r;assign done_error_o=error_r;
    assign pending_o=pending_r;assign outstanding_o=outstanding_r;
    always @(posedge clk) begin
        if(!resetn) begin active_r<=0;done_r<=0;error_r<=0;pending_r<=0;outstanding_r<=0;tag_r<=0;end
        else begin
            if(start_i && !active_r) begin
                active_r<=1;done_r<=0;error_r<=0;tag_r<=tag_i;pending_r<=0;outstanding_r<=0;
            end
            if(active_r && !done_r) begin
                pending_r<=pending_r+reserve_count_i-capture_count_i;
                outstanding_r<=outstanding_r+reserve_count_i-retire_count_i;
                if(backend_error_i || capture_count_i>pending_r || retire_count_i>outstanding_r ||
                   ({1'b0,outstanding_r}+reserve_count_i)>MAX_COUNT) error_r<=1;
                // 检查本拍无新事件，避免在最后一次提交恰逢计数旧值为零时提前完成。
                if(schedule_finished_i && issue_idle_i && feeder_idle_i && results_empty_i &&
                   pending_r==0 && outstanding_r==0 && reserve_count_i==0 && capture_count_i==0 && retire_count_i==0)
                    done_r<=1;
            end
            if(done_valid_o && done_ready_i) begin done_r<=0;active_r<=0;end
            if(start_i && active_r) error_r<=1;
        end
    end
endmodule
