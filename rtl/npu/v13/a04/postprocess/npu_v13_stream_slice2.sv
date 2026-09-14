// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 两槽ready/valid寄存切片：输入ready仅由本地已寄存满状态决定，不组合依赖下游ready。
// front固定作为输出，back吸收最后一个尚在途的输入；无反压时持续II=1。
// 满后刚开始排空的第一拍不接收新输入，这是切断ready路径的代价，不丢数据。
module npu_v13_stream_slice2 #(
    parameter integer WIDTH=180
)(
    input wire clk, // 同域时钟；本模块不是异步FIFO。
    input wire resetn, // 同步取消两槽valid；数据寄存器不复位。
    input wire in_valid_i, // 输入payload有效，等待ready时保持。
    output wire in_ready_o, // 两槽尚未全满；没有out_ready到此端口的组合路径。
    input wire [WIDTH-1:0] in_data_i, // 数据和身份/参数必须一起打包。
    output wire out_valid_o, // front有效。
    input wire out_ready_i, // 下游接受front；可任意停顿。
    output wire [WIDTH-1:0] out_data_o, // 反压期间保持稳定的front。
    output wire idle_o // 两槽都空；用于完成栅栏。
);
    reg front_valid_r,full_r;
    reg [WIDTH-1:0] front_r,back_r;
    wire push=in_valid_i && in_ready_o,pop=out_valid_o && out_ready_i;
    assign in_ready_o=resetn && !full_r;
    assign out_valid_o=resetn && front_valid_r;
    assign out_data_o=front_r;
    assign idle_o=!front_valid_r;
    always @(posedge clk) begin
        if(!resetn)begin front_valid_r<=0;full_r<=0;end
        else begin
            case({push,pop})
                2'b10:begin front_valid_r<=1;full_r<=front_valid_r;end
                2'b01:begin front_valid_r<=full_r;full_r<=0;end
                2'b11:begin front_valid_r<=1;full_r<=0;end
                default:begin end
            endcase
            if(pop && full_r)front_r<=back_r;
            if(push)begin
                if(front_valid_r && !pop)back_r<=in_data_i;
                else front_r<=in_data_i;
            end
        end
    end
    // synthesis translate_off
    initial if(WIDTH<1)$fatal(1,"SLICE WIDTH must be positive");
    always @(posedge clk)if(resetn && full_r && !front_valid_r)$fatal(1,"SLICE invalid occupancy");
    // synthesis translate_on
endmodule
