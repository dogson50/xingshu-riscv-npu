// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// P4 INT8响应在本地打包为64/128-bit；数值仍为INT8，内部PSUM不受影响。
// 一条row/segment由last结束；尾部空字节清零。meta={bank,tag,m,n}取本输出首P4坐标。
// 同一打包字内必须同bank/tag/m且n连续+4，非最后一个P4不得带空lane；违例在输出error报告。
// 每拍最多接受一个32-bit响应，64-bit满字至少需要两拍；不冒称增加BRAM读吞吐。
module npu_v13_feature_transport_pack #(
    parameter integer TRANSPORT_W=64, WORDS=TRANSPORT_W/32, CW=$clog2(WORDS)
)(
    input wire clk,resetn,
    input wire s_valid_i, output wire s_ready_o,
    input wire [31:0] s_data_i, input wire [3:0] s_keep_i,
    input wire [48:0] s_meta_i, input wire s_error_i,s_last_i,
    output wire m_valid_o, input wire m_ready_i,
    output wire [TRANSPORT_W-1:0] m_data_o,
    output wire [TRANSPORT_W/8-1:0] m_keep_o,
    output wire [48:0] m_meta_o, output wire m_error_o,m_last_o,
    output wire busy_o
);
    reg [CW-1:0] count_r;
    reg [TRANSPORT_W-1:0] partial_r,data_r;
    reg [TRANSPORT_W/8-1:0] partial_keep_r,keep_r;
    reg [48:0] first_meta_r,meta_r;
    reg partial_error_r,previous_partial_r,valid_r,error_r,last_r;
    wire [15:0] expected_n=first_meta_r[15:0]+(count_r*4);
    wire mismatch=(count_r!=0) && (s_meta_i[48:16]!=first_meta_r[48:16] || s_meta_i[15:0]!=expected_n || previous_partial_r);
    reg [TRANSPORT_W-1:0] assembled;
    reg [TRANSPORT_W/8-1:0] assembled_keep;
    always @* begin
        assembled=(count_r==0) ? 0 : partial_r;
        assembled_keep=(count_r==0) ? 0 : partial_keep_r;
        for(integer b=0;b<4;b=b+1) begin
            assembled[count_r*32+b*8+:8]=s_keep_i[b] ? s_data_i[b*8+:8] : 8'd0;
            assembled_keep[count_r*4+b]=s_keep_i[b];
        end
    end
    assign s_ready_o=resetn && (!valid_r || m_ready_i);
    assign m_valid_o=resetn && valid_r; assign m_data_o=data_r;assign m_keep_o=keep_r;
    assign m_meta_o=meta_r;assign m_error_o=error_r;assign m_last_o=last_r;
    assign busy_o=(count_r!=0) || valid_r;
    always @(posedge clk) begin
        if(!resetn) begin count_r<=0;valid_r<=0;partial_error_r<=0;previous_partial_r<=0;end
        else begin
            if(valid_r && m_ready_i) valid_r<=0;
            if(s_valid_i && s_ready_o) begin
                if(s_last_i || count_r==WORDS-1) begin
                    data_r<=assembled;keep_r<=assembled_keep;meta_r<=(count_r==0) ? s_meta_i : first_meta_r;
                    error_r<=s_error_i || mismatch || ((count_r!=0) && partial_error_r);
                    last_r<=s_last_i;valid_r<=1;count_r<=0;partial_error_r<=0;previous_partial_r<=0;
                end else begin
                    partial_r<=assembled;partial_keep_r<=assembled_keep;count_r<=count_r+1'b1;
                    if(count_r==0) first_meta_r<=s_meta_i;
                    partial_error_r<=s_error_i || mismatch || ((count_r!=0) && partial_error_r);
                    previous_partial_r<=s_keep_i!=4'hf;
                end
            end
        end
    end
    initial if(TRANSPORT_W!=64 && TRANSPORT_W!=128) $fatal(1,"feature transport width must be 64 or 128");
endmodule
