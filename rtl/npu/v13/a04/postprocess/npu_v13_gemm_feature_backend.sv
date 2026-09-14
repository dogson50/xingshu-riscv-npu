// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 第二批真实联合顶层：父GEMM任务 -> 多Kchunk计算/PSUM -> 参数查表/量化 -> feature BRAM。
// 只做生命周期连线，不复制各子模块的地址/计算逻辑，便于逐层学习和单测。
// 原始INT32 GEMM仍可直接使用multik_backend；本顶层明确选择最终INT8 feature输出。
// 尚不包含CONV窗口生成、pool、全局panel循环或DDR DMA/CDC。
module npu_v13_gemm_feature_backend #(
    parameter integer LOAD_W=128,
    parameter integer MAX_MN=128,MAX_K=512,TOTAL_SLOTS=64,CAPTURE_SLOTS=4,FIFO_DEPTH=8,
    parameter integer AW=$clog2((MAX_MN/16)*MAX_K)
)(
    input wire clk,resetn, // 命令/计算/PSUM/量化/feature同域同步取消。
    input wire job_valid_i, // resident父任务申请；所有字段保持到ready。
    output wire job_ready_o, // 指定feature bank已能预约才接受任务，不靠启动后再等空间。
    input wire [15:0] job_m_i,job_n_i,job_tag_i, // 动态M/N与任务tag；不是固定shape裁剪。
    input wire [31:0] job_k_i, // 总K，可跨多个resident chunk。
    input wire job_feature_bank_i,job_quant_axis_i, // 输出bank0/1；0按M、1按N通道量化。
    input wire chunk_valid_i, // 上游A/B装载调度器提交下一K段。
    output wire chunk_ready_o, // 仅活动父任务，且上一段PSUM写可见栅栏已通过。
    input wire [15:0] chunk_k_i, // 本段K，动态且不超过MAX_K。
    input wire chunk_a_bank_i,chunk_b_bank_i,chunk_c_bank_i, // 计算后端的独立租约bank编号。
    input wire [31:0] chunk_a_base_i,chunk_b_base_i, // 128bit BRAM word基址；不是DDR字节地址。
    output wire done_valid_o, // 最终feature可读取，或失败任务已隔离；不是TLAST或PSUM输入完成。
    input wire done_ready_i, // 完成响应可反压；READY feature继续保留。
    output wire [15:0] done_tag_o, // 原父任务tag。
    output wire [2:0] done_status_o, // 0成功，1..4沿用multik；5后处理/写回失败。
    output wire done_feature_bank_o, // 完成对应的feature bank。
    output wire [31:0] k_done_o, // PSUM栅栏后的实际K进度，不以装载长度代替执行进度。
    input wire cfg_valid_i, // 逐通道量化系数写入；任务期间不接受改写。
    output wire cfg_ready_o,cfg_error_o, // 参数写握手和越界错误。
    input wire [15:0] cfg_index_i, // 当前resident panel相对通道索引。
    input wire signed [31:0] cfg_bias_i, // INT32 bias，只在全部K累加后加一次。
    input wire [30:0] cfg_multiplier_i, // 完整Q31倍率。
    input wire [5:0] cfg_shift_i, // 0..63右移。
    input wire signed [7:0] cfg_zero_point_i, // INT8输出zero-point。
    input wire cfg_relu_i, // 可选ReLU。
    input wire load_begin_valid_i, // 请求在FREE的A/B bank开始装载。
    output wire load_begin_ready_o,load_begin_error_o, // 装载申请握手/错误。
    input wire load_begin_operand_i,load_begin_bank_i, // operand0=A/1=B，bank0/1。
    input wire load_valid_i, // LOAD_W位搬运beat；64位在目标bank本地拼成128位。
    output wire load_ready_o, // 目标需处于LOADING且地址合法。
    input wire load_operand_i,load_bank_i, // 独立A/B与bank选择。
    input wire [AW+(LOAD_W==64)-1:0] load_addr_i, // LOAD_W-bit panel beat地址，不是DDR字节地址。
    input wire [LOAD_W-1:0] load_data_i, // 窄载荷保持到bank叶节点；计算读口仍128位。
    input wire load_finish_valid_i, // 输入装载完成/取消申请。
    output wire load_finish_ready_o,load_finish_error_o, // 最后写可见后才确认。
    input wire load_finish_operand_i,load_finish_bank_i,load_finish_error_i, // finish目标/失败标记。
    input wire discard_valid_i, // 归还保留的输入panel，不得抢占IN_USE。
    output wire discard_ready_o,discard_error_o, // 显式归还握手/错误。
    input wire discard_operand_i,discard_bank_i, // A/B及bank目标。
    input wire allow_beat_i, // 输入气泡测试/供数许可，不取消已发出的读响应。
    output wire [3:0] retained_o,loading_o,in_use_o, // 输入缓存状态{B1,B0,A1,A0}。
    output wire [1:0] feature_ready_o,feature_free_o, // 输出缓存占用，独立于输入缓存。
    input wire feature_release_valid_i, // 消费者不再需要某个输出panel。
    output wire feature_release_ready_o, // 无该bank在途读才接受归还。
    input wire feature_release_bank_i, // 显式释放的输出bank。
    input wire rd_valid_i, // 下一算子/搬运器发出坐标读请求。
    output wire rd_ready_o, // P4请求握手。
    input wire rd_bank_i, // 已READY的feature bank。
    input wire [15:0] rd_m_i,rd_n_i, // 相对行/4对齐列。
    output wire rd_valid_o, // 同步BRAM读响应。
    input wire rd_ready_i, // 读响应可任意反压。
    output wire [31:0] rd_data_o, // P4 INT8，尾lane置零。
    output wire [3:0] rd_keep_o, // 有效lane。
    output wire rd_bank_o,rd_error_o, // 请求bank和读错误。
    output wire [15:0] rd_m_o,rd_n_o,rd_tag_o, // 坐标/tag随响应保持。
    output wire input_beat_o,packet_issue_o, // 实际计算供数/packet发行事件。
    output wire [3:0] psum_commit_o,feature_commit_o, // 分别为INT32/INT8写可见事件。
    output wire busy_o,error_o // 生命周期忙/计算后端粘滞协议错误；任务失败另看done_status。
);
    localparam IDLE=2'd0,LAUNCH=2'd1,RUN=2'd2,WAIT_POST=2'd3;
    reg [1:0] state_r;
    reg [15:0] m_r,n_r,tag_r;reg [31:0] k_r;reg [2:0] status_r;
    wire post_begin_ready,post_end_ready,post_done,post_error,post_busy;
    wire backend_job_ready,backend_done,backend_busy,backend_chunk_ready;
    wire [15:0] backend_tag;wire [2:0] backend_status;
    wire [3:0] cv,cr;wire [511:0] cd;wire [15:0] ck;wire [63:0] cm,cn,ct;
    assign job_ready_o=resetn && state_r==IDLE && post_begin_ready;
    assign chunk_ready_o=resetn && state_r==RUN && backend_chunk_ready;
    assign done_valid_o=resetn && state_r==WAIT_POST && post_done;
    assign done_status_o=(status_r!=0) ? status_r : (post_error ? 3'd5 : 3'd0);
    assign busy_o=state_r!=IDLE || post_busy || backend_busy;
    always @(posedge clk)begin
        if(!resetn)begin state_r<=IDLE;status_r<=0;end
        else begin
            if(job_valid_i && job_ready_o)begin state_r<=LAUNCH;m_r<=job_m_i;n_r<=job_n_i;k_r<=job_k_i;tag_r<=job_tag_i;status_r<=0;end
            if(state_r==LAUNCH && backend_job_ready)state_r<=RUN;
            if(state_r==RUN && backend_done && post_end_ready)begin
                state_r<=WAIT_POST;status_r<=backend_tag!=tag_r ? 3'd3 : backend_status;
            end
            if(done_valid_o && done_ready_i)state_r<=IDLE;
        end
    end
    npu_v13_multik_backend #(.LOAD_W(LOAD_W),.MAX_MN(MAX_MN),.MAX_K(MAX_K),.TOTAL_SLOTS(TOTAL_SLOTS),.CAPTURE_SLOTS(CAPTURE_SLOTS),.FIFO_DEPTH(FIFO_DEPTH)) u_compute(
        .clk(clk),.resetn(resetn),.job_valid_i(state_r==LAUNCH),.job_ready_o(backend_job_ready),.job_m_i(m_r),.job_n_i(n_r),.job_k_i(k_r),.job_tag_i(tag_r),
        .chunk_valid_i(state_r==RUN && chunk_valid_i),.chunk_ready_o(backend_chunk_ready),.chunk_k_i(chunk_k_i),
        .chunk_a_bank_i(chunk_a_bank_i),.chunk_b_bank_i(chunk_b_bank_i),.chunk_c_bank_i(chunk_c_bank_i),.chunk_a_base_i(chunk_a_base_i),.chunk_b_base_i(chunk_b_base_i),
        .done_valid_o(backend_done),.done_ready_i(state_r==RUN && post_end_ready),.done_tag_o(backend_tag),.done_status_o(backend_status),.k_done_o(k_done_o),
        .load_begin_valid_i(load_begin_valid_i),.load_begin_ready_o(load_begin_ready_o),.load_begin_error_o(load_begin_error_o),.load_begin_operand_i(load_begin_operand_i),.load_begin_bank_i(load_begin_bank_i),
        .load_valid_i(load_valid_i),.load_ready_o(load_ready_o),.load_operand_i(load_operand_i),.load_bank_i(load_bank_i),.load_addr_i(load_addr_i),.load_data_i(load_data_i),
        .load_finish_valid_i(load_finish_valid_i),.load_finish_ready_o(load_finish_ready_o),.load_finish_error_o(load_finish_error_o),
        .load_finish_operand_i(load_finish_operand_i),.load_finish_bank_i(load_finish_bank_i),.load_finish_error_i(load_finish_error_i),
        .discard_valid_i(discard_valid_i),.discard_ready_o(discard_ready_o),.discard_error_o(discard_error_o),.discard_operand_i(discard_operand_i),.discard_bank_i(discard_bank_i),
        .allow_beat_i(allow_beat_i),.c_valid_o(cv),.c_ready_i(cr),.c_data_o(cd),.c_keep_o(ck),.c_m_o(cm),.c_n_o(cn),.c_tag_o(ct),
        .retained_o(retained_o),.loading_o(loading_o),.in_use_o(in_use_o),.input_beat_o(input_beat_o),.packet_issue_o(packet_issue_o),.psum_commit_o(psum_commit_o),.busy_o(backend_busy),.error_o(error_o));
    npu_v13_postprocess_engine #(.MAX_M(MAX_MN),.MAX_N(MAX_MN)) u_post(
        .clk(clk),.resetn(resetn),.cfg_valid_i(cfg_valid_i),.cfg_ready_o(cfg_ready_o),.cfg_error_o(cfg_error_o),.cfg_index_i(cfg_index_i),
        .cfg_bias_i(cfg_bias_i),.cfg_multiplier_i(cfg_multiplier_i),.cfg_shift_i(cfg_shift_i),.cfg_zero_point_i(cfg_zero_point_i),.cfg_relu_i(cfg_relu_i),
        .begin_valid_i(state_r==IDLE && job_valid_i),.begin_ready_o(post_begin_ready),.begin_bank_i(job_feature_bank_i),.begin_axis_i(job_quant_axis_i),
        .begin_m_i(job_m_i),.begin_n_i(job_n_i),.begin_tag_i(job_tag_i),.in_valid_i(cv),.in_ready_o(cr),.in_data_i(cd),.in_keep_i(ck),.in_m_i(cm),.in_n_i(cn),.in_tag_i(ct),
        .end_valid_i(state_r==RUN && backend_done),.end_ready_o(post_end_ready),.end_error_i(backend_status!=0 || backend_tag!=tag_r),
        .done_valid_o(post_done),.done_ready_i(state_r==WAIT_POST && done_ready_i),.done_error_o(post_error),.done_bank_o(done_feature_bank_o),.done_tag_o(done_tag_o),
        .bank_ready_o(feature_ready_o),.bank_free_o(feature_free_o),.release_valid_i(feature_release_valid_i),.release_ready_o(feature_release_ready_o),.release_bank_i(feature_release_bank_i),
        .rd_valid_i(rd_valid_i),.rd_ready_o(rd_ready_o),.rd_bank_i(rd_bank_i),.rd_m_i(rd_m_i),.rd_n_i(rd_n_i),.rd_valid_o(rd_valid_o),.rd_ready_i(rd_ready_i),
        .rd_data_o(rd_data_o),.rd_keep_o(rd_keep_o),.rd_bank_o(rd_bank_o),.rd_error_o(rd_error_o),.rd_m_o(rd_m_o),.rd_n_o(rd_n_o),.rd_tag_o(rd_tag_o),
        .write_commit_o(feature_commit_o),.busy_o(post_busy));
endmodule
