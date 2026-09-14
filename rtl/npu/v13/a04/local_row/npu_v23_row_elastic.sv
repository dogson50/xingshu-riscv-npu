// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p23：两字本地弹性输出，反压只进入窄指针/占用寄存器，不组合控制宽 payload 写使能。
// full 时不借用同拍 pop 信用；两槽仍支持正常流连续 II=1，满后恢复无输出气泡。
module npu_v23_row_elastic #(parameter integer W=183)(
    input wire clk,resetn, // 协调复位只取消有效事务；数据不复位。
    input wire in_valid_i, // 本地可读行；只有握手才推进上游行游标。
    output wire in_ready_o, // 仅由本地已寄存占用决定，不依赖下游 ready。
    input wire [W-1:0] in_data_i, // 含完整数据、keep、行号、tag 和末行标记。
    output wire out_valid_o,
    input wire out_ready_i,
    output wire [W-1:0] out_data_o,
    output wire [1:0] used_o
);
    reg [1:0] fill_r;
    reg write_slot_r,read_slot_r;
    wire room_w=!fill_r[1]; // 合法占用只有0/1/2；2为full。
    wire push_w=in_valid_i && in_ready_o;
    wire pop_w=out_valid_o && out_ready_i;
    wire [2*W-1:0] bank_data;
    assign in_ready_o=resetn && room_w;
    assign out_valid_o=resetn && (fill_r!=0);
    assign out_data_o=read_slot_r ? bank_data[W+:W] : bank_data[0+:W];
    assign used_o=fill_r;
    genvar g;
    generate for(g=0;g<2;g=g+1)begin:G_WORD
        reg [W-1:0] payload_r;
        // write_slot总是指向空槽。允许投机覆盖空槽，不检查in_valid或reset，
        // 但绝不覆盖已占用槽；有效性只在真正push时登记。空闲翻转功耗另测。
        // out_ready到这些宽寄存器的CE必须经过fill/write_slot的寄存边界。
        always @(posedge clk)
            if(room_w && write_slot_r==g)payload_r<=in_data_i;
        assign bank_data[g*W+:W]=payload_r;
    end endgenerate
    always @(posedge clk or negedge resetn)begin
        if(!resetn)begin fill_r<=0;write_slot_r<=0;read_slot_r<=0;end
        else begin
            case({push_w,pop_w})
                2'b10:fill_r<=fill_r+1'b1;
                2'b01:fill_r<=fill_r-1'b1;
                default:fill_r<=fill_r;
            endcase
            if(push_w)write_slot_r<=~write_slot_r;
            if(pop_w)read_slot_r<=~read_slot_r;
        end
    end
    // synthesis translate_off
    initial if(W<1)$fatal(1,"ROW_ELASTIC width");
    always @(posedge clk)if(resetn)begin
        if(fill_r>2)$fatal(1,"ROW_ELASTIC occupancy");
        if((fill_r==1 && write_slot_r==read_slot_r) || (fill_r!=1 && write_slot_r!=read_slot_r))
            $fatal(1,"ROW_ELASTIC slot ownership");
    end
    // synthesis translate_on
endmodule
