// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 只管理所有权，不解释矩阵地址/数据：A0/A1/B0/B1 四个独立状态。
// release 后回 READY 而非 FREE；同一宏块可反复执行，直到显式 begin 覆写。
module panel_lease_exp(
    input wire clk, // 同步时钟。
    input wire resetn, // 清状态，数据 BRAM 不复位。
    input wire begin_valid_i, // 显式开始装载/替换指定 operand/bank。
    output wire begin_ready_o, // 非 LOADING、非 IN_USE 才能接受替换。
    input wire begin_operand_i, // 0=A，1=B。
    input wire begin_bank_i, // 独立物理 bank 0/1。
    input wire finish_valid_i, // 数据写入流水已经落 RAM 后提交。
    output wire finish_ready_o, // 只有对应 bank 处于 LOADING 才能提交。
    input wire finish_operand_i, // 提交的 operand。
    input wire finish_bank_i, // 提交的 bank。
    input wire acquire_valid_i, // 原子获取一对 A/B；一次宏块内可重放多次。
    output wire acquire_ready_o, // 两者 READY，且本周期不被 begin 替换。
    input wire acquire_a_bank_i, // 本次宏块使用的 A bank。
    input wire acquire_b_bank_i, // 本次宏块使用的 B bank。
    input wire release_i, // 当前宏块所有计算/消费结束，归还为 READY。
    output wire [3:0] loading_o, // bit={operand,bank}，只允许向 LOADING bank 写。
    output wire [3:0] retained_o, // READY 标志，供实验驱动观察预取完成。
    output reg error_o // 非法 release 的黏滞诊断。
);
    localparam FREE=0,LOADING=1,READY=2,IN_USE=3;
    reg [1:0] state_r[0:3];
    reg owned_r,a_bank_r,b_bank_r;
    wire [1:0] bi={begin_operand_i,begin_bank_i};
    wire [1:0] fi={finish_operand_i,finish_bank_i};
    assign begin_ready_o=resetn && state_r[bi]!=LOADING && state_r[bi]!=IN_USE;
    assign finish_ready_o=resetn && state_r[fi]==LOADING;
    wire begin_fire=begin_valid_i && begin_ready_o;
    wire conflicts=begin_fire && ((!begin_operand_i && begin_bank_i==acquire_a_bank_i) ||
                                 (begin_operand_i && begin_bank_i==acquire_b_bank_i));
    assign acquire_ready_o=resetn && !owned_r && !conflicts &&
        state_r[{1'b0,acquire_a_bank_i}]==READY && state_r[{1'b1,acquire_b_bank_i}]==READY;
    genvar g;
    generate for(g=0;g<4;g=g+1) begin:G_FLAGS
        assign loading_o[g]=state_r[g]==LOADING;
        assign retained_o[g]=state_r[g]==READY;
    end endgenerate
    integer i;
    always @(posedge clk) begin
        if(!resetn) begin
            for(i=0;i<4;i=i+1) state_r[i]<=FREE;
            owned_r<=0;error_o<=0;a_bank_r<=0;b_bank_r<=0;
        end else begin
            if(begin_fire) state_r[bi]<=LOADING;
            if(finish_valid_i && finish_ready_o) state_r[fi]<=READY;
            if(acquire_valid_i && acquire_ready_o) begin
                state_r[{1'b0,acquire_a_bank_i}]<=IN_USE;
                state_r[{1'b1,acquire_b_bank_i}]<=IN_USE;
                a_bank_r<=acquire_a_bank_i;b_bank_r<=acquire_b_bank_i;owned_r<=1;
            end
            if(release_i) begin
                if(!owned_r) error_o<=1;
                else begin
                    state_r[{1'b0,a_bank_r}]<=READY;
                    state_r[{1'b1,b_bank_r}]<=READY;
                    owned_r<=0;
                end
            end
        end
    end
endmodule
