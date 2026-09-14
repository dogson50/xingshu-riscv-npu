// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p10：先按{operand,bank}选择A0/A1/B0/B1，再在各bank叶节点拼成128-bit写字。
// 搬运地址按LOAD_W-bit beat计数；64-bit偶低奇高。上游必须先检查配对/所有权/范围。
// 仅有效与写使能复位；payload/BRAM不清零。读接口仍为每拍A128+B128，固定两拍响应。
// local层级表示逻辑归属，不强制布局；必须用综合/布线审计确认实际寄存器与RAM距离。
module npu_v13_panel_ram_local #(
    parameter integer MAX_MN=128,MAX_K=512,LOAD_W=128,
    parameter integer DEPTH=(MAX_MN/16)*MAX_K,AW=$clog2(DEPTH),TAW=AW+(LOAD_W==64)
)(
    input wire clk,resetn,
    input wire wr_valid_i,wr_operand_i,wr_bank_i,
    input wire [TAW-1:0] wr_addr_i,
    input wire [LOAD_W-1:0] wr_data_i,
    output wire writes_pending_o,
    input wire rd_valid_i,rd_a_bank_i,rd_b_bank_i,
    input wire [AW-1:0] rd_a_addr_i,rd_b_addr_i,
    output wire rd_valid_o,
    output wire [127:0] rd_a_o,rd_b_o
);
    reg [1:0] rv_r,ab_r,bb_r;
    wire [3:0] local_pending;
    wire [127:0] qr[0:3];
    always @(posedge clk) begin
        if(!resetn) rv_r<=0;else rv_r<={rv_r[0],rd_valid_i};
        ab_r<={ab_r[0],rd_a_bank_i};bb_r<={bb_r[0],rd_b_bank_i};
    end
    // 包含当拍写与已接受的本地128位提交；finish必须晚于真实RAM写可见。
    assign writes_pending_o=resetn && (wr_valid_i || (|local_pending));
    assign rd_valid_o=rv_r[1];
    assign rd_a_o=ab_r[1]?qr[1]:qr[0];assign rd_b_o=bb_r[1]?qr[3]:qr[2];
    genvar p;
    generate for(p=0;p<4;p=p+1) begin:G_BANK
        (* ram_style="block" *) reg [127:0] mem[0:DEPTH-1];
        reg we,re;
        reg [AW-1:0] wa,ra;
        reg [127:0] wd,q;
        wire take=resetn && wr_valid_i && {wr_operand_i,wr_bank_i}==p;
        if(LOAD_W==64) begin:G_NARROW
            reg [63:0] low_r;
            // 低半只在选定bank捕获；第二拍本地拼128，宽载荷不再全局分发。
            always @(posedge clk) begin
                we<=take && wr_addr_i[0];
                if(take && !wr_addr_i[0]) low_r<=wr_data_i;
                if(take && wr_addr_i[0]) begin wa<=wr_addr_i[TAW-1:1];wd<={wr_data_i,low_r};end
            end
        end else begin:G_WIDE
            always @(posedge clk) begin
                we<=take;
                if(take) begin wa<=wr_addr_i;wd<=wr_data_i;end
            end
        end
        always @(posedge clk) begin
            re<=resetn && rd_valid_i && ((p<2)?(rd_a_bank_i==(p%2)):(rd_b_bank_i==(p%2)));
            ra<=(p<2)?rd_a_addr_i:rd_b_addr_i;
            // 复位取消尚未落RAM的提交，不依靠复位payload；读取有效流水独立取消。
            if(resetn && we) mem[wa]<=wd;
            if(re) q<=mem[ra];
        end
        assign local_pending[p]=we;
        assign qr[p]=q;
    end endgenerate
    initial begin
        if(LOAD_W!=64 && LOAD_W!=128) $fatal(1,"invalid local panel load width");
        if(DEPTH<2 || AW<1 || (1<<AW)<DEPTH || TAW!=AW+(LOAD_W==64)) $fatal(1,"invalid local panel address parameters");
    end
endmodule
