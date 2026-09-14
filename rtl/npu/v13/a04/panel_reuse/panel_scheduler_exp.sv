// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 宏块二维遍历器：m 外层、n 内层；A 子块横向重放，B 子块纵向重放。
// 只产生 packet 描述符，不读取 BRAM、不做计算、不代替命令 FIFO。
module panel_scheduler_exp #(
    parameter integer G=16,S=1,MAX_K=512,MAX_MN=128,AW=12,
    parameter integer MW=$clog2(MAX_MN+1),KW=$clog2(MAX_K/S+1)
)(
    input wire clk, // 时钟。
    input wire resetn, // 丢弃未发出的描述符。
    input wire start_i, // 上层已获取 bank 租约的单拍启动。
    input wire [15:0] m_i,n_i,k_i, // 动态宏块尺寸，均为实际数量。
    output wire packet_valid_o, // 下一个输出子块描述符有效，停顿时保持。
    input wire packet_ready_i, // feeder 空闲且完整 C 槽已可预约。
    output wire [15:0] m_base_o,n_base_o, // 子块左上角在宏块内的元素坐标。
    output wire [4:0] rows_o,cols_o, // 此子块实际有效行列 1..G。
    output wire [15:0] steps_o, // 本子块需要 ceil(K/S) 个输入 beat。
    output wire [2:0] last_lanes_o, // 最后一拍有效 SIMD lane 数 1..S。
    output wire [AW-1:0] a_base_o,b_base_o, // 固定 MAX_K pitch 的 panel word 起址。
    output wire issued_all_o // 所有描述符已发出，不等于结果已写回。
);
    reg active_r;
    reg [MW-1:0] mr_r,nr_r,n_r,mp_r,np_r;
    reg [4:0] rows_r,cols_r;
    reg [KW-1:0] steps_r;
    reg [2:0] lanes_r;
    assign packet_valid_o=active_r;
    assign issued_all_o=!active_r;
    assign m_base_o=mp_r;assign n_base_o=np_r;
    // 描述符字段是寄存器，不在 ready/全局 C 预约路径上现场进行尺寸减法。
    assign rows_o=rows_r;
    assign cols_o=cols_r;
    assign steps_o=steps_r;
    assign last_lanes_o=lanes_r;
    assign a_base_o=(mp_r/G)*(MAX_K/S);
    assign b_base_o=(np_r/G)*(MAX_K/S);
    always @(posedge clk) begin
        if(!resetn) begin active_r<=0;mp_r<=0;np_r<=0;mr_r<=0;nr_r<=0;n_r<=0;
            rows_r<=1;cols_r<=1;steps_r<=1;lanes_r<=S;end
        else if(start_i) begin
            active_r<=1;mr_r<=m_i[MW-1:0];nr_r<=n_i[MW-1:0];n_r<=n_i[MW-1:0];mp_r<=0;np_r<=0;
            rows_r<=m_i>=G?G:m_i;cols_r<=n_i>=G?G:n_i;
            steps_r<=(k_i+S-1)/S;lanes_r<=((k_i-1)%S)+1;
        end
        else if(packet_valid_o && packet_ready_i) begin
            if(nr_r>G) begin np_r<=np_r+G;nr_r<=nr_r-G;cols_r<=nr_r>=2*G?G:nr_r-G;end
            else begin np_r<=0;nr_r<=n_r;cols_r<=n_r>=G?G:n_r;
                if(mr_r>G) begin mp_r<=mp_r+G;mr_r<=mr_r-G;rows_r<=mr_r>=2*G?G:mr_r-G;end
                else active_r<=0;
            end
        end
    end
endmodule
