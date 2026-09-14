// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 存储外壳：保留式manager + 四份独立A0/A1/B0/B1同步BRAM。
// manager只管理所有权；本壳把状态落实到RAM读写使能，防止软件误写正在使用的bank。
// C是下游流式目的地的租约，不在这里混入A/B RAM；真正C容量由四个result_island预约。
module npu_v13_managed_panel_store #(
    parameter integer LOAD_W=128,
    parameter integer MAX_MN=128,MAX_K=512,
    parameter integer DEPTH=(MAX_MN/16)*MAX_K,AW=$clog2(DEPTH)
)(
    input wire clk,resetn, // 与executor、feeder同域并协调复位，RAM内容不清零。
    input wire load_begin_valid_i, // 申请装载一个FREE输入bank。
    output wire load_begin_ready_o,load_begin_error_o, // 握手且error=0才获得写权限。
    input wire load_begin_operand_i,load_begin_bank_i, // operand0=A/1=B，各有bank0/1。
    input wire load_valid_i, // LOAD_W位搬运beat；64位在目标bank本地拼成128位。
    output wire load_ready_o, // 只有目标处于LOADING且地址在DEPTH内才接受。
    input wire load_operand_i,load_bank_i, // 写目标；可与当前计算所用bank不同。
    input wire [AW+(LOAD_W==64)-1:0] load_addr_i, // LOAD_W-bit panel beat地址，不是DDR字节地址。
    input wire [LOAD_W-1:0] load_data_i, // 窄载荷保持到bank叶节点；计算读口仍128位。
    input wire load_finish_valid_i, // 最后一笔写已发送后发布或放弃此次装载。
    output wire load_finish_ready_o,load_finish_error_o, // 等待所有已接受的写真实落入RAM。
    input wire load_finish_operand_i,load_finish_bank_i,load_finish_error_i, // 结束目标及主动放弃标记。
    input wire discard_valid_i, // 重装前显式丢弃旧READY数据；不能丢弃IN_USE。
    output wire discard_ready_o,discard_error_o, // 非法discard消费并报错，不改变原状态。
    input wire discard_operand_i,discard_bank_i, // 选择要丢弃的独立A/B bank。
    input wire acquire_valid_i, // executor对稳定req_*原子申请A/B/C租约。
    output wire acquire_ready_o,acquire_error_o, // 资源齐全且无错误才同时获得三者。
    input wire release_valid_i,release_error_i, // 完整结果已消费后归还；error=1标记任务失败。
    output wire release_ready_o, // 身份匹配才能释放，不能仅按bank空闲猜测。
    input wire req_a_bank_i,req_b_bank_i,req_c_bank_i, // executor锁存上下文的bank编号。
    input wire [15:0] req_tag_i, // 租约身份，与ctx保持相同生命周期。
    input wire rd_valid_i, // 已预约packet的feeder请求，拥有A/B时才实际进入RAM。
    input wire [AW-1:0] rd_a_addr_i,rd_b_addr_i, // 当前子块的A/B word地址。
    output wire ram_valid_o, // 请求延迟两拍，不能被下游反压丢弃。
    output wire [127:0] ram_a_o,ram_b_o, // 对齐的A/B固定延迟响应。
    output wire [3:0] retained_o,loading_o,in_use_o, // 位序{B1,B0,A1,A0}，只作状态观察。
    output wire [1:0] c_free_o,c_in_use_o, // 两个独立C目的地租约状态，不代表C容量。
    output wire lease_active_o, // 当前存在未归还的原子租约。
    output wire error_o // manager协议错误或非法实际读取，必须协调复位。
);
    wire [1:0] ar,al,au,br,bl,bu;
    wire manager_error,pending_writes,finish_ready;
    reg read_error_r;
    wire load_state=load_operand_i?bl[load_bank_i]:al[load_bank_i];
    assign load_ready_o=resetn && load_state && load_addr_i<DEPTH*(128/LOAD_W);
    wire wr=load_valid_i && load_ready_o;
    // panel_ram.pending包含当前拍wr以及本地写流水，finish不能越过最后一笔写。
    assign load_finish_ready_o=finish_ready && !pending_writes;
    wire read_permitted=lease_active_o && au[req_a_bank_i] && bu[req_b_bank_i] &&
        rd_a_addr_i<DEPTH && rd_b_addr_i<DEPTH;
    assign retained_o={br,ar};assign loading_o={bl,al};assign in_use_o={bu,au};
    assign error_o=manager_error || read_error_r;
    always @(posedge clk) begin
        if(!resetn) read_error_r<=0;
        else if(rd_valid_i && !read_permitted) read_error_r<=1;
    end
    npu_v13_retained_buffer_manager #(.AB_BANKS(2),.C_BANKS(2),.BANK_W(1),.TAG_W(16),
        .RETAIN_INPUTS(1),.C_STREAM_CONSUMED(1)) u_manager(
        .clk(clk),.resetn(resetn),.load_begin_valid_i(load_begin_valid_i),.load_begin_ready_o(load_begin_ready_o),
        .load_begin_operand_i(load_begin_operand_i),.load_begin_bank_i(load_begin_bank_i),.load_begin_error_o(load_begin_error_o),
        .load_finish_valid_i(load_finish_valid_i && !pending_writes),.load_finish_ready_o(finish_ready),
        .load_finish_operand_i(load_finish_operand_i),.load_finish_bank_i(load_finish_bank_i),
        .load_finish_error_i(load_finish_error_i),.load_finish_error_o(load_finish_error_o),
        .input_discard_valid_i(discard_valid_i),.input_discard_ready_o(discard_ready_o),
        .input_discard_operand_i(discard_operand_i),.input_discard_bank_i(discard_bank_i),.input_discard_error_o(discard_error_o),
        .req_a_bank_i(req_a_bank_i),.req_b_bank_i(req_b_bank_i),.req_c_bank_i(req_c_bank_i),.req_tag_i(req_tag_i),
        .buffer_acquire_valid_i(acquire_valid_i),.buffer_acquire_ready_o(acquire_ready_o),.buffer_acquire_error_o(acquire_error_o),
        .buffer_release_valid_i(release_valid_i),.buffer_release_ready_o(release_ready_o),.buffer_release_error_i(release_error_i),
        .c_take_valid_i(1'b0),.c_take_ready_o(),.c_take_bank_i(1'b0),.c_take_error_o(),.c_take_tag_o(),
        .c_return_valid_i(1'b0),.c_return_ready_o(),.c_return_bank_i(1'b0),.c_return_error_o(),
        .a_free_o(),.a_loading_o(al),.a_ready_o(ar),.a_in_use_o(au),
        .b_free_o(),.b_loading_o(bl),.b_ready_o(br),.b_in_use_o(bu),
        .c_free_o(c_free_o),.c_in_use_o(c_in_use_o),.c_ready_o(),.c_draining_o(),
        .lease_active_o(lease_active_o),.protocol_error_o(manager_error));
    npu_v13_panel_ram_local #(.LOAD_W(LOAD_W),.MAX_MN(MAX_MN),.MAX_K(MAX_K),.DEPTH(DEPTH),.AW(AW)) u_ram(
        .clk(clk),.resetn(resetn),.wr_valid_i(wr),.wr_operand_i(load_operand_i),.wr_bank_i(load_bank_i),
        .wr_addr_i(load_addr_i),.wr_data_i(load_data_i),.writes_pending_o(pending_writes),
        .rd_valid_i(rd_valid_i && read_permitted),.rd_a_bank_i(req_a_bank_i),.rd_b_bank_i(req_b_bank_i),
        .rd_a_addr_i(rd_a_addr_i),.rd_b_addr_i(rd_b_addr_i),.rd_valid_o(ram_valid_o),.rd_a_o(ram_a_o),.rd_b_o(ram_b_o));
    // synthesis translate_off
    always @(posedge clk) if(resetn && rd_valid_i && !read_permitted) $fatal(1,"unowned/out-of-range panel read");
    // synthesis translate_on
endmodule
