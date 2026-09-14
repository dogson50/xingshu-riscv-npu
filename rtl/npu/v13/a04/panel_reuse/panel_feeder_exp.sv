// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// packet 级启动、逐拍流水预取。允许包内气泡；valid=0 不冻结任何返回流水。
module panel_feeder_exp #(
    parameter integer G=16,S=1,AW=12,WORD_W=G*S*8,MAX_K=512,KW=$clog2(MAX_K/S+1)
)(
    input wire clk, // 时钟。
    input wire resetn, // 清空控制 token。
    input wire packet_valid_i, // 同拍已取得 C 容量的描述符。
    output wire packet_ready_o, // 尾请求当拍可接受下一 packet。
    input wire [AW-1:0] a_base_i,b_base_i, // A/B panel word 起址。
    input wire [15:0] steps_i, // ceil(K/S)，不为零。
    input wire [2:0] last_lanes_i, // 最后一 beat 的有效 SIMD lane 数。
    input wire [4:0] rows_i,cols_i, // 动态 shape。
    input wire allow_beat_i, // 0 只暂停新 RAM 请求，不暂停在途响应。
    output wire rd_valid_o, // 请求 A/B 同步读。
    output wire [AW-1:0] rd_a_addr_o,rd_b_addr_o, // 固定延迟 RAM 的地址。
    input wire ram_valid_i, // RAM 延迟两拍的响应有效。
    input wire [WORD_W-1:0] ram_a_i,ram_b_i, // packed word。
    output reg valid_o,init_o,last_o, // 输出再寄存一拍，对接核固定速率输入。
    output reg [4:0] rows_o,cols_o, // 同拍 shape，在 init 时由核锁存。
    output reg [WORD_W-1:0] a_o,b_o, // K 尾 lane 已强制归零。
    output wire idle_o // 请求与响应都已排空。
);
    reg running_r;
    reg [AW-1:0] abase_r,bbase_r;
    reg [KW-1:0] step_r,last_step_r;
    reg [2:0] lanes_r;
    reg [4:0] rows_r,cols_r;
    reg [1:0] v_r,i_r,l_r;
    reg [4:0] rp_r[0:1],cp_r[0:1];
    reg [2:0] lp_r[0:1];
    assign rd_valid_o=resetn && running_r && allow_beat_i;
    wire tail=step_r==last_step_r;
    assign packet_ready_o=resetn && (!running_r || (rd_valid_o && tail));
    assign rd_a_addr_o=abase_r+step_r;
    assign rd_b_addr_o=bbase_r+step_r;
    assign idle_o=!running_r && v_r==0 && !valid_o;
    integer row,lane;
    always @(posedge clk) begin
        if(!resetn) begin
            running_r<=0;v_r<=0;i_r<=0;l_r<=0;valid_o<=0;init_o<=0;last_o<=0;
            step_r<=0;last_step_r<=0;abase_r<=0;bbase_r<=0;lanes_r<=S;rows_r<=1;cols_r<=1;
        end else begin
            v_r<={v_r[0],rd_valid_o};i_r<={i_r[0],step_r==0};l_r<={l_r[0],tail};
            if(rd_valid_o) begin
                if(tail) begin running_r<=0;step_r<=0;end
                else step_r<=step_r+1'b1;
            end
            if(packet_valid_i && packet_ready_o) begin
                running_r<=1;abase_r<=a_base_i;bbase_r<=b_base_i;step_r<=0;last_step_r<=steps_i[KW-1:0]-1'b1;
                lanes_r<=last_lanes_i;rows_r<=rows_i;cols_r<=cols_i;
            end
            valid_o<=ram_valid_i;init_o<=i_r[1];last_o<=l_r[1];
        end
        rp_r[0]<=rows_r;rp_r[1]<=rp_r[0];cp_r[0]<=cols_r;cp_r[1]<=cp_r[0];
        lp_r[0]<=lanes_r;lp_r[1]<=lp_r[0];
        rows_o<=rp_r[1];cols_o<=cp_r[1];
        for(row=0;row<G;row=row+1) for(lane=0;lane<S;lane=lane+1) begin
            a_o[(row*S+lane)*8+:8]<=(l_r[1] && lane>=lp_r[1])?8'b0:ram_a_i[(row*S+lane)*8+:8];
            b_o[(row*S+lane)*8+:8]<=(l_r[1] && lane>=lp_r[1])?8'b0:ram_b_i[(row*S+lane)*8+:8];
        end
    end
    // synthesis translate_off
    always @(posedge clk) if(resetn && ram_valid_i!==v_r[1]) $fatal(1,"RAM/feeder latency mismatch");
    // synthesis translate_on
endmodule
