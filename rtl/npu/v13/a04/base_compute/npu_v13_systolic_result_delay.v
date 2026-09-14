// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_systolic_result_delay
//
// 功能：把一个 PE 的 post-MAC 结果延迟固定的 DELAY 拍，使它与最远 PE(3,3)
// 的结果在同一个输出周期汇合。本模块是连续流版的结果对齐链，不是 FIFO：
// 没有读写指针，也不能吸收下游反压，只会每拍把数据向后推进。
//
// 本模块只负责固定延迟，不解释 shape，也不把尾块的未激活 PE 清零。
// shape 随结果作为独立 sideband 输出，由 collector 只采纳有效行列。这样
// DELAY>1 的整条数据链没有 reset、使能或末级 mux，便于 Vivado 直接推断为
// SRL16E；DELAY=1 时则只保留无法再压缩的一拍寄存器。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_systolic_result_delay #(
    parameter integer ACC_W = 32,
    parameter integer DELAY = 0
) (
    // 固定速率移位链时钟。
    input  wire                    clk, // 固定延迟流水的推进时钟；没有 reset、使能或反压，每拍都移入新数据。
    // 待对齐的单个 PE 结果。
    input  wire signed [ACC_W-1:0] data_i, // 待对齐的有符号 PE 结果，每拍采样；有效性由外部独立 token 跟踪。
    // 对齐后的结果；顶层按 PE_INDEX 拼接为 c_matrix_o。
    output wire signed [ACC_W-1:0] data_o // data_i 延迟 DELAY 拍的值，DELAY=0 时直通；无内置 valid，启动未填满或对应 token 无效时不可使用。
);
    generate
        if (DELAY == 0) begin : g_no_delay
            // 零延迟纯连线；当前 stream tile 的 RESULT_DELAY 最小为 1。
            assign data_o = data_i;
        end else begin : g_delay
            // 所有级都是无 reset、无 enable 的同构移位。DELAY>1 可映射成
            // 每个结果 bit 一条 SRL；DELAY=1 自然映射为一个普通 FF。
            (* shreg_extract = "yes" *) reg signed [ACC_W-1:0] data_r [0:DELAY-1];
            integer i;

            always @(posedge clk) begin
                data_r[0] <= data_i;
                for (i = 1; i < DELAY; i = i + 1) begin
                    data_r[i] <= data_r[i-1];
                end
            end

            assign data_o = data_r[DELAY-1];
        end
    endgenerate
endmodule
