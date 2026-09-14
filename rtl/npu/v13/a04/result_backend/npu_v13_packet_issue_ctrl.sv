// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 单描述符暂存：EMPTY -> RESERVE -> COMMIT -> SEND。四组同拍原子预约。
// reserve与send解耦：先拿到结果空间，再允许产生任何A/B读请求。
// COMMIT隔开跨组容量判断与计数更新；描述符最小间隔4拍，不能声称短K的II=1。
// 唯一预约者契约：RESERVE到COMMIT期间mask稳定，其他模块不能消耗这些槽。
// 因此已通过的ready只能保持/因退休而增加，不能撤销；违约必须协调复位。
module npu_v13_packet_issue_ctrl #(parameter integer AW=12,MAX_K=65535)(
    input wire clk, // 计算时钟。
    input wire resetn, // 协调复位取消已暂存描述符及预约，不能独立热复位。
    input wire desc_valid_i, // scheduler分块描述符有效。
    output wire desc_ready_o, // 仅本地暂存为空；不形成下游ready到scheduler的长组合链。
    input wire [AW-1:0] desc_a_i,desc_b_i, // A/B缓存内word起址，不是DDR字节地址。
    input wire [15:0] desc_k_i, // 当前packet实际K，必须大于零。
    input wire [4:0] desc_rows_i,desc_cols_i, // 动态实际shape，合法范围1..16。
    input wire [15:0] desc_m_i,desc_n_i,desc_tag_i, // 输出块坐标和命令标识。
    input wire buffers_owned_i, // 上层保证A/B缓存已装载且当前任务持有。
    output wire reserve_valid_o, // 上拍四组均ready后，本拍发出不可撤销的原子 COMMIT。
    input wire [3:0] reserve_ready_i, // 四组针对稳定mask/元数据的容量判断。
    output wire [15:0] reserve_mask_o, // 每tile一位，低四位属于island0。
    output wire [15:0] reserve_m_o,reserve_n_o,reserve_tag_o, // 预约元数据。
    output wire packet_valid_o, // 已完成预约，允许feeder接收。
    input wire packet_ready_i, // feeder可以接受下一个packet。
    output wire [AW-1:0] packet_a_o,packet_b_o, // 在SEND等待期间保持。
    output wire [15:0] packet_k_o, // feeder需要发送的有效K拍数。
    output wire [4:0] packet_rows_o,packet_cols_o, // 随packet保持的动态shape。
    output wire idle_o, // 没有已接收尚未交付的描述符。
    output reg error_o // 非法shape/K；集成prepare应在启动前拒绝非法命令。
);
    localparam EMPTY=0,RESERVE=1,COMMIT=2,SEND=3;
    reg [1:0] state_r;
    reg [AW-1:0] a_r,b_r;
    reg [15:0] k_r,m_r,n_r,tag_r,mask_r;
    reg [4:0] rows_r,cols_r;
    assign desc_ready_o=resetn && state_r==EMPTY;
    assign reserve_valid_o=resetn && state_r==COMMIT;
    assign reserve_mask_o=mask_r;
    assign reserve_m_o=m_r;assign reserve_n_o=n_r;assign reserve_tag_o=tag_r;
    assign packet_valid_o=resetn && state_r==SEND && buffers_owned_i;
    assign packet_a_o=a_r;assign packet_b_o=b_r;assign packet_k_o=k_r;
    assign packet_rows_o=rows_r;assign packet_cols_o=cols_r;
    assign idle_o=state_r==EMPTY;
    integer t;
    always @(posedge clk) begin
        if(!resetn) begin state_r<=EMPTY;error_o<=0;end
        else begin
            if(desc_valid_i && desc_ready_o) begin
                // p19：载荷只按真实desc握手采样，不把shape/K合法性串入宽载荷CE/R。
                // 非法描述符可以覆盖EMPTY状态下不可解释的载荷，但绝不离开EMPTY/产生预约/访存。
                // 合法性只控制state/error；RESERVE->COMMIT->SEND及每个有效事件的周期保持不变。
                a_r<=desc_a_i;b_r<=desc_b_i;k_r<=desc_k_i;
                rows_r<=desc_rows_i;cols_r<=desc_cols_i;m_r<=desc_m_i;n_r<=desc_n_i;tag_r<=desc_tag_i;
                for(t=0;t<16;t=t+1) mask_r[t]<=desc_rows_i>(t/4)*4 && desc_cols_i>(t%4)*4;
                if(desc_k_i==0 || desc_k_i>MAX_K || desc_rows_i==0 || desc_rows_i>16 || desc_cols_i==0 || desc_cols_i>16)
                    error_o<=1;
                else state_r<=RESERVE;
            end
            // grant 在此寄存；COMMIT 数据面不再依赖本拍 ready 的重新组合判定。
            if(state_r==RESERVE && buffers_owned_i && (&reserve_ready_i)) state_r<=COMMIT;
            if(reserve_valid_o) begin
                state_r<=SEND;
                if(!buffers_owned_i || !(&reserve_ready_i)) error_o<=1;
            end
            if(packet_valid_o && packet_ready_i) state_r<=EMPTY;
        end
    end
    // synthesis translate_off
    always @(posedge clk) if(resetn && reserve_valid_o && (!buffers_owned_i || !(&reserve_ready_i)))
        $fatal(1,"reservation grant withdrawn: requires sole producer and stable bank ownership");
    // synthesis translate_on
endmodule
