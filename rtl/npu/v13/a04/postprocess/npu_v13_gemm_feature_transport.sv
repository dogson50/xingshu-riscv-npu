// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 第二批真实联合顶层：父GEMM任务 -> 多Kchunk计算/PSUM -> 参数查表/量化 -> feature BRAM。
// 只做生命周期连线，不复制各子模块的地址/计算逻辑，便于逐层学习和单测。
// 原始INT32 GEMM仍可直接使用multik_backend；本顶层明确选择最终INT8 feature输出。
// p10搬运边界：64-bit默认/128-bit编译期对照；核心保持原样。
// 尚不包含CONV窗口生成、pool、全局panel循环或DDR DMA/CDC。
// 读请求仍是P4坐标，输出meta为每个打包字的首坐标；请求必须按行/segment连续并明确last。
module npu_v13_gemm_feature_transport #(
    parameter integer MAX_MN=128,MAX_K=512,TOTAL_SLOTS=64,CAPTURE_SLOTS=4,FIFO_DEPTH=8,
    parameter integer TRANSPORT_W=64,
    parameter integer AW=$clog2((MAX_MN/16)*MAX_K), TAW=AW+(TRANSPORT_W==64)
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
    input wire load_valid_i, // 默认64bit输入写beat；两拍在本地组成一个128-bit panel字。
    output wire load_ready_o, // 目标需处于LOADING且地址合法。
    input wire load_operand_i,load_bank_i, // 独立A/B与bank选择。
    input wire [TAW-1:0] load_addr_i, // TRANSPORT_W-bit panel字地址；不是DDR字节地址。
    input wire [TRANSPORT_W-1:0] load_data_i, // 搬运字的低lane在低位，计算侧仍为16个INT8。
    input wire [TRANSPORT_W/8-1:0] load_keep_i, // 无效字节补零，64-bit下仍须偶/奇两半完整配对。
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
    input wire rd_last_i, // 与每个P4坐标请求一起提交；每行/segment末请求必须置1以排出尾字。
    output wire rd_last_o, // 最后一个64/128-bit响应，随反压保持。
    input wire rd_valid_i, // 下一算子/搬运器发出坐标读请求。
    output wire rd_ready_o, // P4请求握手。
    input wire rd_bank_i, // 已READY的feature bank。
    input wire [15:0] rd_m_i,rd_n_i, // 相对行/4对齐列。
    output wire rd_valid_o, // 同步BRAM读响应。
    input wire rd_ready_i, // 读响应可任意反压。
    output wire [TRANSPORT_W-1:0] rd_data_o, // 打包后的INT8，尾字无效字节清零。
    output wire [TRANSPORT_W/8-1:0] rd_keep_o, // 有效lane。
    output wire rd_bank_o,rd_error_o, // 请求bank和读错误。
    output wire [15:0] rd_m_o,rd_n_o,rd_tag_o, // 坐标/tag随响应保持。
    output wire input_beat_o,packet_issue_o, // 实际计算供数/packet发行事件。
    output wire [3:0] psum_commit_o,feature_commit_o, // 分别为INT32/INT8写可见事件。
    output wire busy_o,error_o // 生命周期忙/计算后端粘滞协议错误；任务失败另看done_status。
);
    wire c_load_begin_valid_i,c_load_begin_ready_o,c_load_begin_error_o,c_load_begin_operand_i,c_load_begin_bank_i;
    wire c_load_valid_i,c_load_ready_o,c_load_operand_i,c_load_bank_i;
    wire [TAW-1:0] c_load_addr_i;wire [TRANSPORT_W-1:0] c_load_data_i;
    wire c_load_finish_valid_i,c_load_finish_ready_o,c_load_finish_error_o;
    wire c_load_finish_operand_i,c_load_finish_bank_i,c_load_finish_error_i,load_busy;
    wire c_rd_valid_i,c_rd_ready_o,c_rd_bank_i,c_rd_valid_o,c_rd_ready_i,c_rd_bank_o,c_rd_error_o;
    wire [15:0] c_rd_m_i,c_rd_n_i,c_rd_m_o,c_rd_n_o,c_rd_tag_o;
    wire [31:0] c_rd_data_o;wire [3:0] c_rd_keep_o;
    wire c_feature_release_valid_i,c_feature_release_ready_o;
    // 8项请求last标记FIFO，覆盖原同步读流水；只随真实请求/响应握手移动，不用固定拍延时。
    reg [7:0] last_fifo_r;reg [2:0] marker_wr_r,marker_rd_r;reg [3:0] marker_count_r;
    wire pack_ready,pack_busy;
    wire marker_push=c_rd_valid_i && c_rd_ready_o;
    wire marker_pop=c_rd_valid_o && c_rd_ready_i;
    assign c_rd_valid_i=rd_valid_i && marker_count_r<8;
    assign rd_ready_o=resetn && c_rd_ready_o && marker_count_r<8;
    assign c_rd_bank_i=rd_bank_i;assign c_rd_m_i=rd_m_i;assign c_rd_n_i=rd_n_i;
    assign c_rd_ready_i=pack_ready && marker_count_r!=0;
    // 即便原读流水已经排空，只要末个搬运字仍在本地组装/反压中，就不确认bank释放。
    assign c_feature_release_valid_i=feature_release_valid_i && marker_count_r==0 && !pack_busy;
    assign feature_release_ready_o=c_feature_release_ready_o && marker_count_r==0 && !pack_busy;
    always @(posedge clk) begin
        if(!resetn) begin marker_wr_r<=0;marker_rd_r<=0;marker_count_r<=0;end
        else begin
            if(marker_push)begin last_fifo_r[marker_wr_r]<=rd_last_i;marker_wr_r<=marker_wr_r+1'b1;end
            if(marker_pop)marker_rd_r<=marker_rd_r+1'b1;
            case({marker_push,marker_pop})
                2'b10:marker_count_r<=marker_count_r+1'b1;
                2'b01:marker_count_r<=marker_count_r-1'b1;
                default:marker_count_r<=marker_count_r;
            endcase
        end
    end
    npu_v13_panel_load_narrow #(.TRANSPORT_W(TRANSPORT_W),.DEPTH((MAX_MN/16)*MAX_K),.AW(AW),.TAW(TAW)) u_load_transport(
        .clk(clk),.resetn(resetn),
        .s_begin_valid_i(load_begin_valid_i),.s_begin_ready_o(load_begin_ready_o),.s_begin_error_o(load_begin_error_o),
        .s_begin_operand_i(load_begin_operand_i),.s_begin_bank_i(load_begin_bank_i),
        .s_valid_i(load_valid_i),.s_ready_o(load_ready_o),.s_operand_i(load_operand_i),.s_bank_i(load_bank_i),
        .s_addr_i(load_addr_i),.s_data_i(load_data_i),.s_keep_i(load_keep_i),
        .s_finish_valid_i(load_finish_valid_i),.s_finish_ready_o(load_finish_ready_o),.s_finish_error_o(load_finish_error_o),
        .s_finish_operand_i(load_finish_operand_i),.s_finish_bank_i(load_finish_bank_i),.s_finish_error_i(load_finish_error_i),
        .m_begin_valid_o(c_load_begin_valid_i),.m_begin_ready_i(c_load_begin_ready_o),.m_begin_error_i(c_load_begin_error_o),
        .m_begin_operand_o(c_load_begin_operand_i),.m_begin_bank_o(c_load_begin_bank_i),
        .m_valid_o(c_load_valid_i),.m_ready_i(c_load_ready_o),.m_operand_o(c_load_operand_i),.m_bank_o(c_load_bank_i),
        .m_addr_o(c_load_addr_i),.m_data_o(c_load_data_i),
        .m_finish_valid_o(c_load_finish_valid_i),.m_finish_ready_i(c_load_finish_ready_o),.m_finish_error_i(c_load_finish_error_o),
        .m_finish_operand_o(c_load_finish_operand_i),.m_finish_bank_o(c_load_finish_bank_i),.m_finish_error_o(c_load_finish_error_i),.busy_o(load_busy));
    npu_v13_feature_transport_pack #(.TRANSPORT_W(TRANSPORT_W)) u_read_transport(
        .clk(clk),.resetn(resetn),.s_valid_i(c_rd_valid_o && marker_count_r!=0),.s_ready_o(pack_ready),
        .s_data_i(c_rd_data_o),.s_keep_i(c_rd_keep_o),.s_meta_i({c_rd_bank_o,c_rd_tag_o,c_rd_m_o,c_rd_n_o}),
        .s_error_i(c_rd_error_o),.s_last_i(last_fifo_r[marker_rd_r]),
        .m_valid_o(rd_valid_o),.m_ready_i(rd_ready_i),.m_data_o(rd_data_o),.m_keep_o(rd_keep_o),
        .m_meta_o({rd_bank_o,rd_tag_o,rd_m_o,rd_n_o}),.m_error_o(rd_error_o),.m_last_o(rd_last_o),.busy_o(pack_busy));

    npu_v13_gemm_feature_backend #(.LOAD_W(TRANSPORT_W),.MAX_MN(MAX_MN),.MAX_K(MAX_K),.TOTAL_SLOTS(TOTAL_SLOTS),.CAPTURE_SLOTS(CAPTURE_SLOTS),.FIFO_DEPTH(FIFO_DEPTH),.AW(AW)) u_core(
        .clk(clk),
        .resetn(resetn),
        .job_valid_i(job_valid_i),
        .job_ready_o(job_ready_o),
        .job_m_i(job_m_i),
        .job_n_i(job_n_i),
        .job_tag_i(job_tag_i),
        .job_k_i(job_k_i),
        .job_feature_bank_i(job_feature_bank_i),
        .job_quant_axis_i(job_quant_axis_i),
        .chunk_valid_i(chunk_valid_i),
        .chunk_ready_o(chunk_ready_o),
        .chunk_k_i(chunk_k_i),
        .chunk_a_bank_i(chunk_a_bank_i),
        .chunk_b_bank_i(chunk_b_bank_i),
        .chunk_c_bank_i(chunk_c_bank_i),
        .chunk_a_base_i(chunk_a_base_i),
        .chunk_b_base_i(chunk_b_base_i),
        .done_valid_o(done_valid_o),
        .done_ready_i(done_ready_i),
        .done_tag_o(done_tag_o),
        .done_status_o(done_status_o),
        .done_feature_bank_o(done_feature_bank_o),
        .k_done_o(k_done_o),
        .cfg_valid_i(cfg_valid_i),
        .cfg_ready_o(cfg_ready_o),
        .cfg_error_o(cfg_error_o),
        .cfg_index_i(cfg_index_i),
        .cfg_bias_i(cfg_bias_i),
        .cfg_multiplier_i(cfg_multiplier_i),
        .cfg_shift_i(cfg_shift_i),
        .cfg_zero_point_i(cfg_zero_point_i),
        .cfg_relu_i(cfg_relu_i),
        .load_begin_valid_i(c_load_begin_valid_i),
        .load_begin_ready_o(c_load_begin_ready_o),
        .load_begin_error_o(c_load_begin_error_o),
        .load_begin_operand_i(c_load_begin_operand_i),
        .load_begin_bank_i(c_load_begin_bank_i),
        .load_valid_i(c_load_valid_i),
        .load_ready_o(c_load_ready_o),
        .load_operand_i(c_load_operand_i),
        .load_bank_i(c_load_bank_i),
        .load_addr_i(c_load_addr_i),
        .load_data_i(c_load_data_i),
        .load_finish_valid_i(c_load_finish_valid_i),
        .load_finish_ready_o(c_load_finish_ready_o),
        .load_finish_error_o(c_load_finish_error_o),
        .load_finish_operand_i(c_load_finish_operand_i),
        .load_finish_bank_i(c_load_finish_bank_i),
        .load_finish_error_i(c_load_finish_error_i),
        .discard_valid_i(discard_valid_i),
        .discard_ready_o(discard_ready_o),
        .discard_error_o(discard_error_o),
        .discard_operand_i(discard_operand_i),
        .discard_bank_i(discard_bank_i),
        .allow_beat_i(allow_beat_i),
        .retained_o(retained_o),
        .loading_o(loading_o),
        .in_use_o(in_use_o),
        .feature_ready_o(feature_ready_o),
        .feature_free_o(feature_free_o),
        .feature_release_valid_i(c_feature_release_valid_i),
        .feature_release_ready_o(c_feature_release_ready_o),
        .feature_release_bank_i(feature_release_bank_i),
        .rd_valid_i(c_rd_valid_i),
        .rd_ready_o(c_rd_ready_o),
        .rd_bank_i(c_rd_bank_i),
        .rd_m_i(c_rd_m_i),
        .rd_n_i(c_rd_n_i),
        .rd_valid_o(c_rd_valid_o),
        .rd_ready_i(c_rd_ready_i),
        .rd_data_o(c_rd_data_o),
        .rd_keep_o(c_rd_keep_o),
        .rd_bank_o(c_rd_bank_o),
        .rd_error_o(c_rd_error_o),
        .rd_m_o(c_rd_m_o),
        .rd_n_o(c_rd_n_o),
        .rd_tag_o(c_rd_tag_o),
        .input_beat_o(input_beat_o),
        .packet_issue_o(packet_issue_o),
        .psum_commit_o(psum_commit_o),
        .feature_commit_o(feature_commit_o),
        .busy_o(busy_o),
        .error_o(error_o));
endmodule
