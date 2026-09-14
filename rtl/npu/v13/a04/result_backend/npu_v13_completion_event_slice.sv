// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p9完成事件切片：原始“有无事件”直接归约，popcount仅进入原有13bit寄存级。
// 禁止先popcount再判零后直达done；三类计数仍同拍延迟，守恒账本延迟不变。
module npu_v13_completion_event_slice(
    input wire clk, // 仅同域事件，不承担CDC。
    input wire resetn, // 同步取消尚未交给完成器的事件。
    input wire enable_i, // 父任务active且未done；start沿为0，旧事件不进入新任务。
    input wire reserve_valid_i, // 原始预约握手；mask非零但未握手不算预约。
    input wire [15:0] reserve_mask_i,capture_mask_i, // 物理tile事件位图，不能用shape替代返回valid。
    input wire [3:0] retire_mask_i, // 四组真实tile末字消费事件。
    output reg [4:0] reserve_count_o,capture_count_o, // 延迟一拍，单位仍是tile。
    output reg [2:0] retire_count_o, // 没有ready，不丢弃逐拍并发事件。
    output wire event_now_o // 原始本拍事件栅栏，故意不受enable/reset屏蔽。
);
    // 完成判定必须同时看原始事件和寄存事件。净变化为0也不能略过错误检查。
    assign event_now_o=(reserve_valid_i && (|reserve_mask_i)) || (|capture_mask_i) || (|retire_mask_i);
    function automatic [4:0] count16(input [15:0] x);
        integer j;begin count16=0;for(j=0;j<16;j=j+1)count16=count16+{4'b0,x[j]};end
    endfunction
    wire [2:0] retire_count={2'b0,retire_mask_i[0]}+{2'b0,retire_mask_i[1]}+
                            {2'b0,retire_mask_i[2]}+{2'b0,retire_mask_i[3]};
    always @(posedge clk) begin
        if(!resetn || !enable_i) begin
            reserve_count_o<=0;capture_count_o<=0;retire_count_o<=0;
        end else begin
            reserve_count_o<=reserve_valid_i ? count16(reserve_mask_i) : 5'd0;
            capture_count_o<=count16(capture_mask_i);retire_count_o<=retire_count;
        end
    end
endmodule
