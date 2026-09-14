// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 同域输入/输出寄存夹具：外部端口豁免只覆盖端口到夹具，不豁免任何DUT内部路径。
// 包含reset、ready、数据和metadata，禁止把它们固定为常量让综合删除真实控制逻辑。
module psum_timing #(
    parameter integer DEPTH=1024,AW=$clog2(DEPTH),MW=32,
    parameter integer IW=1+1+AW+128+4+1+1+MW+1,
    parameter integer OW=2+128+4+AW+MW+3+4+AW+MW+2
)(
    input wire clk, // 目标计算时钟。
    input wire [IW-1:0] stimulus_i, // 夹具未寄存输入，真实数据均可变化。
    output reg [OW-1:0] observation_o // 夹具已寄存观察输出，不代表DDR引脚。
);
    reg [IW-1:0] launch_r;
    wire resetn,iv,ir,first,final_chunk,ov,ordy,cv,ce,cf,idle,error;
    wire [AW-1:0] ia,oa,ca;
    wire [127:0] idata,od;
    wire [3:0] ik,ok,ck;
    wire [MW-1:0] im,om,cm;
    assign {resetn,iv,ia,idata,ik,first,final_chunk,im,ordy}=launch_r;
    always @(posedge clk) begin
        launch_r<=stimulus_i;
        observation_o<={ir,ov,od,ok,oa,om,cv,ce,cf,ck,ca,cm,idle,error};
    end
    npu_v13_psum_p4 #(.DEPTH(DEPTH),.ADDR_W(AW),.META_W(MW)) u_dut(
        .clk(clk),.resetn(resetn),.in_valid_i(iv),.in_ready_o(ir),.in_addr_i(ia),.in_data_i(idata),
        .in_keep_i(ik),.in_first_i(first),.in_final_i(final_chunk),.in_meta_i(im),
        .out_valid_o(ov),.out_ready_i(ordy),.out_data_o(od),.out_keep_o(ok),.out_addr_o(oa),.out_meta_o(om),
        .commit_valid_o(cv),.commit_error_o(ce),.commit_final_o(cf),.commit_keep_o(ck),
        .commit_addr_o(ca),.commit_meta_o(cm),.idle_o(idle),.error_o(error));
    // synthesis translate_off
    initial begin
        if($bits({resetn,iv,ia,idata,ik,first,final_chunk,im,ordy})!=IW) $fatal(1,"PSUM fixture input width");
        if($bits({ir,ov,od,ok,oa,om,cv,ce,cf,ck,ca,cm,idle,error})!=OW) $fatal(1,"PSUM fixture output width");
    end
    // synthesis translate_on
endmodule
