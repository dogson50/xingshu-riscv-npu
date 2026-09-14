// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p7：单搬运会话的64/128-bit装载边界；计算侧固定128-bit，不改变缓存容量。
// s_addr是TRANSPORT_W-bit打包panel字地址，不是DDR字节地址；64-bit时偶地址低半、紧随奇地址高半。
// 每个128-bit字必须完整提供两半；尾部无效字节由keep清零。缺半finish会取消整次装载，不发布RETAINED。
// 只串行化物理装载端口；另一A/B bank仍可被计算复用。非本会话finish消费报错但不结束真正会话。
module npu_v13_panel_load_transport #(
    parameter integer TRANSPORT_W=64, DEPTH=4096, AW=$clog2(DEPTH), TAW=AW+(TRANSPORT_W==64)
)(
    input wire clk,resetn,
    input wire s_begin_valid_i, output wire s_begin_ready_o,s_begin_error_o,
    input wire s_begin_operand_i,s_begin_bank_i,
    input wire s_valid_i, output wire s_ready_o,
    input wire s_operand_i,s_bank_i,
    input wire [TAW-1:0] s_addr_i,
    input wire [TRANSPORT_W-1:0] s_data_i,
    input wire [TRANSPORT_W/8-1:0] s_keep_i,
    input wire s_finish_valid_i, output wire s_finish_ready_o,s_finish_error_o,
    input wire s_finish_operand_i,s_finish_bank_i,s_finish_error_i,
    output wire m_begin_valid_o, input wire m_begin_ready_i,m_begin_error_i,
    output wire m_begin_operand_o,m_begin_bank_o,
    output wire m_valid_o, input wire m_ready_i,
    output wire m_operand_o,m_bank_o,
    output wire [AW-1:0] m_addr_o, output wire [127:0] m_data_o,
    output wire m_finish_valid_o, input wire m_finish_ready_i,m_finish_error_i,
    output wire m_finish_operand_o,m_finish_bank_o,m_finish_error_o,
    output wire busy_o
);
    reg active_r,operand_r,bank_r,bad_r,half_r,out_valid_r;
    reg [63:0] low_r;
    reg [AW-1:0] half_addr_r,out_addr_r;
    reg [127:0] out_data_r;
    wire [AW-1:0] word_addr=s_addr_i >> (TRANSPORT_W==64);
    wire wrong_finish=!active_r || s_finish_operand_i!=operand_r || s_finish_bank_i!=bank_r;
    wire malformed=s_operand_i!=operand_r || s_bank_i!=bank_r || s_addr_i>=DEPTH*(128/TRANSPORT_W) ||
        ((TRANSPORT_W==64) && ((!half_r && s_addr_i[0]) ||
        (half_r && (!s_addr_i[0] || word_addr!=half_addr_r))));
    reg [127:0] masked;
    always @* begin
        masked=0;
        for(integer b=0;b<TRANSPORT_W/8;b=b+1) if(s_keep_i[b]) masked[b*8+:8]=s_data_i[b*8+:8];
    end
    assign m_begin_valid_o=resetn && !active_r && !s_finish_valid_i && s_begin_valid_i;
    assign s_begin_ready_o=resetn && !active_r && !s_finish_valid_i && m_begin_ready_i;
    assign s_begin_error_o=m_begin_error_i;
    assign m_begin_operand_o=s_begin_operand_i; assign m_begin_bank_o=s_begin_bank_i;
    assign s_ready_o=resetn && active_r && !s_finish_valid_i && (!out_valid_r || m_ready_i);
    assign m_valid_o=resetn && out_valid_r;
    assign m_operand_o=operand_r; assign m_bank_o=bank_r;
    assign m_addr_o=out_addr_r; assign m_data_o=out_data_r;
    // 先排空已组装的128-bit输出，再让原存储管理器等待其本地写流水；finish不能越过写可见栅栏。
    assign m_finish_valid_o=resetn && s_finish_valid_i && !wrong_finish && !out_valid_r;
    assign m_finish_operand_o=operand_r; assign m_finish_bank_o=bank_r;
    assign m_finish_error_o=s_finish_error_i || bad_r || half_r;
    assign s_finish_ready_o=resetn && (wrong_finish || (!out_valid_r && m_finish_ready_i));
    assign s_finish_error_o=wrong_finish || bad_r || half_r || (!wrong_finish && m_finish_error_i);
    assign busy_o=active_r || half_r || out_valid_r;
    always @(posedge clk) begin
        if(!resetn) begin active_r<=0;operand_r<=0;bank_r<=0;bad_r<=0;half_r<=0;out_valid_r<=0;end
        else begin
            if(out_valid_r && m_ready_i) out_valid_r<=0;
            if(s_begin_valid_i && s_begin_ready_o && !s_begin_error_o) begin
                active_r<=1;operand_r<=s_begin_operand_i;bank_r<=s_begin_bank_i;bad_r<=0;half_r<=0;
            end
            if(s_valid_i && s_ready_o) begin
                if(bad_r || malformed) begin bad_r<=1;half_r<=0;end
                else if(TRANSPORT_W==64 && !half_r) begin low_r<=masked[63:0];half_addr_r<=word_addr;half_r<=1;end
                else begin
                    out_data_r<=(TRANSPORT_W==64) ? {masked[63:0],low_r} : masked;
                    out_addr_r<=word_addr;out_valid_r<=1;half_r<=0;
                end
            end
            if(s_finish_valid_i && s_finish_ready_o && !wrong_finish) begin active_r<=0;bad_r<=0;half_r<=0;end
        end
    end
    initial begin
        if(TRANSPORT_W!=64 && TRANSPORT_W!=128) $fatal(1,"transport width must be 64 or 128");
        if(DEPTH<2 || AW<1 || (1<<AW)<DEPTH) $fatal(1,"invalid panel address parameters");
    end
endmodule
