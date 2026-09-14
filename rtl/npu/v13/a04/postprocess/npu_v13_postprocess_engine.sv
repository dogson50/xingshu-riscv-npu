// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 第二批后处理闭环：最终PSUM -> 逐通道查表 -> 四路Q31量化/ReLU -> 双bank INT8 feature。
// 不自行遍历M/N/K，不生成计算命令；begin预约成功以后，上游才允许启动父计算任务。
// 上游end表示“不会再送最终PSUM”，本模块done表示“最后一次feature写已经可见”。
// 这两种完成不能等同；即使最后PSUM握手，系数/量化/写缓冲里仍可能有数据。
module npu_v13_postprocess_engine #(
    parameter integer MAX_M=128,MAX_N=128,
    parameter integer CHANNELS=(MAX_M>MAX_N ? MAX_M : MAX_N)
)(
    input wire clk,resetn, // 计算域同步复位；必须与产生PSUM的后端协调取消同一任务。
    input wire cfg_valid_i, // 通道参数装载端口；只在本模块无活动任务时接受。
    output wire cfg_ready_o,cfg_error_o, // 参数写握手/越界错误，错误写不改变参数。
    input wire [15:0] cfg_index_i, // 当前resident panel内的通道号。
    input wire signed [31:0] cfg_bias_i, // 最终INT32累加之后一次性加bias。
    input wire [30:0] cfg_multiplier_i, // 保留完整Q31倍率。
    input wire [5:0] cfg_shift_i, // 0..63右移，ties-away舍入。
    input wire signed [7:0] cfg_zero_point_i, // INT8输出zero-point。
    input wire cfg_relu_i, // 量化域ReLU可选。
    input wire begin_valid_i, // 申请锁定参数集并预约一个空feature bank。
    output wire begin_ready_o, // 当前空闲且指定bank可预约；满时禁止上游启动计算。
    input wire begin_bank_i,begin_axis_i, // 独立feature bank0/1；axis0=M通道，1=N通道。
    input wire [15:0] begin_m_i,begin_n_i,begin_tag_i, // panel相对尺寸和任务身份。
    input wire [3:0] in_valid_i, // 来自PSUM panel的四路最终结果，不允许中间Kchunk进入。
    output wire [3:0] in_ready_o, // 每岛独立容量，可直接连接PSUM out_ready。
    input wire [511:0] in_data_i, // 四岛*四lane*INT32。
    input wire [15:0] in_keep_i, // 有效元素mask，动态M/N不固定。
    input wire [63:0] in_m_i,in_n_i,in_tag_i, // 四岛位置身份，不要求岛间同步。
    input wire end_valid_i, // 所有最终PSUM均已握手，上游要求关闭输入。
    output wire end_ready_o, // 活动任务仅接收一次end。
    input wire end_error_i, // 上游任务失败，已收数据仍排空，但不发布READY。
    output wire done_valid_o, // 真正feature写可见完成，或失败任务安全隔离。
    input wire done_ready_i, // 完成响应可反压；响应握手不自动释放READY数据。
    output wire done_error_o,done_bank_o, // 参数/上游/store错误，和所预约bank。
    output wire [15:0] done_tag_o, // 父任务tag。
    output wire [1:0] bank_ready_o,bank_free_o, // 下一算子或调度器用于选择驻留数据。
    input wire release_valid_i, // 显式归还一个已不再使用的feature bank。
    output wire release_ready_o, // 没有该bank在途读时才允许归还。
    input wire release_bank_i, // 归还目标，不与A/B bank混用。
    input wire rd_valid_i, // 同步坐标读口；可与另一bank计算/写入并行。
    output wire rd_ready_o, // P4读请求握手。
    input wire rd_bank_i, // 读取的READY bank。
    input wire [15:0] rd_m_i,rd_n_i, // 相对坐标；列4对齐。
    output wire rd_valid_o, // 读响应；不是DDR总线协议。
    input wire rd_ready_i, // 下游可反压，数据和身份保持。
    output wire [31:0] rd_data_o, // 四个INT8；无效lane置零。
    output wire [3:0] rd_keep_o, // 四lane有效标记。
    output wire rd_bank_o,rd_error_o, // 原请求bank及非法请求标志。
    output wire [15:0] rd_m_o,rd_n_o,rd_tag_o, // 读响应身份。
    output wire [3:0] write_commit_o, // 四组真实feature写入事件，用于完成栅栏审计。
    output wire busy_o // 活动后处理/响应/读流水，READY驻留占用另看bank状态。
);
    localparam IDLE=3'd0,RUN=3'd1,DRAIN=3'd2,CLOSE=3'd3,WAIT_STORE=3'd4;
    reg [2:0] state_r;
    reg axis_r,error_r;
    wire params_idle,store_busy,store_begin_ready,store_end_ready,store_done;
    wire [3:0] pi,pr,pv,pe,qr,qv,qi,store_ready;
    // P87-A: central lifecycle state only emits job-boundary events. Four retained
    // ownership bits are separate physical timing sources for the four ingress paths.
    wire [3:0] ingress_open_w;
    wire [511:0] pd,pb;wire [495:0] pmu;wire [95:0] psh;wire [127:0] pz,qd;
    wire [15:0] pk,pre,qk;wire [63:0] pm,pn,pt,qm,qn,qt;
    wire reserve=state_r==IDLE && params_idle;
    wire begin_fire=begin_valid_i && begin_ready_o;
    wire end_fire=end_valid_i && end_ready_o;
    // cfg与begin同拍时优先接收cfg；params_idle包含p8本地提交级。
    // 接收最后配置后还必须等RAM写可见，不能固定认为下一拍即可锁定任务。
    assign begin_ready_o=resetn && reserve && !cfg_valid_i && store_begin_ready;
    assign end_ready_o=resetn && state_r==RUN;
    // pi is already masked by each island's registered ownership token.
    assign in_ready_o=pi;
    assign done_valid_o=resetn && state_r==WAIT_STORE && store_done;
    assign busy_o=state_r!=IDLE || store_busy || !params_idle || !( &qi );
    always @(posedge clk)begin
        if(!resetn)begin state_r<=IDLE;axis_r<=0;error_r<=0;end
        else begin
            if(begin_fire)begin state_r<=RUN;axis_r<=begin_axis_i;error_r<=0;end
            if(|(pv&pr&pe))error_r<=1;
            if(end_fire)begin state_r<=DRAIN;if(end_error_i)error_r<=1;end
            if(state_r==DRAIN && params_idle && (&qi))state_r<=CLOSE;
            if(state_r==CLOSE && store_end_ready)state_r<=WAIT_STORE;
            if(done_valid_o && done_ready_i)state_r<=IDLE;
        end
    end
    npu_v13_quant_params #(.CHANNELS(CHANNELS)) u_params(
        .clk(clk),.resetn(resetn),.lock_i(state_r!=IDLE),.read_open_i(ingress_open_w),
        .cfg_valid_i(cfg_valid_i),.cfg_ready_o(cfg_ready_o),
        .cfg_index_i(cfg_index_i),.cfg_bias_i(cfg_bias_i),.cfg_multiplier_i(cfg_multiplier_i),.cfg_shift_i(cfg_shift_i),
        .cfg_zero_point_i(cfg_zero_point_i),.cfg_relu_i(cfg_relu_i),.cfg_error_o(cfg_error_o),
        .in_valid_i(in_valid_i),.in_ready_o(pi),.in_axis_i(axis_r),
        .in_data_i(in_data_i),.in_keep_i(in_keep_i),.in_m_i(in_m_i),.in_n_i(in_n_i),.in_tag_i(in_tag_i),
        .out_valid_o(pv),.out_ready_i(pr),.out_data_o(pd),.out_bias_o(pb),.out_multiplier_o(pmu),.out_shift_o(psh),
        .out_zero_point_o(pz),.out_keep_o(pk),.out_relu_o(pre),.out_m_o(pm),.out_n_o(pn),.out_tag_o(pt),.out_error_o(pe),.idle_o(params_idle));
    genvar g;
    generate for(g=0;g<4;g=g+1)begin:G_QUANT
        // P87-A distributed ingress ownership: one retained bit per island. The central
        // state no longer sits combinationally on PSUM ready -> advance -> BRAM/CE/R.
        // Begin/end only touch these four D pins at task boundaries; steady state II=1.
        (* keep="true", equivalent_register_removal="no" *) reg ingress_open_r;
        always @(posedge clk) begin
            if(!resetn) ingress_open_r<=1'b0;
            else if(begin_fire) ingress_open_r<=1'b1;
            else if(end_fire) ingress_open_r<=1'b0;
        end
        assign ingress_open_w[g]=ingress_open_r;
        // 缺参beat必须退休并使整个任务失败，不能永远堵住已经启动的计算包。
        assign pr[g]=pe[g] || qr[g];
        npu_v13_requant_p4 #(.META_W(48)) u_quant(
            .clk(clk),.resetn(resetn),.in_valid_i(pv[g] && !pe[g]),.in_ready_o(qr[g]),
            .in_data_i(pd[g*128+:128]),.in_keep_i(pk[g*4+:4]),.in_bias_i(pb[g*128+:128]),
            .in_multiplier_i(pmu[g*124+:124]),.in_shift_i(psh[g*24+:24]),.in_zero_point_i(pz[g*32+:32]),
            .in_relu_i(pre[g*4+:4]),.in_meta_i({pt[g*16+:16],pm[g*16+:16],pn[g*16+:16]}),
            .out_valid_o(qv[g]),.out_ready_i(store_ready[g]),.out_data_o(qd[g*32+:32]),.out_keep_o(qk[g*4+:4]),
            .out_meta_o({qt[g*16+:16],qm[g*16+:16],qn[g*16+:16]}),.idle_o(qi[g]));
    end endgenerate
    npu_v13_feature_store #(.MAX_M(MAX_M),.MAX_N(MAX_N)) u_store(
        .clk(clk),.resetn(resetn),.begin_valid_i(begin_valid_i && reserve && !cfg_valid_i),.begin_ready_o(store_begin_ready),
        .begin_bank_i(begin_bank_i),.begin_m_i(begin_m_i),.begin_n_i(begin_n_i),.begin_tag_i(begin_tag_i),
        .in_valid_i(qv),.in_ready_o(store_ready),.in_data_i(qd),.in_keep_i(qk),.in_m_i(qm),.in_n_i(qn),.in_tag_i(qt),
        .end_valid_i(state_r==CLOSE),.end_ready_o(store_end_ready),.end_error_i(error_r),
        .done_valid_o(store_done),.done_ready_i(state_r==WAIT_STORE && done_ready_i),
        .done_error_o(done_error_o),.done_bank_o(done_bank_o),.done_tag_o(done_tag_o),.bank_ready_o(bank_ready_o),.bank_free_o(bank_free_o),
        .release_valid_i(release_valid_i),.release_ready_o(release_ready_o),.release_bank_i(release_bank_i),
        .rd_valid_i(rd_valid_i),.rd_ready_o(rd_ready_o),.rd_bank_i(rd_bank_i),.rd_m_i(rd_m_i),.rd_n_i(rd_n_i),
        .rd_valid_o(rd_valid_o),.rd_ready_i(rd_ready_i),.rd_data_o(rd_data_o),.rd_keep_o(rd_keep_o),
        .rd_bank_o(rd_bank_o),.rd_error_o(rd_error_o),.rd_m_o(rd_m_o),.rd_n_o(rd_n_o),.rd_tag_o(rd_tag_o),
        .write_commit_o(write_commit_o),.busy_o(store_busy));
    // synthesis translate_off
    always @(posedge clk)if(resetn && end_valid_i && end_ready_o && (|in_valid_i))
        $fatal(1,"POSTPROCESS end must follow final PSUM transfers");
    // synthesis translate_on
endmodule
