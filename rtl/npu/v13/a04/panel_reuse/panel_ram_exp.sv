// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 真正的独立 A0/A1/B0/B1 同步 BRAM。每个 panel word 含 G 行/列、每项 S 个 K lane。
// word=(m_or_n/G)*(MAX_K/S)+k/S；SIMD4 的一个 word 分两个 128-bit DDR beat 写。
// 写口先打本地边界拍，再落 RAM；读地址/使能也先打一拍再同步读取，响应延迟两拍。
module panel_ram_exp #(
    parameter integer G=16,S=1,MAX_MN=128,MAX_K=512,
    parameter integer WORD_W=G*S*8,
    parameter integer DEPTH=(MAX_MN/G)*(MAX_K/S),
    parameter integer AW=$clog2(DEPTH)
)(
    input wire clk, // BRAM 时钟。
    input wire resetn, // 仅复位有效流水。
    input wire wr_valid_i, // 已通过所有权检查的 128-bit 写事件。
    input wire wr_operand_i, // 0=A、1=B。
    input wire wr_bank_i, // 物理 bank。
    input wire [AW-1:0] wr_addr_i, // panel word 地址，不是字节地址。
    input wire wr_half_i, // WORD_W=256 时选择低/高 128 bit；128 时必须 0。
    input wire [127:0] wr_data_i, // 实际接受的 DDR 载荷。
    output wire writes_pending_o, // 还有已接受但未落 RAM 的写；此时不能发布 READY。
    input wire rd_valid_i, // 每个高电平读取 A/B 一对 word，可每拍连续读取。
    input wire rd_a_bank_i, // 此 packet 的 A bank。
    input wire rd_b_bank_i, // 此 packet 的 B bank。
    input wire [AW-1:0] rd_a_addr_i, // A 子块地址。
    input wire [AW-1:0] rd_b_addr_i, // B 子块地址。
    output wire rd_valid_o, // 请求延迟两拍；没有响应 ready。
    output wire [WORD_W-1:0] rd_a_o, // 与 rd_valid_o 对齐的 A word。
    output wire [WORD_W-1:0] rd_b_o // 与 rd_valid_o 对齐的 B word。
);
    reg [1:0] rv_r;
    reg [1:0] ab_r,bb_r;
    reg wp_r;
    always @(posedge clk) begin
        if(!resetn) begin rv_r<=0;wp_r<=0;end
        else begin rv_r<={rv_r[0],rd_valid_i};wp_r<=wr_valid_i;end
        ab_r<={ab_r[0],rd_a_bank_i};bb_r<={bb_r[0],rd_b_bank_i};
    end
    assign writes_pending_o=wp_r || wr_valid_i;
    assign rd_valid_o=rv_r[1];
    wire [WORD_W-1:0] qr[0:3];
    assign rd_a_o=ab_r[1]?qr[1]:qr[0];
    assign rd_b_o=bb_r[1]?qr[3]:qr[2];
    genvar p,h;
    generate for(p=0;p<4;p=p+1) begin:G_BANK
        for(h=0;h<WORD_W/128;h=h+1) begin:G_SLICE
            (* ram_style="block" *) reg [127:0] mem[0:DEPTH-1];
            reg we,re;
            reg [AW-1:0] wa,ra;
            reg [127:0] wd,q;
            always @(posedge clk) begin
                we<=resetn && wr_valid_i && {wr_operand_i,wr_bank_i}==p && wr_half_i==h;
                wa<=wr_addr_i;wd<=wr_data_i;
                re<=resetn && rd_valid_i && ((p<2)?(rd_a_bank_i==(p%2)):(rd_b_bank_i==(p%2)));
                ra<=(p<2)?rd_a_addr_i:rd_b_addr_i;
                if(we) mem[wa]<=wd;
                if(re) q<=mem[ra];
            end
            assign qr[p][h*128+:128]=q;
        end
    end endgenerate
endmodule
