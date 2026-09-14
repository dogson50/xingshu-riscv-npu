// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 正式executor与packet数据面之间的薄适配层：只验证panel布局并转换一个batch描述符。
// 绝不自己重新遍历M/N；遍历权属于executor内部的正式tile scheduler。
// P87-B：batch入口与描述符提交之间增加一深弹性边界，切断scheduler坐标到描述符寄存器的跨层长路径。
module npu_v13_exec_panel_adapter #(
    parameter integer MAX_MN=128,MAX_K=512,
    parameter integer DEPTH=(MAX_MN/16)*MAX_K,AW=$clog2(DEPTH)
)(
    input wire clk,resetn,
    input wire prepare_valid_i,
    output wire prepare_ready_o,
    output wire prepare_error_o,
    input wire [1:0] ctx_opcode_i,ctx_mode_i,
    input wire [2:0] ctx_layout_i,
    input wire [31:0] ctx_op_cfg_i,
    input wire [15:0] ctx_m_i,ctx_n_i,ctx_k_i,
    input wire [31:0] ctx_a_base_i,ctx_b_base_i,
    input wire batch_valid_i,
    output wire batch_ready_o,
    input wire [15:0] batch_m_i,batch_n_i,
    output wire desc_valid_o,
    input wire desc_ready_i,
    output wire [AW-1:0] desc_a_o,desc_b_o,
    output wire [15:0] desc_k_o,desc_m_o,desc_n_o,
    output wire [4:0] desc_rows_o,desc_cols_o,
    output wire idle_o,
    output reg protocol_error_o
);
    // stage1：已提交、等待packet backend消费的描述符。
    reg held_r;
    reg [AW-1:0] a_r,b_r;
    reg [15:0] k_r,m_r,n_r;
    reg [4:0] rows_r,cols_r;

    // 命令级冷路径分拍：M/N减一 -> 最后子块偏移 -> 偏移加K -> 加基址 -> 范围比较 -> 回报。
    localparam [2:0] P_IDLE=0,P_OFFSET=1,P_SPAN=2,P_BASE=3,P_CHECK=4,P_REPORT=5;
    reg [2:0] prepare_state_r;
    reg prepared_r,fields_ok_r,prepare_error_r;
    reg [15:0] m_m1_r,n_m1_r;
    reg [15:0] local_k_r;
    reg [AW-1:0] local_a_base_r,local_b_base_r;
    reg [11:0] last_m_group_r,last_n_group_r;
    reg [4:0] tail_rows_r,tail_cols_r;
    reg [AW-1:0] a_offset_r,b_offset_r;
    reg [AW:0] a_span_r,b_span_r;
    reg [AW+1:0] a_end_r,b_end_r;
    localparam [AW+1:0] DEPTH_LIMIT=DEPTH;

    wire fields_ok=ctx_opcode_i==0 && ctx_mode_i==0 && ctx_layout_i==0 && ctx_op_cfg_i==0 &&
        ctx_m_i>0 && ctx_m_i<=MAX_MN && ctx_n_i>0 && ctx_n_i<=MAX_MN && ctx_k_i>0 && ctx_k_i<=MAX_K &&
        ctx_a_base_i[31:AW]==0 && ctx_b_base_i[31:AW]==0;
    assign prepare_ready_o=resetn && prepare_state_r==P_REPORT;
    assign prepare_error_o=prepare_state_r==P_REPORT && prepare_error_r;

    // stage0：只锁存scheduler batch边界字段。stage0与stage1可同拍移位和重新装载，稳态II=1。
    reg ingress_valid_r;
    reg [11:0] ingress_m_group_r,ingress_n_group_r;
    reg [3:0] ingress_m_low_r,ingress_n_low_r;
    wire desc_slot_ready=!held_r || desc_ready_i;
    wire ingress_advance=ingress_valid_r && desc_slot_ready;
    wire ingress_slot_ready=!ingress_valid_r || desc_slot_ready;
    assign batch_ready_o=resetn && prepared_r && prepare_state_r==P_IDLE && !prepare_valid_i && ingress_slot_ready;
    wire batch_fire=batch_valid_i && batch_ready_o;

    wire ingress_batch_ok=ingress_m_low_r==0 && ingress_n_low_r==0 &&
        ingress_m_group_r<=last_m_group_r && ingress_n_group_r<=last_n_group_r;
    wire ingress_m_last=ingress_m_group_r==last_m_group_r;
    wire ingress_n_last=ingress_n_group_r==last_n_group_r;

    assign desc_valid_o=resetn && held_r;
    assign idle_o=!held_r && !ingress_valid_r;
    assign desc_a_o=a_r;assign desc_b_o=b_r;assign desc_k_o=k_r;
    assign desc_m_o=m_r;assign desc_n_o=n_r;assign desc_rows_o=rows_r;assign desc_cols_o=cols_r;

    always @(posedge clk) begin
        if(!resetn) begin prepare_state_r<=P_IDLE;prepared_r<=0;prepare_error_r<=0;end
        else case(prepare_state_r)
            P_IDLE: if(prepare_valid_i && !held_r && !ingress_valid_r) begin
                prepared_r<=0;fields_ok_r<=fields_ok;m_m1_r<=ctx_m_i-16'd1;n_m1_r<=ctx_n_i-16'd1;
                local_k_r<=ctx_k_i;local_a_base_r<=ctx_a_base_i[AW-1:0];local_b_base_r<=ctx_b_base_i[AW-1:0];
                prepare_state_r<=P_OFFSET;
            end
            P_OFFSET: begin
                a_offset_r<=m_m1_r[15:4]*MAX_K;b_offset_r<=n_m1_r[15:4]*MAX_K;
                last_m_group_r<=m_m1_r[15:4];last_n_group_r<=n_m1_r[15:4];
                tail_rows_r<={1'b0,m_m1_r[3:0]}+5'd1;tail_cols_r<={1'b0,n_m1_r[3:0]}+5'd1;
                prepare_state_r<=P_SPAN;
            end
            P_SPAN: begin
                a_span_r<={1'b0,a_offset_r}+local_k_r;b_span_r<={1'b0,b_offset_r}+local_k_r;
                prepare_state_r<=P_BASE;
            end
            P_BASE: begin
                a_end_r<={2'b0,local_a_base_r}+{1'b0,a_span_r};
                b_end_r<={2'b0,local_b_base_r}+{1'b0,b_span_r};
                prepare_state_r<=P_CHECK;
            end
            P_CHECK: begin
                prepare_error_r<=!fields_ok_r || a_end_r>DEPTH_LIMIT || b_end_r>DEPTH_LIMIT;
                prepare_state_r<=P_REPORT;
            end
            P_REPORT: if(prepare_valid_i) begin
                prepared_r<=!prepare_error_r;prepare_state_r<=P_IDLE;
            end
            default: begin prepare_state_r<=P_IDLE;prepared_r<=0;end
        endcase
    end

    // 两级弹性提交：
    // 1. scheduler只驱动本地ingress寄存器，不再直接到rows/cols/address描述符寄存器；
    // 2. stage1有空位时使用上一拍本地字段生成描述符；数据字段无条件写，合法性只控制valid，
    //    避免宽batch_ok比较被吸收到rows_r/cols_r的同步reset端。
    always @(posedge clk) begin
        if(!resetn) begin
            held_r<=0;ingress_valid_r<=0;protocol_error_o<=0;
        end else begin
            if(desc_slot_ready) begin
                if(ingress_valid_r) begin
                    held_r<=ingress_batch_ok;
                    a_r<=local_a_base_r+ingress_m_group_r*MAX_K;
                    b_r<=local_b_base_r+ingress_n_group_r*MAX_K;
                    k_r<=local_k_r;
                    m_r<={ingress_m_group_r,4'b0000};
                    n_r<={ingress_n_group_r,4'b0000};
                    rows_r<=ingress_m_last?tail_rows_r:5'd16;
                    cols_r<=ingress_n_last?tail_cols_r:5'd16;
                    if(!ingress_batch_ok) protocol_error_o<=1;
                end else held_r<=0;
            end

            case({batch_fire,ingress_advance})
                2'b10,2'b11: begin
                    ingress_valid_r<=1;
                    ingress_m_group_r<=batch_m_i[15:4];
                    ingress_n_group_r<=batch_n_i[15:4];
                    ingress_m_low_r<=batch_m_i[3:0];
                    ingress_n_low_r<=batch_n_i[3:0];
                end
                2'b01: ingress_valid_r<=0;
                default: ;
            endcase
        end
    end

    // synthesis translate_off
    initial if(MAX_MN<16 || MAX_MN%16!=0 || MAX_MN>65535 || MAX_K<1 || MAX_K>65535 ||
        DEPTH!=(MAX_MN/16)*MAX_K || AW<1 || AW<$clog2(DEPTH) || AW>31) $fatal(1,"adapter parameters");
    reg [150:0] context_snapshot;
    wire [150:0] context_value={ctx_opcode_i,ctx_mode_i,ctx_layout_i,ctx_op_cfg_i,ctx_m_i,ctx_n_i,ctx_k_i,ctx_a_base_i,ctx_b_base_i};
    always @(posedge clk) if(resetn) begin
        if(prepare_state_r==P_IDLE && prepare_valid_i && !held_r && !ingress_valid_r) context_snapshot<=context_value;
        else if(prepare_state_r!=P_IDLE && (!prepare_valid_i || context_value!==context_snapshot))
            $fatal(1,"prepare valid/context changed before result handshake");
        if(batch_valid_i && !batch_ready_o && (batch_m_i!==batch_m_i || batch_n_i!==batch_n_i))
            $fatal(1,"batch fields unknown while stalled");
    end
    // synthesis translate_on
endmodule