// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 局部P4跨K累加：同步BRAM读 -> 四路32bit加法 -> RAM提交/最终输出。
// 只认识word地址；GEMM/CONV坐标映射、chunk顺序、panel所有权由上层负责。
// 关键契约：非first只能读取本panel已经first初始化的lane；RAM本身不复位。
// INT32运算按模2^32回绕，不能在中间Kchunk做饱和、量化、bias或ReLU。
module npu_v13_psum_predecode_reference #(
    parameter integer DEPTH=1024, // 本island的128bit word容量，可为非2次幂。
    parameter integer ADDR_W=(DEPTH<=2 ? 1 : $clog2(DEPTH)),
    parameter integer META_W=48 // 上层opaque标签，例如{父任务tag,行,首列}。
)(
    input wire clk, // 单计算时钟域；本模块不是CDC。
    input wire resetn, // 已同步复位，低电平至少跨一个上升沿；取消全部在途事务。
    input wire in_valid_i, // 输入有效；valid&&!ready期间所有输入字段须保持。
    output wire in_ready_o, // 本地流水可前进；不保证下游永久反压时仍接收。
    input wire [ADDR_W-1:0] in_addr_i, // 本PSUM bank的word地址，不是DDR字节地址。
    input wire [127:0] in_data_i, // 低lane在低32bit，四个有符号INT32部分和。
    input wire [3:0] in_keep_i, // 每lane独立写使能；0位既不修改RAM也不产生有效结果。
    input wire in_first_i, // 本beat有效lane覆盖旧值；不能只对整个命令首beat置1。
    input wire in_final_i, // 本beat是其输出位置的最终Kchunk，才送下游后处理。
    input wire [META_W-1:0] in_meta_i, // 随数据逐级寄存，不自行解释其中字段。
    output wire out_valid_o, // 最终累加结果有效；中间chunk及全零keep不输出。
    input wire out_ready_i, // 消费者反压；输出数据、地址、keep和meta同时保持。
    output wire [127:0] out_data_o, // final的四个INT32，keep=0的lane固定输出0。
    output wire [3:0] out_keep_o, // 对应final输入keep。
    output wire [ADDR_W-1:0] out_addr_o, // 对应PSUM word地址；便于后续mapper/store。
    output wire [META_W-1:0] out_meta_o, // 原样传递final输入meta。
    output wire commit_valid_o, // 本拍上升沿退休一个输入；有效lane此沿写入RAM。
    output wire commit_error_o, // commit伴随的地址越界错误；错误请求不读写RAM。
    output wire commit_final_o, // 被退休输入的final属性，不代表下游已接受final结果。
    output wire [3:0] commit_keep_o, // 被退休请求原keep，包括全0；计数不能只数有数据的beat。
    output wire [ADDR_W-1:0] commit_addr_o, // 被退休请求原地址，错误时也不截断伪装合法。
    output wire [META_W-1:0] commit_meta_o, // 退休的事务身份，供完成栅栏逐项记账。
    output wire idle_o, // 读级、计算级和待消费final输出均空；RAM旧内容不算在途。
    output wire error_o // 地址错误黏滞到reset；上层须使本父任务以错误完成。
);
    // r0与BRAM读寄存器对齐，r1为加法结果，wb为最近一次真实提交记录。
    // wb即便是非final也保留，用于解决BRAM同沿读写碰撞；不占最终输出带宽。
    reg r0_valid,r1_valid,wb_valid;
    reg r0_first,r0_final,r1_final,wb_final;
    reg r0_bad,r1_bad,wb_bad,error_r;
    reg [ADDR_W-1:0] r0_addr,r1_addr,wb_addr;
    reg [3:0] r0_keep,r1_keep,wb_keep;
    reg [META_W-1:0] r0_meta,r1_meta,wb_meta;
    reg [127:0] r0_data;
    wire advance=!out_valid_o || out_ready_i;
    wire accept=in_valid_i && in_ready_o;
    wire address_bad=(in_addr_i>=DEPTH);
    assign in_ready_o=resetn && advance;
    assign out_valid_o=resetn && wb_valid && wb_final && !wb_bad && (|wb_keep);
    assign out_keep_o=wb_keep;
    assign out_addr_o=wb_addr;
    assign out_meta_o=wb_meta;
    assign commit_valid_o=resetn && advance && r1_valid;
    assign commit_error_o=r1_bad;
    assign commit_final_o=r1_final;
    assign commit_keep_o=r1_keep;
    assign commit_addr_o=r1_addr;
    assign commit_meta_o=r1_meta;
    assign idle_o=resetn && !r0_valid && !r1_valid && !out_valid_o;
    assign error_o=error_r;

    // 四个独立32bit RAM lane共享地址。这样keep是RAM写使能，空lane无需读改写整字。
    // BRAM和数据寄存器不带reset；只有valid清零，防止复位让整片RAM退化为FF阵列。
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin:G_LANE
        (* ram_style="block" *) reg [31:0] mem [0:DEPTH-1];
        reg [31:0] ram_q,sum_r,wb_data_r;
        // r1比wb更新，且必须逐lane看keep。不能因word地址匹配就旁路整128bit：
        // 较新事务可能仅写lane0，lane1仍应从wb或者RAM取值。
        wire hit_r1=r1_valid && !r1_bad && r1_addr==r0_addr && r1_keep[lane];
        wire hit_wb=wb_valid && !wb_bad && wb_addr==r0_addr && wb_keep[lane];
        wire [31:0] prior=hit_r1 ? sum_r : (hit_wb ? wb_data_r : ram_q);
        wire [31:0] base=r0_first ? 32'b0 : prior;
        assign out_data_o[lane*32+:32]=wb_keep[lane] ? wb_data_r : 32'b0;

        // 同步简单双口RAM模板：读/写可在同一沿发生。
        // 即使硬件碰撞时ram_q未知，后级wb逐lane旁路也会覆盖这个旧读值。
        always @(posedge clk) begin
            if(accept && !address_bad && !in_first_i && in_keep_i[lane])
                ram_q<=mem[in_addr_i];
            if(commit_valid_o && !r1_bad && r1_keep[lane])
                mem[r1_addr]<=sum_r;
        end
        // 全流水共用advance：堵在final输出时，读响应及两个旁路历史一起冻结。
        // 加法只取32bit，明确回绕；无效lane输出0而不引用未初始化RAM。
        always @(posedge clk) if(advance) begin
            if(r0_valid)
                sum_r<=(!r0_bad && r0_keep[lane]) ? (base+r0_data[lane*32+:32]) : 32'b0;
            if(r1_valid) wb_data_r<=sum_r;
        end
    end endgenerate

    // valid需要同步reset；宽数据/地址/meta不reset，由相应valid保护其可见性。
    // wb_valid不能简单等于out_valid，因为非final的最近写入仍是RAW旁路所需状态。
    always @(posedge clk) begin
        if(!resetn) begin
            r0_valid<=0;r1_valid<=0;wb_valid<=0;error_r<=0;
        end else begin
            if(accept && address_bad) error_r<=1;
            if(advance) begin
                r0_valid<=accept;
                if(accept) begin
                    r0_addr<=in_addr_i;r0_data<=in_data_i;r0_keep<=in_keep_i;
                    r0_first<=in_first_i;r0_final<=in_final_i;
                    r0_meta<=in_meta_i;r0_bad<=address_bad;
                end
                r1_valid<=r0_valid;
                if(r0_valid) begin
                    r1_addr<=r0_addr;r1_keep<=r0_keep;r1_final<=r0_final;
                    r1_meta<=r0_meta;r1_bad<=r0_bad;
                end
                wb_valid<=r1_valid;
                if(r1_valid) begin
                    wb_addr<=r1_addr;wb_keep<=r1_keep;wb_final<=r1_final;
                    wb_meta<=r1_meta;wb_bad<=r1_bad;
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(DEPTH<2 || ADDR_W<$clog2(DEPTH) || ADDR_W>30 || META_W<1)
            $fatal(1,"PSUM illegal static parameters");
    end
    // synthesis translate_on
endmodule
