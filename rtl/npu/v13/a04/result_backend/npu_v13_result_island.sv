// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 一组四个物理 tile：小型无反压捕获槽 -> 本地轮询 -> 单写/单读 BRAM FIFO -> P4。
// 第一版固定四个 tile 位于同一 tile 行，按 TILE_ROW 参数解释全局坐标。
// 每个 tile 结果固定占四字；无效行仍携带 keep=0，并在第四字握手后释放预约。
// TOTAL_SLOTS 约束从计算启动到最终消费的总容量；CAPTURE_SLOTS 约束各 tile 短暂捕获。
module npu_v13_result_island #(
    parameter integer TILE_ROW=0, TOTAL_SLOTS=32, CAPTURE_SLOTS=4,
    parameter integer UW=$clog2(TOTAL_SLOTS+1)
)(
    input wire clk, // 与计算核同域。
    input wire resetn, // 清空事务状态；不清缓存内容。
    input wire reserve_valid_i, // 原子预约事件；仅 valid&&ready 记账。
    output wire reserve_ready_o, // mask 内各 tile 有捕获槽，且最终容量足够。
    input wire [3:0] reserve_mask_i, // 本组参与本 packet 的 tile；零 mask 不占容量。
    input wire [15:0] reserve_tag_i, // 命令 tag，随结果原样输出。
    input wire [15:0] reserve_m_i, // 整个16x16输出子块的行起点。
    input wire [15:0] reserve_n_i, // 整个16x16输出子块的列起点。
    input wire [3:0] result_valid_i, // 四 tile 独立结果事件；没有 ready，必须提前预约。
    input wire [2047:0] result_data_i, // 四份本地 row-major 4x4 INT32。
    input wire [15:0] result_shape_i, // 每 tile 四位 {rows_m1,cols_m1}。
    output wire out_valid_o, // 本组P4数据有效。
    input wire out_ready_i, // 本组消费者反压，不影响其他组的输出握手。
    output wire [127:0] out_data_o, // 一行四个INT32，低列在低位。
    output wire [3:0] out_keep_o, // 四个元素有效位；允许整字为零mask。
    output wire [15:0] out_tag_o, // 任务标识；与数据共用队列，不另走延迟线。
    output wire [15:0] out_m_o, // 当前输出行坐标。
    output wire [15:0] out_n_o, // 当前四元素的起始列坐标。
    output wire out_tile_last_o, // tile的第四字；不代表命令最后一个tile。
    output wire retire_o, // 第四字真正消费，归还一个最终结果槽。
    output wire [UW-1:0] used_o, // 已预约尚未最终退休，包括尚未计算返回。
    output wire empty_o, // 本组无任何在途/已缓存结果。
    output wire error_o // 捕获协议或容量守恒错误，黏滞到协调复位。
);
    localparam integer PW=181;
    reg [UW-1:0] used_r;
    reg accounting_error_r;
    wire [3:0] capture_ready,cv,cr,ce;
    wire [4*PW-1:0] cp;
    wire [2:0] request_count={2'b0,reserve_mask_i[0]}+{2'b0,reserve_mask_i[1]}+
                             {2'b0,reserve_mask_i[2]}+{2'b0,reserve_mask_i[3]};
    assign reserve_ready_o=resetn && (&(capture_ready | ~reserve_mask_i)) &&
        ({1'b0,used_r}+request_count<=TOTAL_SLOTS);
    wire reserve=reserve_valid_i && reserve_ready_o;
    assign used_o=used_r;
    assign empty_o=used_r==0;
    assign retire_o=out_valid_o && out_ready_i && out_tile_last_o;
    assign error_o=accounting_error_r || |ce;
    // 每lane保留小型并行捕获，不能将同拍4个tile的2048位结果塞进单个128位写口。
    genvar t;
    generate for(t=0;t<4;t=t+1) begin:G_CAPTURE
        wire [127:0] d;
        wire [3:0] keep;
        wire [1:0] row;
        wire [47:0] meta;
        wire [15:0] m=meta[31:16]+TILE_ROW*4+row;
        wire [15:0] n=meta[15:0]+t*4;
        npu_v13_tile_collector_exp #(.P(4),.FAST_CAPTURE(1),.SLOTS(CAPTURE_SLOTS),.ADDR_W(2),.TAG_W(48)) u_capture(
            .clk(clk),.resetn(resetn),.reserve_valid_i(reserve && reserve_mask_i[t]),.reserve_ready_o(capture_ready[t]),
            .reserve_base_i(2'b0),.reserve_tag_i({reserve_tag_i,reserve_m_i,reserve_n_i}),
            .result_valid_i(result_valid_i[t]),.result_data_i(result_data_i[t*512+:512]),.result_shape_i(result_shape_i[t*4+:4]),
            .wr_valid_o(cv[t]),.wr_ready_i(cr[t]),.wr_addr_o(row),.wr_data_o(d),.wr_keep_o(keep),.wr_tag_o(meta),
            .retire_o(),.used_o(),.protocol_error_o(ce[t]));
        assign cp[t*PW+:PW]={row==3,meta[47:32],m,n,keep,d};
    end endgenerate
    wire mv,mr;
    wire [PW-1:0] md,od;
    // 轮询结果按字交织；下游必须使用坐标，而不是假定图像扫描顺序。
    merge4_exp #(.W(PW)) u_merge(.clk(clk),.resetn(resetn),.valid_i(cv),.ready_o(cr),.data_i(cp),
        .valid_o(mv),.ready_i(mr),.data_o(md));
    // 深度=4*总结果槽，足以容纳每个预约的四个P4字；输出级容量不额外透支。
    npu_v13_result_bram_fifo #(.WIDTH(PW),.DEPTH(4*TOTAL_SLOTS)) u_store(
        .clk(clk),.resetn(resetn),.in_valid_i(mv),.in_ready_o(mr),.in_data_i(md),
        .out_valid_o(out_valid_o),.out_ready_i(out_ready_i),.out_data_o(od),.used_o());
    assign {out_tile_last_o,out_tag_o,out_m_o,out_n_o,out_keep_o,out_data_o}=od;
    // 同拍多tile预约与一个tile退休合并计算；不在满时借用尚未登记的退休额度。
    always @(posedge clk) begin
        if(!resetn) begin used_r<=0;accounting_error_r<=0;end
        else begin
            used_r<=used_r+(reserve?request_count:3'b0)-retire_o;
            if((retire_o && used_r==0) || used_r>TOTAL_SLOTS) accounting_error_r<=1;
        end
    end
    // synthesis translate_off
    initial if(TOTAL_SLOTS<4 || CAPTURE_SLOTS<2 || TILE_ROW>3) $fatal(1,"island parameters");
    // synthesis translate_on
endmodule
