// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 一级联合夹具：真实A/B双bank + 保留式租约 + 宏块调度 + 可复用packet数据面。
// host装载不是DDR/MIG模型；此顶层证明读/算/排空闭环，正式命令队列在二级联合接入。
module npu_v13_result_backend_joint #(
    parameter integer MAX_MN=128,MAX_K=512,TOTAL_SLOTS=32,CAPTURE_SLOTS=4,
    parameter integer AW=$clog2((MAX_MN/16)*MAX_K),UW=$clog2(TOTAL_SLOTS+1)
)(
    input wire clk,resetn, // 单计算域控制复位；RAM内容不复位。
    input wire load_begin_valid_i, // 请求重装一个bank；使用中的bank不可重装。
    output wire load_begin_ready_o, // 对应bank可以进入LOADING。
    input wire load_begin_operand_i,load_begin_bank_i, // 0=A/1=B，物理bank0/1。
    input wire load_valid_i, // 有效的128bit装载数据。
    output wire load_ready_o, // 指定bank处于LOADING才接受。
    input wire load_operand_i,load_bank_i, // 数据目标，允许与计算所用bank独立。
    input wire [AW-1:0] load_addr_i, // panel word=(axis/16)*MAX_K+k。
    input wire [127:0] load_data_i, // 16个INT8；A按行、B按列。
    input wire load_finish_valid_i, // 所有写请求结束后发布READY。
    output wire load_finish_ready_o, // 最后一个写已经真正落入BRAM。
    input wire load_finish_operand_i,load_finish_bank_i, // 待发布的operand/bank。
    input wire cmd_valid_i, // 当前bank内GEMM宏块命令。
    output wire cmd_ready_o, // 合法配置、A/B均READY且后端空闲。
    input wire [15:0] cmd_m_i,cmd_n_i,cmd_k_i,cmd_tag_i, // 动态实际尺寸与tag。
    input wire cmd_a_bank_i,cmd_b_bank_i, // A/B可分别选择bank。
    input wire allow_beat_i, // 给新BRAM读插入气泡，不取消在途返回。
    output wire [3:0] c_valid_o, // 四组P4输出，按坐标消费，组间无顺序保证。
    input wire [3:0] c_ready_i, // 独立下游反压。
    output wire [511:0] c_data_o, // 四组各128bit INT32。
    output wire [15:0] c_keep_o, // 四组各4bit元素mask。
    output wire [63:0] c_m_o,c_n_o,c_tag_o, // 四组各16bit坐标/tag。
    output wire [3:0] c_tile_last_o, // 各组当前字为该tile第四行。
    output wire done_valid_o, // 最后结果已消费，但bank直到done握手才归还。
    input wire done_ready_i, // 上层接受完成回应。
    output wire [15:0] done_tag_o, // 完成任务标识。
    output wire done_error_o,busy_o, // 完成错误、包含done等待的忙状态。
    output wire [3:0] retained_o, // A0/A1/B0/B1 READY，可重复消费。
    output wire input_beat_o,packet_issue_o,reserve_wait_o, // 性能观测事件。
    output wire [4*UW-1:0] slots_used_o, // 四组已预约结果槽数。
    output wire [15:0] pending_o,outstanding_o, // 独立生命周期计数。
    output wire error_o // 租约/计算/缓存错误汇总。
);
    wire [3:0] loading;
    wire lease_ready,lease_error,finish_ready,writes_pending;
    reg a_bank_r,b_bank_r;
    wire config_ok=cmd_m_i>0 && cmd_n_i>0 && cmd_k_i>0 && cmd_m_i<=MAX_MN && cmd_n_i<=MAX_MN && cmd_k_i<=MAX_K;
    assign cmd_ready_o=resetn && !busy_o && config_ok && lease_ready;
    wire start=cmd_valid_i && cmd_ready_o;
    always @(posedge clk) if(start) begin a_bank_r<=cmd_a_bank_i;b_bank_r<=cmd_b_bank_i;end
    panel_lease_exp u_lease(.clk(clk),.resetn(resetn),.begin_valid_i(load_begin_valid_i),.begin_ready_o(load_begin_ready_o),
        .begin_operand_i(load_begin_operand_i),.begin_bank_i(load_begin_bank_i),
        .finish_valid_i(load_finish_valid_i && !writes_pending),.finish_ready_o(finish_ready),
        .finish_operand_i(load_finish_operand_i),.finish_bank_i(load_finish_bank_i),
        .acquire_valid_i(start),.acquire_ready_o(lease_ready),.acquire_a_bank_i(cmd_a_bank_i),.acquire_b_bank_i(cmd_b_bank_i),
        .release_i(done_valid_o && done_ready_i),.loading_o(loading),.retained_o(retained_o),.error_o(lease_error));
    assign load_ready_o=resetn && loading[{load_operand_i,load_bank_i}];
    assign load_finish_ready_o=finish_ready && !writes_pending;
    wire rd_valid,ram_valid;
    wire [AW-1:0] rd_a,rd_b;
    wire [127:0] ram_a,ram_b;
    panel_ram_exp #(.G(16),.S(1),.MAX_MN(MAX_MN),.MAX_K(MAX_K)) u_ram(
        .clk(clk),.resetn(resetn),.wr_valid_i(load_valid_i && load_ready_o),.wr_operand_i(load_operand_i),
        .wr_bank_i(load_bank_i),.wr_addr_i(load_addr_i),.wr_half_i(1'b0),.wr_data_i(load_data_i),.writes_pending_o(writes_pending),
        .rd_valid_i(rd_valid),.rd_a_bank_i(a_bank_r),.rd_b_bank_i(b_bank_r),.rd_a_addr_i(rd_a),.rd_b_addr_i(rd_b),
        .rd_valid_o(ram_valid),.rd_a_o(ram_a),.rd_b_o(ram_b));
    wire dv,dr,all_issued;
    wire [15:0] dm,dn,dk;
    wire [4:0] rows,cols;
    wire [AW-1:0] da,db;
    panel_scheduler_exp #(.G(16),.S(1),.MAX_MN(MAX_MN),.MAX_K(MAX_K),.AW(AW)) u_scheduler(
        .clk(clk),.resetn(resetn),.start_i(start),.m_i(cmd_m_i),.n_i(cmd_n_i),.k_i(cmd_k_i),
        .packet_valid_o(dv),.packet_ready_i(dr),.m_base_o(dm),.n_base_o(dn),.rows_o(rows),.cols_o(cols),
        .steps_o(dk),.last_lanes_o(),.a_base_o(da),.b_base_o(db),.issued_all_o(all_issued));
    wire backend_error;
    npu_v13_packet_backend #(.AW(AW),.MAX_K(MAX_K),.TOTAL_SLOTS(TOTAL_SLOTS),.CAPTURE_SLOTS(CAPTURE_SLOTS)) u_backend(
        .cfg_valid_i(1'b0),.cfg_mode_i(2'b00),.cfg_ready_o(),.cfg_error_o(),.active_mode_o(),.cluster_idle_o(),
        .clk(clk),.resetn(resetn),.start_i(start),.tag_i(cmd_tag_i),.buffers_owned_i(busy_o),.schedule_finished_i(all_issued),
        .desc_valid_i(dv),.desc_ready_o(dr),.desc_a_i(da),.desc_b_i(db),.desc_k_i(dk),.desc_m_i(dm),.desc_n_i(dn),
        .desc_rows_i(rows),.desc_cols_i(cols),.allow_beat_i(allow_beat_i),.rd_valid_o(rd_valid),.rd_a_addr_o(rd_a),.rd_b_addr_o(rd_b),
        .ram_valid_i(ram_valid),.ram_a_i(ram_a),.ram_b_i(ram_b),.c_valid_o(c_valid_o),.c_ready_i(c_ready_i),.c_data_o(c_data_o),
        .c_keep_o(c_keep_o),.c_m_o(c_m_o),.c_n_o(c_n_o),.c_tag_o(c_tag_o),.c_tile_last_o(c_tile_last_o),
        .done_valid_o(done_valid_o),.done_ready_i(done_ready_i),.done_tag_o(done_tag_o),.done_error_o(done_error_o),.busy_o(busy_o),
        .input_beat_o(input_beat_o),.packet_issue_o(packet_issue_o),.reserve_wait_o(reserve_wait_o),
        .slots_used_o(slots_used_o),.pending_o(pending_o),.outstanding_o(outstanding_o),.error_o(backend_error));
    assign error_o=lease_error || backend_error;
    // synthesis translate_off
    initial if(MAX_MN%16!=0 || MAX_MN>65535 || MAX_K<1 || MAX_K>65535) $fatal(1,"invalid panel capacity");
    // synthesis translate_on
endmodule
