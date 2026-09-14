// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 第二批阶段性联合顶层：Kchunk控制 -> 正式命令后端/真实256DSP阵列 -> 四路PSUM。
// 当前顶层是resident GEMM panel，不冒充已完成CONV/DDR/量化/feature_store的完整NPU。
// A/B装载可以与另一个bank计算重叠；一个父输出panel的PSUM在全部Kchunk间保留。
// done成功目前表示PSUM final流全部握手；未来接store后还须额外等待写可见栅栏。
module npu_v13_multik_backend #(
    parameter integer LOAD_W=128,
    parameter integer MAX_MN=128,MAX_K=512,TOTAL_SLOTS=64,CAPTURE_SLOTS=4,FIFO_DEPTH=8,
    parameter integer AW=$clog2((MAX_MN/16)*MAX_K)
)(
    input wire clk,resetn, // 整条命令/存储/计算/PSUM同域协调复位。
    input wire job_valid_i, // 一个父输出panel任务；字段保持直到ready。
    output wire job_ready_o, // 当前父任务及完成响应都已结束。
    input wire [15:0] job_m_i,job_n_i,job_tag_i, // 动态panel尺寸和身份，尺寸不超过MAX_MN。
    input wire [31:0] job_k_i, // 全K长；可以跨任意多个合法resident Kchunk。
    input wire chunk_valid_i, // 按K递增提供已装载A/B的描述符。
    output wire chunk_ready_o, // 上一chunk已完成PSUM写可见栅栏。
    input wire [15:0] chunk_k_i, // 本段实际K，不超过MAX_K，不得超过父任务剩余K。
    input wire chunk_a_bank_i,chunk_b_bank_i,chunk_c_bank_i, // 正式buffer manager租约编号。
    input wire [31:0] chunk_a_base_i,chunk_b_base_i, // A/B BRAM word基址，非DDR字节地址。
    output wire done_valid_o, // 全K及final传输完成；非feature_store落盘完成。
    input wire done_ready_i, // 完成响应消费者，可反压。
    output wire [15:0] done_tag_o, // 父任务身份。
    output wire [2:0] done_status_o, // 参见kchunk_ctrl：0成功，1/2参数，3后端，4PSUM。
    output wire [31:0] k_done_o, // 已通过PSUM栅栏的K进度。
    input wire load_begin_valid_i, // 请求在FREE的A/B bank开始装载。
    output wire load_begin_ready_o,load_begin_error_o, // 装载申请握手/错误。
    input wire load_begin_operand_i,load_begin_bank_i, // operand0=A/1=B，bank0/1。
    input wire load_valid_i, // LOAD_W位搬运beat；64位在目标bank本地拼成128位。
    output wire load_ready_o, // 写目标必须LOADING且地址合法。
    input wire load_operand_i,load_bank_i, // 输入数据的独立A/B bank选择。
    input wire [AW+(LOAD_W==64)-1:0] load_addr_i, // LOAD_W-bit panel beat地址，不是DDR字节地址。
    input wire [LOAD_W-1:0] load_data_i, // 窄载荷保持到bank叶节点；计算读口仍128位。
    input wire load_finish_valid_i, // 装载结束或主动取消。
    output wire load_finish_ready_o,load_finish_error_o, // 最后写可见之后才确认finish。
    input wire load_finish_operand_i,load_finish_bank_i,load_finish_error_i, // finish目标与失败标记。
    input wire discard_valid_i, // 显式归还保留的输入panel以便重装，不能抢占IN_USE。
    output wire discard_ready_o,discard_error_o, // discard受理/合法性。
    input wire discard_operand_i,discard_bank_i, // 目标A/B及bank。
    input wire allow_beat_i, // 合法插入输入气泡；已发BRAM响应不取消。
    output wire [3:0] c_valid_o, // 四路最终INT32 P4流；中间Kchunk不会出现在这里。
    input wire [3:0] c_ready_i, // 四路独立消费反压。
    output wire [511:0] c_data_o, // 四组128bit跨K累加结果。
    output wire [15:0] c_keep_o, // 每组四个lane有效标记。
    output wire [63:0] c_m_o,c_n_o,c_tag_o, // 每组16bit panel相对坐标/tag，不能假定到达顺序。
    output wire [3:0] retained_o,loading_o,in_use_o, // 输入bank状态{B1,B0,A1,A0}。
    output wire input_beat_o,packet_issue_o, // 实际核心供数/packet发行性能事件。
    output wire [3:0] psum_commit_o, // 四路实际PSUM写/退休事件。
    output wire busy_o,error_o // 整条活动状态/后端协议故障；任务错误另见done_status。
);
    wire ctxv,ctxr,first,last,cmdv,cmdr,rspv,rspr,endv,endr,fv,fr,fe,ctrl_busy,backend_busy,psum_busy;
    wire [15:0] cm,cn,ct,bm,bn,bk,bt,rt;
    wire [2:0] rs;
    wire ab,bb,cb;wire [31:0] ap,bp;
    wire [3:0] cv,cr;wire [511:0] cd;wire [15:0] keep;wire [63:0] om,on,ot;
    npu_v13_kchunk_ctrl #(.MAX_M(MAX_MN),.MAX_N(MAX_MN),.MAX_K(MAX_K)) u_chunks(
        .clk(clk),.resetn(resetn),.job_valid_i(job_valid_i),.job_ready_o(job_ready_o),
        .job_m_i(job_m_i),.job_n_i(job_n_i),.job_tag_i(job_tag_i),.job_k_i(job_k_i),
        .chunk_valid_i(chunk_valid_i),.chunk_ready_o(chunk_ready_o),.chunk_k_i(chunk_k_i),
        .chunk_a_bank_i(chunk_a_bank_i),.chunk_b_bank_i(chunk_b_bank_i),.chunk_c_bank_i(chunk_c_bank_i),
        .chunk_a_base_i(chunk_a_base_i),.chunk_b_base_i(chunk_b_base_i),
        .ctx_valid_o(ctxv),.ctx_ready_i(ctxr),.ctx_m_o(cm),.ctx_n_o(cn),.ctx_tag_o(ct),.ctx_first_o(first),.ctx_final_o(last),
        .cmd_valid_o(cmdv),.cmd_ready_i(cmdr),.cmd_m_o(bm),.cmd_n_o(bn),.cmd_k_o(bk),.cmd_tag_o(bt),
        .cmd_a_bank_o(ab),.cmd_b_bank_o(bb),.cmd_c_bank_o(cb),.cmd_a_base_o(ap),.cmd_b_base_o(bp),
        .rsp_valid_i(rspv),.rsp_ready_o(rspr),.rsp_tag_i(rt),.rsp_status_i(rs),
        .end_valid_o(endv),.end_ready_i(endr),.fence_valid_i(fv),.fence_ready_o(fr),.fence_error_i(fe),
        .done_valid_o(done_valid_o),.done_ready_i(done_ready_i),.done_tag_o(done_tag_o),.done_status_o(done_status_o),
        .k_done_o(k_done_o),.busy_o(ctrl_busy));
    npu_v13_command_backend_joint #(.LOAD_W(LOAD_W),.MAX_MN(MAX_MN),.MAX_K(MAX_K),.TOTAL_SLOTS(TOTAL_SLOTS),
        .CAPTURE_SLOTS(CAPTURE_SLOTS),.FIFO_DEPTH(FIFO_DEPTH)) u_backend(
        .clk(clk),.resetn(resetn),.cmd_valid_i(cmdv),.cmd_ready_o(cmdr),
        .cmd_opcode_i(2'd0),.cmd_cluster_mode_i(2'd0),.cmd_layout_i(3'd0),
        .cmd_m_i(bm),.cmd_n_i(bn),.cmd_k_i(bk),.cmd_tag_i(bt),.cmd_a_base_i(ap),.cmd_b_base_i(bp),.cmd_c_base_i(32'd0),
        .cmd_a_bank_i(ab),.cmd_b_bank_i(bb),.cmd_c_bank_i(cb),.cmd_op_cfg_i(32'd0),
        .rsp_valid_o(rspv),.rsp_ready_i(rspr),.rsp_tag_o(rt),.rsp_status_o(rs),
        .load_begin_valid_i(load_begin_valid_i),.load_begin_ready_o(load_begin_ready_o),.load_begin_error_o(load_begin_error_o),
        .load_begin_operand_i(load_begin_operand_i),.load_begin_bank_i(load_begin_bank_i),
        .load_valid_i(load_valid_i),.load_ready_o(load_ready_o),.load_operand_i(load_operand_i),.load_bank_i(load_bank_i),
        .load_addr_i(load_addr_i),.load_data_i(load_data_i),.load_finish_valid_i(load_finish_valid_i),
        .load_finish_ready_o(load_finish_ready_o),.load_finish_error_o(load_finish_error_o),
        .load_finish_operand_i(load_finish_operand_i),.load_finish_bank_i(load_finish_bank_i),.load_finish_error_i(load_finish_error_i),
        .discard_valid_i(discard_valid_i),.discard_ready_o(discard_ready_o),.discard_error_o(discard_error_o),
        .discard_operand_i(discard_operand_i),.discard_bank_i(discard_bank_i),.allow_beat_i(allow_beat_i),
        .c_valid_o(cv),.c_ready_i(cr),.c_data_o(cd),.c_keep_o(keep),.c_m_o(om),.c_n_o(on),.c_tag_o(ot),.c_tile_last_o(),
        .busy_o(backend_busy),.queue_level_o(),.retained_o(retained_o),.loading_o(loading_o),.in_use_o(in_use_o),
        .c_free_o(),.c_in_use_o(),.active_mode_o(),.input_beat_o(input_beat_o),.packet_issue_o(packet_issue_o),
        .slots_used_o(),.pending_o(),.outstanding_o(),.error_o(error_o));
    npu_v13_psum_panel #(.MAX_M(MAX_MN),.MAX_N(MAX_MN)) u_psum_panel(
        .clk(clk),.resetn(resetn),.ctx_valid_i(ctxv),.ctx_ready_o(ctxr),.ctx_m_i(cm),.ctx_n_i(cn),.ctx_tag_i(ct),
        .ctx_first_i(first),.ctx_final_i(last),.c_valid_i(cv),.c_ready_o(cr),.c_data_i(cd),.c_keep_i(keep),.c_m_i(om),.c_n_i(on),.c_tag_i(ot),
        .end_valid_i(endv),.end_ready_o(endr),.done_valid_o(fv),.done_ready_i(fr),.done_error_o(fe),
        .out_valid_o(c_valid_o),.out_ready_i(c_ready_i),.out_data_o(c_data_o),.out_keep_o(c_keep_o),
        .out_m_o(c_m_o),.out_n_o(c_n_o),.out_tag_o(c_tag_o),.commit_o(psum_commit_o),.busy_o(psum_busy));
    assign busy_o=ctrl_busy || backend_busy || psum_busy;
endmodule
