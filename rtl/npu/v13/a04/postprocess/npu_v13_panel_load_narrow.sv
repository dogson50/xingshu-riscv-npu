// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p12：入口增加一级已校验窄beat寄存，隔离配对/范围检查到bank载荷写控制的组合路径。
// 载荷仍为TRANSPORT_W，不在全局组装128；默认64，128仅编译期对照。
// 64-bit偶低奇高按上游已接收beat检查；bank叶节点仍只组装合法的下游握手。
// 地址单位是TRANSPORT_W-bit panel beat，不是DDR字节；缺半/错序取消整次装载。
// finish经过下游RAM写可见栅栏；错误目标finish消费报错但不结束真正会话。
module npu_v13_panel_load_narrow #(
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
    output wire [TAW-1:0] m_addr_o, output wire [TRANSPORT_W-1:0] m_data_o,
    output wire m_finish_valid_o, input wire m_finish_ready_i,m_finish_error_i,
    output wire m_finish_operand_o,m_finish_bank_o,m_finish_error_o,
    output wire busy_o
);
    reg active_r,operand_r,bank_r,bad_r,half_r;
    reg beat_valid_r;
    reg [TAW-1:0] beat_addr_r;
    reg [TRANSPORT_W-1:0] beat_data_r;
    reg [AW-1:0] half_addr_r;
    wire [AW-1:0] word_addr=s_addr_i >> (TRANSPORT_W==64);
    wire wrong_finish=!active_r || s_finish_operand_i!=operand_r || s_finish_bank_i!=bank_r;
    wire malformed=s_operand_i!=operand_r || s_bank_i!=bank_r || s_addr_i>=DEPTH*(128/TRANSPORT_W) ||
        ((TRANSPORT_W==64) && ((!half_r && s_addr_i[0]) ||
        (half_r && (!s_addr_i[0] || word_addr!=half_addr_r))));
    reg [TRANSPORT_W-1:0] masked;
    always @* begin
        masked=0;
        for(integer b=0;b<TRANSPORT_W/8;b=b+1) if(s_keep_i[b]) masked[b*8+:8]=s_data_i[b*8+:8];
    end
    assign m_begin_valid_o=resetn && !active_r && !s_finish_valid_i && s_begin_valid_i;
    assign s_begin_ready_o=resetn && !active_r && !s_finish_valid_i && m_begin_ready_i;
    assign s_begin_error_o=m_begin_error_i;
    assign m_begin_operand_o=s_begin_operand_i;assign m_begin_bank_o=s_begin_bank_i;
    // 单槽前向寄存：满槽可随下游出队同拍接收；这里只隔离前向校验，不声称切断反向ready。
    // 载荷采样使能只取上游握手，不取malformed；是否合法单独进入窄valid寄存器。
    assign s_ready_o=resetn && active_r && !s_finish_valid_i && (!beat_valid_r || m_ready_i);
    assign m_valid_o=resetn && beat_valid_r;
    assign m_operand_o=operand_r;assign m_bank_o=bank_r;
    assign m_addr_o=beat_addr_r;assign m_data_o=beat_data_r;
    // finish先等入口beat排空，再交给原manager等待bank本地写可见；错误目标不取消真正会话。
    // 即便finish已拉高，pending beat仍允许向下游发送，避免互等死锁。
    assign m_finish_valid_o=resetn && s_finish_valid_i && !wrong_finish && !beat_valid_r;
    assign m_finish_operand_o=operand_r;assign m_finish_bank_o=bank_r;
    assign m_finish_error_o=s_finish_error_i || bad_r || half_r;
    assign s_finish_ready_o=resetn && (wrong_finish || (!beat_valid_r && m_finish_ready_i));
    assign s_finish_error_o=wrong_finish || bad_r || half_r || (!wrong_finish && m_finish_error_i);
    assign busy_o=active_r || half_r || beat_valid_r;
    always @(posedge clk) begin
        if(!resetn) begin active_r<=0;operand_r<=0;bank_r<=0;bad_r<=0;half_r<=0;beat_valid_r<=0;end
        else begin
            if(beat_valid_r && m_ready_i) beat_valid_r<=0;
            if(s_begin_valid_i && s_begin_ready_o && !s_begin_error_o) begin
                active_r<=1;operand_r<=s_begin_operand_i;bank_r<=s_begin_bank_i;bad_r<=0;half_r<=0;
            end
            if(s_valid_i && s_ready_o) begin
                // 数据/地址不复位，非法载荷也可采样但valid必须为0，绝不向RAM泄漏。
                beat_data_r<=masked;beat_addr_r<=s_addr_i;
                beat_valid_r<=!bad_r && !malformed;
                if(bad_r || malformed) begin bad_r<=1;half_r<=0;end
                else if(TRANSPORT_W==64 && !half_r) begin half_addr_r<=word_addr;half_r<=1;end
                else half_r<=0;
            end
            if(s_finish_valid_i && s_finish_ready_o && !wrong_finish) begin active_r<=0;bad_r<=0;half_r<=0;end
        end
    end
    initial begin
        if(TRANSPORT_W!=64 && TRANSPORT_W!=128) $fatal(1,"transport width must be 64 or 128");
        if(DEPTH<2 || AW<1 || (1<<AW)<DEPTH) $fatal(1,"invalid panel address parameters");
    end
endmodule
