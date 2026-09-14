// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 同步 BRAM FIFO：RAM 读出级 + 输出预加载级；输入 ready 只依赖本地占用。
// DEPTH 是整个 FIFO 对外承诺的容量，包含两级寄存器中的数据，保守不额外借容量。
// 不复位数据 RAM/宽数据寄存器，只清 valid、指针、计数；旧数据不可见。
module npu_v13_result_bram_fifo #(
    parameter integer WIDTH=181, DEPTH=128,
    parameter integer AW=$clog2(DEPTH), CW=$clog2(DEPTH+1)
)(
    input wire clk, // 同一计算时钟域。
    input wire resetn, // 低有效同步控制复位，必须与生产者/消费者协调。
    input wire in_valid_i, // 本拍输入数据有效；等待 ready 时保持。
    output wire in_ready_o, // 有完整容量，不组合依赖 out_ready_i。
    input wire [WIDTH-1:0] in_data_i, // 数据和元数据整体写入，防止错拍。
    output wire out_valid_o, // 已预加载的队首有效。
    input wire out_ready_i, // 消费者本拍能接收；valid&&ready 才出队。
    output wire [WIDTH-1:0] out_data_o, // 反压时保持稳定。
    output wire [CW-1:0] used_o // 包含 RAM 未读、RAM 读出、输出级的全部数据。
);
    (* ram_style="block" *) reg [WIDTH-1:0] mem[0:DEPTH-1];
    reg [AW-1:0] wr_r,rd_r;
    reg [CW-1:0] total_r,unread_r;
    reg ram_valid_r,out_valid_r;
    reg [WIDTH-1:0] ram_data_r,out_data_r;
    assign in_ready_o=resetn && total_r<DEPTH;
    assign out_valid_o=resetn && out_valid_r;
    assign out_data_o=out_data_r;
    assign used_o=total_r;
    wire push=in_valid_i && in_ready_o;
    wire pop=out_valid_o && out_ready_i;
    wire out_open=!out_valid_r || out_ready_i;
    wire ram_open=!ram_valid_r || out_open;
    wire read_en=resetn && unread_r!=0 && ram_open;
    // BRAM 单写口+同步单读口。只有未读数据存在才读，不依赖同址读写模式。
    always @(posedge clk) begin
        if(push) mem[wr_r]<=in_data_i;
        if(read_en) ram_data_r<=mem[rd_r];
        if(resetn && out_open && ram_valid_r) out_data_r<=ram_data_r;
    end
    // valid 是数据所在位置的标记；预取不等于出队，只有 pop 减 total。
    always @(posedge clk) begin
        if(!resetn) begin
            wr_r<=0;rd_r<=0;total_r<=0;unread_r<=0;ram_valid_r<=0;out_valid_r<=0;
        end else begin
            if(push) wr_r<=(wr_r==DEPTH-1)?0:wr_r+1'b1;
            if(read_en) rd_r<=(rd_r==DEPTH-1)?0:rd_r+1'b1;
            case({push,pop}) 2'b10:total_r<=total_r+1'b1;2'b01:total_r<=total_r-1'b1;default:;endcase
            case({push,read_en}) 2'b10:unread_r<=unread_r+1'b1;2'b01:unread_r<=unread_r-1'b1;default:;endcase
            if(out_open) out_valid_r<=ram_valid_r;
            if(read_en) ram_valid_r<=1;else if(out_open) ram_valid_r<=0;
        end
    end
    // synthesis translate_off
    initial if(DEPTH<4 || (1<<AW)<DEPTH) $fatal(1,"result FIFO parameters");
    always @(posedge clk) if(resetn && total_r != unread_r+ram_valid_r+out_valid_r)
        $fatal(1,"result FIFO occupancy invariant");
    // synthesis translate_on
endmodule
