// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 逐通道量化系数表与四路P4同步查表适配器。
// 一个系数集合保留至软件/装载器改写；lock_i期间禁止接收新配置，保证同任务参数不混代。
// p8：cfg握手只装入四组本地提交寄存器，下一拍写RAM；idle包含待提交栅栏。
// 新任务必须等待idle；即使独立调用者紧接cfg拉高lock，本模块也在提交完成前禁止接受读请求。
// 支持axis=0按M行广播（CONV的M=输出通道），axis=1按N列逐lane取参（常用GEMM）。
// 索引为resident panel相对坐标；外层panel调度器负责装载对应的全局通道参数。
// 每岛保存一份相同的小型distributed RAM系数表，换取四个独立读口；不占用特征BRAM。
// 每份表按index[1:0]分四bank，一次同步读取四个连续列系数，无16:1跨岛数据交换。
// 这有明确的LUT存储成本，需要综合实测；不能把四份复制误称为一份存储资源。
module npu_v13_quant_params #(
    parameter integer CHANNELS=128,
    parameter integer WORDS=(CHANNELS+3)/4,
    parameter integer PAW=(WORDS<=2 ? 1 : $clog2(WORDS))
)(
    input wire clk,resetn, // 同域同步复位；只清有效标记/流水，不清系数RAM内容。
    input wire lock_i, // 仅用于配置集合ownership/fence；任务期间禁止改写参数表。
    input wire [3:0] read_open_i, // 每岛注册的输入所有权token；仅驱动对应岛的稳态读入口。
    input wire cfg_valid_i, // 写一个通道完整参数；valid保持至ready。
    output wire cfg_ready_o, // 未锁定且读流水为空时接收配置；可连续每拍一条，接收不等于RAM已写可见。
    input wire [15:0] cfg_index_i, // panel相对通道号0..CHANNELS-1，不是RAM截短地址。
    input wire signed [31:0] cfg_bias_i, // 有符号INT32 bias，最终K累加之后使用一次。
    input wire [30:0] cfg_multiplier_i, // Q31整数倍率0..2^31-1。
    input wire [5:0] cfg_shift_i, // 右移0..63，数值规则由requant_p4定义。
    input wire signed [7:0] cfg_zero_point_i, // INT8输出zero-point。
    input wire cfg_relu_i, // 量化域ReLU下限使用zero-point。
    output wire cfg_error_o, // 握手当拍索引越界；错误写被接收但不改变表。
    input wire [3:0] in_valid_i, // 四路最终PSUM结果；每岛独立反压，最多一拍一P4。
    output wire [3:0] in_ready_o, // 锁定中且本岛输入两槽有空位。
    input wire in_axis_i, // 0按行；1按列。随每个beat锁存，不能依赖输出时的全局值。
    input wire [511:0] in_data_i, // 每岛4个INT32；本模块只延迟，不修改数值。
    input wire [15:0] in_keep_i, // 每岛4lane；无效lane不要求参数已初始化。
    input wire [63:0] in_m_i,in_n_i,in_tag_i, // 每岛16bit坐标/身份，与查表响应一同延迟。
    output wire [3:0] out_valid_o, // 切片后三级查表请求有效；错误也产生一个保持式响应便于排空。
    input wire [3:0] out_ready_i, // 四个量化器的输入ready；可独立长时间拉低。
    output wire [511:0] out_data_o,out_bias_o, // 原INT32数据与每lane的INT32 bias。
    output wire [495:0] out_multiplier_o, // 四岛*四lane*31bit。
    output wire [95:0] out_shift_o, // 四岛*四lane*6bit。
    output wire [127:0] out_zero_point_o, // 四岛*四lane*8bit。
    output wire [15:0] out_keep_o,out_relu_o, // 延迟mask与逐lane激活选择。
    output wire [63:0] out_m_o,out_n_o,out_tag_o, // 原请求身份，不按岛间到达顺序重建。
    output wire [3:0] out_error_o, // 有效lane缺参数/索引越界/列未4对齐；上层使任务失败。
    output wire idle_o // 读流水全空且四组配置均已提交；上层必须据此预约新任务，不能只看cfg握手。
);
    wire [3:0] slice_idle,output_idle;
    // Formal A04 cleanup: declare the global commit record before its first reference.
    reg cfg_commit_valid_r;
    reg [PAW+1:0] cfg_index_r;
    reg [77:0] cfg_word_r;
    wire read_idle=(&slice_idle) && (&output_idle);
    // 接收端只检查读流水/锁；不依赖pending，因此背靠背配置仍能每拍接收。
    // cfg_pending在最后一次本地RAM写入的边沿后才清除，防止begin越过待提交参数。
    assign idle_o=read_idle && !cfg_commit_valid_r;
    assign cfg_ready_o=resetn && !lock_i && read_idle;
    assign cfg_error_o=cfg_valid_i && cfg_ready_o && cfg_index_i>=CHANNELS;
    wire cfg_write=cfg_valid_i && cfg_ready_o && !cfg_error_o;
    wire [77:0] cfg_word={cfg_relu_i,cfg_zero_point_i,cfg_shift_i,cfg_multiplier_i,cfg_bias_i};
    // P89-A04: a single central commit record drives all four coefficient replicas.
    // This is the minimum-register extreme of the configuration-distribution network.
    always @(posedge clk) begin
        if(!resetn) cfg_commit_valid_r<=1'b0;
        else cfg_commit_valid_r<=cfg_write;
        if(cfg_write) begin cfg_index_r<=cfg_index_i[PAW+1:0];cfg_word_r<=cfg_word;end
    end
    genvar island,lane,bank;
    generate for(island=0;island<4;island=island+1)begin:G_ISLAND
        // Shared commit record; no island-local payload/control copy in A04.
        // P87-A: data-plane permission is a local registered token. lock_i remains a
        // configuration ownership fence only, eliminating central state -> four-island ready.
        wire read_enable=read_open_i[island] && !cfg_commit_valid_r;
        wire sv,sr,si,axis;wire [127:0] data;wire [3:0] keep;wire [15:0] row,col,tag;
        npu_v13_stream_slice2 #(.WIDTH(181)) u_input(
            .clk(clk),.resetn(resetn),.in_valid_i(read_enable && in_valid_i[island]),.in_ready_o(si),
            .in_data_i({in_axis_i,in_tag_i[island*16+:16],in_m_i[island*16+:16],in_n_i[island*16+:16],in_keep_i[island*4+:4],in_data_i[island*128+:128]}),
            .out_valid_o(sv),.out_ready_i(sr),.out_data_o({axis,tag,row,col,keep,data}),.idle_o(slice_idle[island]));
        assign in_ready_o[island]=resetn && read_enable && si;
        // p2：切片后分为LUTRAM同步采样、行/列选择与合法性、屏蔽输出三级。
        // 所有级在末级反压时一起冻结；ready只依赖末级valid，不穿越索引检查。
        reg [2:0] valid_r;
        reg axis_r;reg [1:0] row_lane_r;
        reg [179:0] read_payload_r,select_payload_r,payload_r;
        reg [3:0] present_r,range_bad_r,selected_bad_r;
        reg [3:0] read_keep_r,select_keep_r;
        reg align_bad_r,bad_r;
        wire advance=!valid_r[2] || out_ready_i[island];
        assign sr=resetn && advance;
        assign out_valid_o[island]=resetn && valid_r[2];
        assign output_idle[island]=!(|valid_r);
        assign out_error_o[island]=bad_r;
        assign {out_tag_o[island*16+:16],out_m_o[island*16+:16],out_n_o[island*16+:16],out_keep_o[island*4+:4],out_data_o[island*128+:128]}=payload_r;
        wire [15:0] index=axis ? col : row;
        wire [15:0] word_index=index>>2;
        wire word_in_range=word_index<WORDS;
        wire [PAW-1:0] address=word_index[PAW-1:0];
        wire [77:0] bank_coeff[0:3];wire [3:0] present;
        wire [3:0] range_bad;
        for(bank=0;bank<4;bank=bank+1)begin:G_BANK
            (* ram_style="distributed" *) reg [77:0] mem[0:WORDS-1];
            reg [WORDS-1:0] initialized_r;
            reg [77:0] coeff_r;
            always @(posedge clk)begin
                if(!resetn)initialized_r<=0;
                else if(cfg_commit_valid_r && cfg_index_r[1:0]==bank)initialized_r[cfg_index_r[PAW+1:2]]<=1;
                if(resetn && cfg_commit_valid_r && cfg_index_r[1:0]==bank)
                    mem[cfg_index_r[PAW+1:2]]<=cfg_word_r;
                // 无合法性->宽系数CE路径；错误读的数值最后单独屏蔽，绝不送出旧参数。
                if(resetn && advance && sv)coeff_r<=mem[address];
            end
            assign bank_coeff[bank]=coeff_r;
            assign present[bank]=word_in_range && initialized_r[address];
        end
        for(lane=0;lane<4;lane=lane+1)begin:G_LANE
            wire [16:0] full_index=axis ? ({1'b0,col}+lane) : {1'b0,row};
            assign range_bad[lane]=full_index>=CHANNELS;
            wire selected_present=axis_r ? present_r[lane] : present_r[row_lane_r];
            reg [77:0] selected_r,coeff_r;
            always @(posedge clk)if(resetn && advance)begin
                if(valid_r[0])begin
                    selected_r<=axis_r ? bank_coeff[lane] : bank_coeff[row_lane_r];
                    selected_bad_r[lane]<=read_keep_r[lane] &&
                        (range_bad_r[lane] || !selected_present || align_bad_r);
                end
                if(valid_r[1])coeff_r<=select_keep_r[lane] && !selected_bad_r[lane] ? selected_r : 78'b0;
            end
            assign {out_relu_o[island*4+lane],out_zero_point_o[(island*4+lane)*8+:8],
                out_shift_o[(island*4+lane)*6+:6],out_multiplier_o[(island*4+lane)*31+:31],
                out_bias_o[(island*4+lane)*32+:32]}=coeff_r;
        end
        always @(posedge clk)begin
            if(!resetn)valid_r<=0;
            else if(advance)begin
                valid_r<={valid_r[1:0],sv};
                if(sv)begin
                    read_payload_r<={tag,row,col,keep,data};axis_r<=axis;row_lane_r<=row[1:0];
                    read_keep_r<=keep;present_r<=present;range_bad_r<=range_bad;
                    align_bad_r<=axis && col[1:0]!=0;
                end
                if(valid_r[0])begin select_payload_r<=read_payload_r;select_keep_r<=read_keep_r;end
                if(valid_r[1])begin payload_r<=select_payload_r;bad_r<=|selected_bad_r;end
            end
        end
    end endgenerate
    // synthesis translate_off
    initial if(CHANNELS<1 || CHANNELS>65535 || WORDS!=(CHANNELS+3)/4 || PAW<(WORDS<=1 ? 1 : $clog2(WORDS)))
        $fatal(1,"QUANT_PARAMS invalid static capacity");
    always @(posedge clk)if(resetn && !lock_i && !read_idle)$fatal(1,"QUANT_PARAMS unlock before read drain");
    // synthesis translate_on
endmodule
