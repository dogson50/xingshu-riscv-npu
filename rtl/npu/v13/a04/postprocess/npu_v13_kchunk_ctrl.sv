// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 一个resident输出panel的K分块控制器；不读取RAM、不做M/N tile遍历，也不做PSUM加法。
// 上游给父任务和已装载的chunk描述符；本模块生成first/final，独占下游命令入口。
// 每个chunk仍由正式FIFO/executor/manager调度、取得A/B租约和处理M/N。
// K总长为32bit，单chunk为16bit且不大于片上MAX_K；不是将动态K静态裁小。
module npu_v13_kchunk_ctrl #(
    parameter integer MAX_M=128,MAX_N=128,MAX_K=512
)(
    input wire clk, // 与命令后端及PSUM同域。
    input wire resetn, // 同步取消父任务/当前chunk，须同时复位后端和PSUM。
    input wire job_valid_i, // 新父任务有效，ready前保持全部job字段。
    output wire job_ready_o, // 没有父任务或尚未消费的完成响应。
    input wire [15:0] job_m_i,job_n_i,job_tag_i, // 当前输出panel尺寸/父tag，均保持动态。
    input wire [31:0] job_k_i, // 完整K长度，必须大于0；可大于MAX_K和65535。
    input wire chunk_valid_i, // 按K顺序提交一段A/B panel描述符，必须从k_done_o处开始。
    output wire chunk_ready_o, // 前一chunk后端响应及PSUM栅栏均完成，才能接下一段。
    input wire [15:0] chunk_k_i, // 本段真实K长度；0、超容量或超过剩余K会终止父任务并报错。
    input wire chunk_a_bank_i,chunk_b_bank_i,chunk_c_bank_i, // 交给正式manager的0/1租约编号。
    input wire [31:0] chunk_a_base_i,chunk_b_base_i, // 本段A/B在各自BRAM bank的word地址。
    output wire ctx_valid_o, // 先向PSUM装入稳定上下文，再允许backend接受命令。
    input wire ctx_ready_i, // PSUM没有旧上下文/在途写入。
    output wire [15:0] ctx_m_o,ctx_n_o,ctx_tag_o, // 同父任务的动态panel身份。
    output wire ctx_first_o,ctx_final_o, // 自动由已完成K和当前chunk长度推导。
    output wire cmd_valid_o, // 发往现有command_backend的命令入口，不旁路其FIFO。
    input wire cmd_ready_i, // 正式命令FIFO可接受。
    output wire [15:0] cmd_m_o,cmd_n_o,cmd_k_o,cmd_tag_o, // 下游执行本段K、整个M/N panel。
    output wire cmd_a_bank_o,cmd_b_bank_o,cmd_c_bank_o, // 当前chunk租约，等待期间保持。
    output wire [31:0] cmd_a_base_o,cmd_b_base_o, // 不解释DMA字节地址，单位仍为BRAM word。
    input wire rsp_valid_i, // 正式后端的chunk退休响应，尚不代表父任务完成。
    output wire rsp_ready_o, // 仅有一个已提交chunk时接受响应，防止错配。
    input wire [15:0] rsp_tag_i, // 必须与父tag匹配；当前实现按chunk严格串行。
    input wire [2:0] rsp_status_i, // 后端0成功，其他值作为本父任务执行失败。
    output wire end_valid_o, // 后端响应后关闭PSUM本chunk输入。
    input wire end_ready_i, // PSUM接受关闭标记。
    input wire fence_valid_i, // PSUM写入与final输出已排空。
    output wire fence_ready_o, // 确认该栅栏，之后才可推进K或完成父任务。
    input wire fence_error_i, // PSUM映射/写入错误。
    output wire done_valid_o, // 父任务响应；成功时所有K及PSUM最终传输已经完成。
    input wire done_ready_i, // 响应反压；tag/status/k_done保持，不能提前接新父任务。
    output wire [15:0] done_tag_o, // 对应job_tag；非法父参数也恰好响应一次。
    output wire [2:0] done_status_o, // 0成功/1父参数非法/2chunk非法/3backend或tag错误/4PSUM错误。
    output wire [31:0] k_done_o, // 已通过PSUM栅栏的K长度；不是已装载或刚发给核的K。
    output wire busy_o // 从父任务接受直到完成响应握手。
);
    localparam [3:0] IDLE=0,CHUNK=1,CONTEXT=2,COMMAND=3,RESPONSE=4,CLOSE=5,FENCE=6,DONE=7;
    reg [3:0] state_r;
    reg [15:0] m_r,n_r,tag_r,k_r;
    reg [31:0] total_r,remaining_r,done_k_r,a_r,b_r;
    reg ab_r,bb_r,cb_r,last_r;
    reg [2:0] status_r;
    assign job_ready_o=resetn && state_r==IDLE;
    assign chunk_ready_o=resetn && state_r==CHUNK;
    assign ctx_valid_o=resetn && state_r==CONTEXT;
    assign ctx_m_o=m_r;assign ctx_n_o=n_r;assign ctx_tag_o=tag_r;
    assign ctx_first_o=(remaining_r==total_r);assign ctx_final_o=last_r;
    assign cmd_valid_o=resetn && state_r==COMMAND;
    assign cmd_m_o=m_r;assign cmd_n_o=n_r;assign cmd_k_o=k_r;assign cmd_tag_o=tag_r;
    assign cmd_a_bank_o=ab_r;assign cmd_b_bank_o=bb_r;assign cmd_c_bank_o=cb_r;
    assign cmd_a_base_o=a_r;assign cmd_b_base_o=b_r;
    assign rsp_ready_o=resetn && state_r==RESPONSE;
    assign end_valid_o=resetn && state_r==CLOSE;
    assign fence_ready_o=resetn && state_r==FENCE;
    assign done_valid_o=resetn && state_r==DONE;
    assign done_tag_o=tag_r;assign done_status_o=status_r;assign k_done_o=done_k_r;
    assign busy_o=state_r!=IDLE;
    // data不reset；状态机有效性保护所有输出。状态/错误/完成计数需要同步复位。
    always @(posedge clk) begin
        if(!resetn) begin state_r<=IDLE;status_r<=0;done_k_r<=0;end
        else case(state_r)
            IDLE: if(job_valid_i && job_ready_o) begin
                m_r<=job_m_i;n_r<=job_n_i;tag_r<=job_tag_i;
                total_r<=job_k_i;remaining_r<=job_k_i;done_k_r<=0;status_r<=0;
                if(job_m_i==0 || job_n_i==0 || job_k_i==0 || job_m_i>MAX_M || job_n_i>MAX_N) begin
                    status_r<=1;state_r<=DONE;
                end else state_r<=CHUNK;
            end
            CHUNK: if(chunk_valid_i && chunk_ready_o) begin
                if(chunk_k_i==0 || chunk_k_i>MAX_K || {16'b0,chunk_k_i}>remaining_r) begin
                    status_r<=2;state_r<=DONE;
                end else begin
                    k_r<=chunk_k_i;a_r<=chunk_a_base_i;b_r<=chunk_b_base_i;
                    ab_r<=chunk_a_bank_i;bb_r<=chunk_b_bank_i;cb_r<=chunk_c_bank_i;
                    last_r<=({16'b0,chunk_k_i}==remaining_r);state_r<=CONTEXT;
                end
            end
            CONTEXT: if(ctx_valid_o && ctx_ready_i) state_r<=COMMAND;
            COMMAND: if(cmd_valid_o && cmd_ready_i) state_r<=RESPONSE;
            RESPONSE: if(rsp_valid_i && rsp_ready_o) begin
                if(rsp_status_i!=0 || rsp_tag_i!=tag_r) status_r<=3;
                state_r<=CLOSE;
            end
            CLOSE: if(end_valid_o && end_ready_i) state_r<=FENCE;
            FENCE: if(fence_valid_i && fence_ready_o) begin
                if(fence_error_i || status_r!=0) begin
                    if(status_r==0) status_r<=4;
                    state_r<=DONE;
                end else begin
                    // 只有实际PSUM栅栏允许更新进度；装载、发命令、TLAST都不是这个事件。
                    remaining_r<=remaining_r-{16'b0,k_r};
                    done_k_r<=done_k_r+{16'b0,k_r};
                    state_r<=last_r ? DONE : CHUNK;
                end
            end
            DONE: if(done_valid_o && done_ready_i) state_r<=IDLE;
            default: begin state_r<=DONE;status_r<=3;end
        endcase
    end
    // synthesis translate_off
    initial if(MAX_M<16 || MAX_N<16 || MAX_M>65520 || MAX_N>65520 || MAX_K<1 || MAX_K>65535)
        $fatal(1,"Kchunk static limits");
    // synthesis translate_on
endmodule
