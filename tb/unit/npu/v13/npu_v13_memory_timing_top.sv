// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 仅时序测试夹具：给所有数据/握手端口提供真实发射与捕获寄存器。
// 夹具额外延迟不属于生产模块。异步 reset 直接传入，其他内部路径全部单周期。
module npu_v13_bram_bank_timing_top #(
    parameter integer DATA_W=32,
    parameter integer DEPTH=1024,
    parameter integer ADDR_W=(DEPTH>1 ? $clog2(DEPTH) : 1),
    parameter integer TAG_W=8,
    parameter integer READ_LATENCY=2
) (
    input wire  clk,
    input wire  resetn,
    input wire  wr_valid_i,
    output reg  wr_ready_o,
    input wire [ADDR_W-1:0] wr_addr_i,
    input wire [DATA_W-1:0] wr_data_i,
    output reg  wr_error_o,
    input wire  rd_valid_i,
    output reg  rd_ready_o,
    input wire [ADDR_W-1:0] rd_addr_i,
    input wire [TAG_W-1:0] rd_tag_i,
    output reg  rd_rsp_valid_o,
    output reg [DATA_W-1:0] rd_rsp_data_o,
    output reg [TAG_W-1:0] rd_rsp_tag_o,
    output reg  rd_rsp_error_o
);
    reg  wr_valid_i_boundary_r;
    reg [ADDR_W-1:0] wr_addr_i_boundary_r;
    reg [DATA_W-1:0] wr_data_i_boundary_r;
    reg  rd_valid_i_boundary_r;
    reg [ADDR_W-1:0] rd_addr_i_boundary_r;
    reg [TAG_W-1:0] rd_tag_i_boundary_r;
    wire  wr_ready_o_boundary_w;
    wire  wr_error_o_boundary_w;
    wire  rd_ready_o_boundary_w;
    wire  rd_rsp_valid_o_boundary_w;
    wire [DATA_W-1:0] rd_rsp_data_o_boundary_w;
    wire [TAG_W-1:0] rd_rsp_tag_o_boundary_w;
    wire  rd_rsp_error_o_boundary_w;
    always @(posedge clk)begin
        wr_valid_i_boundary_r<=wr_valid_i;
        wr_addr_i_boundary_r<=wr_addr_i;
        wr_data_i_boundary_r<=wr_data_i;
        rd_valid_i_boundary_r<=rd_valid_i;
        rd_addr_i_boundary_r<=rd_addr_i;
        rd_tag_i_boundary_r<=rd_tag_i;
        wr_ready_o<=wr_ready_o_boundary_w;
        wr_error_o<=wr_error_o_boundary_w;
        rd_ready_o<=rd_ready_o_boundary_w;
        rd_rsp_valid_o<=rd_rsp_valid_o_boundary_w;
        rd_rsp_data_o<=rd_rsp_data_o_boundary_w;
        rd_rsp_tag_o<=rd_rsp_tag_o_boundary_w;
        rd_rsp_error_o<=rd_rsp_error_o_boundary_w;
    end
    (* keep_hierarchy="yes" *) npu_v13_bram_bank #(.DATA_W(DATA_W),.DEPTH(DEPTH),.ADDR_W(ADDR_W),.TAG_W(TAG_W),.READ_LATENCY(READ_LATENCY)) u_dut (
        .clk(clk),
        .resetn(resetn),
        .wr_valid_i(wr_valid_i_boundary_r),
        .wr_ready_o(wr_ready_o_boundary_w),
        .wr_addr_i(wr_addr_i_boundary_r),
        .wr_data_i(wr_data_i_boundary_r),
        .wr_error_o(wr_error_o_boundary_w),
        .rd_valid_i(rd_valid_i_boundary_r),
        .rd_ready_o(rd_ready_o_boundary_w),
        .rd_addr_i(rd_addr_i_boundary_r),
        .rd_tag_i(rd_tag_i_boundary_r),
        .rd_rsp_valid_o(rd_rsp_valid_o_boundary_w),
        .rd_rsp_data_o(rd_rsp_data_o_boundary_w),
        .rd_rsp_tag_o(rd_rsp_tag_o_boundary_w),
        .rd_rsp_error_o(rd_rsp_error_o_boundary_w)
    );
endmodule

// 仅时序测试夹具：给所有数据/握手端口提供真实发射与捕获寄存器。
// 夹具额外延迟不属于生产模块。异步 reset 直接传入，其他内部路径全部单周期。
module npu_v13_buffer_manager_timing_top #(
    parameter integer AB_BANKS=2,
    parameter integer C_BANKS=1,
    parameter integer BANK_W=1,
    parameter integer TAG_W=8
) (
    input wire  clk,
    input wire  resetn,
    input wire  load_begin_valid_i,
    output reg  load_begin_ready_o,
    input wire  load_begin_operand_i,
    input wire [BANK_W-1:0] load_begin_bank_i,
    output reg  load_begin_error_o,
    input wire  load_finish_valid_i,
    output reg  load_finish_ready_o,
    input wire  load_finish_operand_i,
    input wire [BANK_W-1:0] load_finish_bank_i,
    input wire  load_finish_error_i,
    output reg  load_finish_error_o,
    input wire input_discard_valid_i,
    output reg input_discard_ready_o,
    input wire input_discard_operand_i,
    input wire [BANK_W-1:0] input_discard_bank_i,
    output reg input_discard_error_o,
    input wire [BANK_W-1:0] req_a_bank_i,
    input wire [BANK_W-1:0] req_b_bank_i,
    input wire [BANK_W-1:0] req_c_bank_i,
    input wire [TAG_W-1:0] req_tag_i,
    input wire  buffer_acquire_valid_i,
    output reg  buffer_acquire_ready_o,
    output reg  buffer_acquire_error_o,
    input wire  buffer_release_valid_i,
    output reg  buffer_release_ready_o,
    input wire  buffer_release_error_i,
    input wire  c_take_valid_i,
    output reg  c_take_ready_o,
    input wire [BANK_W-1:0] c_take_bank_i,
    output reg  c_take_error_o,
    output reg [TAG_W-1:0] c_take_tag_o,
    input wire  c_return_valid_i,
    output reg  c_return_ready_o,
    input wire [BANK_W-1:0] c_return_bank_i,
    output reg  c_return_error_o,
    output reg [AB_BANKS-1:0] a_free_o,
    output reg [AB_BANKS-1:0] a_loading_o,
    output reg [AB_BANKS-1:0] a_ready_o,
    output reg [AB_BANKS-1:0] a_in_use_o,
    output reg [AB_BANKS-1:0] b_free_o,
    output reg [AB_BANKS-1:0] b_loading_o,
    output reg [AB_BANKS-1:0] b_ready_o,
    output reg [AB_BANKS-1:0] b_in_use_o,
    output reg [C_BANKS-1:0] c_free_o,
    output reg [C_BANKS-1:0] c_in_use_o,
    output reg [C_BANKS-1:0] c_ready_o,
    output reg [C_BANKS-1:0] c_draining_o,
    output reg  lease_active_o,
    output reg  protocol_error_o
);
    reg  load_begin_valid_i_boundary_r;
    reg  load_begin_operand_i_boundary_r;
    reg [BANK_W-1:0] load_begin_bank_i_boundary_r;
    reg  load_finish_valid_i_boundary_r;
    reg  load_finish_operand_i_boundary_r;
    reg [BANK_W-1:0] load_finish_bank_i_boundary_r;
    reg  load_finish_error_i_boundary_r;
    reg input_discard_valid_i_boundary_r,input_discard_operand_i_boundary_r;
    reg [BANK_W-1:0] input_discard_bank_i_boundary_r;
    wire input_discard_ready_o_boundary_w,input_discard_error_o_boundary_w;
    reg [BANK_W-1:0] req_a_bank_i_boundary_r;
    reg [BANK_W-1:0] req_b_bank_i_boundary_r;
    reg [BANK_W-1:0] req_c_bank_i_boundary_r;
    reg [TAG_W-1:0] req_tag_i_boundary_r;
    reg  buffer_acquire_valid_i_boundary_r;
    reg  buffer_release_valid_i_boundary_r;
    reg  buffer_release_error_i_boundary_r;
    reg  c_take_valid_i_boundary_r;
    reg [BANK_W-1:0] c_take_bank_i_boundary_r;
    reg  c_return_valid_i_boundary_r;
    reg [BANK_W-1:0] c_return_bank_i_boundary_r;
    wire  load_begin_ready_o_boundary_w;
    wire  load_begin_error_o_boundary_w;
    wire  load_finish_ready_o_boundary_w;
    wire  load_finish_error_o_boundary_w;
    wire  buffer_acquire_ready_o_boundary_w;
    wire  buffer_acquire_error_o_boundary_w;
    wire  buffer_release_ready_o_boundary_w;
    wire  c_take_ready_o_boundary_w;
    wire  c_take_error_o_boundary_w;
    wire [TAG_W-1:0] c_take_tag_o_boundary_w;
    wire  c_return_ready_o_boundary_w;
    wire  c_return_error_o_boundary_w;
    wire [AB_BANKS-1:0] a_free_o_boundary_w;
    wire [AB_BANKS-1:0] a_loading_o_boundary_w;
    wire [AB_BANKS-1:0] a_ready_o_boundary_w;
    wire [AB_BANKS-1:0] a_in_use_o_boundary_w;
    wire [AB_BANKS-1:0] b_free_o_boundary_w;
    wire [AB_BANKS-1:0] b_loading_o_boundary_w;
    wire [AB_BANKS-1:0] b_ready_o_boundary_w;
    wire [AB_BANKS-1:0] b_in_use_o_boundary_w;
    wire [C_BANKS-1:0] c_free_o_boundary_w;
    wire [C_BANKS-1:0] c_in_use_o_boundary_w;
    wire [C_BANKS-1:0] c_ready_o_boundary_w;
    wire [C_BANKS-1:0] c_draining_o_boundary_w;
    wire  lease_active_o_boundary_w;
    wire  protocol_error_o_boundary_w;
    always @(posedge clk)begin
        load_begin_valid_i_boundary_r<=load_begin_valid_i;
        load_begin_operand_i_boundary_r<=load_begin_operand_i;
        load_begin_bank_i_boundary_r<=load_begin_bank_i;
        load_finish_valid_i_boundary_r<=load_finish_valid_i;
        load_finish_operand_i_boundary_r<=load_finish_operand_i;
        load_finish_bank_i_boundary_r<=load_finish_bank_i;
        load_finish_error_i_boundary_r<=load_finish_error_i;
        input_discard_valid_i_boundary_r<=input_discard_valid_i;
        input_discard_operand_i_boundary_r<=input_discard_operand_i;
        input_discard_bank_i_boundary_r<=input_discard_bank_i;
        input_discard_ready_o<=input_discard_ready_o_boundary_w;
        input_discard_error_o<=input_discard_error_o_boundary_w;
        req_a_bank_i_boundary_r<=req_a_bank_i;
        req_b_bank_i_boundary_r<=req_b_bank_i;
        req_c_bank_i_boundary_r<=req_c_bank_i;
        req_tag_i_boundary_r<=req_tag_i;
        buffer_acquire_valid_i_boundary_r<=buffer_acquire_valid_i;
        buffer_release_valid_i_boundary_r<=buffer_release_valid_i;
        buffer_release_error_i_boundary_r<=buffer_release_error_i;
        c_take_valid_i_boundary_r<=c_take_valid_i;
        c_take_bank_i_boundary_r<=c_take_bank_i;
        c_return_valid_i_boundary_r<=c_return_valid_i;
        c_return_bank_i_boundary_r<=c_return_bank_i;
        load_begin_ready_o<=load_begin_ready_o_boundary_w;
        load_begin_error_o<=load_begin_error_o_boundary_w;
        load_finish_ready_o<=load_finish_ready_o_boundary_w;
        load_finish_error_o<=load_finish_error_o_boundary_w;
        buffer_acquire_ready_o<=buffer_acquire_ready_o_boundary_w;
        buffer_acquire_error_o<=buffer_acquire_error_o_boundary_w;
        buffer_release_ready_o<=buffer_release_ready_o_boundary_w;
        c_take_ready_o<=c_take_ready_o_boundary_w;
        c_take_error_o<=c_take_error_o_boundary_w;
        c_take_tag_o<=c_take_tag_o_boundary_w;
        c_return_ready_o<=c_return_ready_o_boundary_w;
        c_return_error_o<=c_return_error_o_boundary_w;
        a_free_o<=a_free_o_boundary_w;
        a_loading_o<=a_loading_o_boundary_w;
        a_ready_o<=a_ready_o_boundary_w;
        a_in_use_o<=a_in_use_o_boundary_w;
        b_free_o<=b_free_o_boundary_w;
        b_loading_o<=b_loading_o_boundary_w;
        b_ready_o<=b_ready_o_boundary_w;
        b_in_use_o<=b_in_use_o_boundary_w;
        c_free_o<=c_free_o_boundary_w;
        c_in_use_o<=c_in_use_o_boundary_w;
        c_ready_o<=c_ready_o_boundary_w;
        c_draining_o<=c_draining_o_boundary_w;
        lease_active_o<=lease_active_o_boundary_w;
        protocol_error_o<=protocol_error_o_boundary_w;
    end
    (* keep_hierarchy="yes" *) npu_v13_buffer_manager #(.AB_BANKS(AB_BANKS),.C_BANKS(C_BANKS),.BANK_W(BANK_W),.TAG_W(TAG_W)) u_dut (
        .clk(clk),
        .resetn(resetn),
        .load_begin_valid_i(load_begin_valid_i_boundary_r),
        .load_begin_ready_o(load_begin_ready_o_boundary_w),
        .load_begin_operand_i(load_begin_operand_i_boundary_r),
        .load_begin_bank_i(load_begin_bank_i_boundary_r),
        .load_begin_error_o(load_begin_error_o_boundary_w),
        .load_finish_valid_i(load_finish_valid_i_boundary_r),
        .load_finish_ready_o(load_finish_ready_o_boundary_w),
        .load_finish_operand_i(load_finish_operand_i_boundary_r),
        .load_finish_bank_i(load_finish_bank_i_boundary_r),
        .load_finish_error_i(load_finish_error_i_boundary_r),
        .load_finish_error_o(load_finish_error_o_boundary_w),
        .input_discard_valid_i(input_discard_valid_i_boundary_r),.input_discard_ready_o(input_discard_ready_o_boundary_w),
        .input_discard_operand_i(input_discard_operand_i_boundary_r),.input_discard_bank_i(input_discard_bank_i_boundary_r),.input_discard_error_o(input_discard_error_o_boundary_w),
        .req_a_bank_i(req_a_bank_i_boundary_r),
        .req_b_bank_i(req_b_bank_i_boundary_r),
        .req_c_bank_i(req_c_bank_i_boundary_r),
        .req_tag_i(req_tag_i_boundary_r),
        .buffer_acquire_valid_i(buffer_acquire_valid_i_boundary_r),
        .buffer_acquire_ready_o(buffer_acquire_ready_o_boundary_w),
        .buffer_acquire_error_o(buffer_acquire_error_o_boundary_w),
        .buffer_release_valid_i(buffer_release_valid_i_boundary_r),
        .buffer_release_ready_o(buffer_release_ready_o_boundary_w),
        .buffer_release_error_i(buffer_release_error_i_boundary_r),
        .c_take_valid_i(c_take_valid_i_boundary_r),
        .c_take_ready_o(c_take_ready_o_boundary_w),
        .c_take_bank_i(c_take_bank_i_boundary_r),
        .c_take_error_o(c_take_error_o_boundary_w),
        .c_take_tag_o(c_take_tag_o_boundary_w),
        .c_return_valid_i(c_return_valid_i_boundary_r),
        .c_return_ready_o(c_return_ready_o_boundary_w),
        .c_return_bank_i(c_return_bank_i_boundary_r),
        .c_return_error_o(c_return_error_o_boundary_w),
        .a_free_o(a_free_o_boundary_w),
        .a_loading_o(a_loading_o_boundary_w),
        .a_ready_o(a_ready_o_boundary_w),
        .a_in_use_o(a_in_use_o_boundary_w),
        .b_free_o(b_free_o_boundary_w),
        .b_loading_o(b_loading_o_boundary_w),
        .b_ready_o(b_ready_o_boundary_w),
        .b_in_use_o(b_in_use_o_boundary_w),
        .c_free_o(c_free_o_boundary_w),
        .c_in_use_o(c_in_use_o_boundary_w),
        .c_ready_o(c_ready_o_boundary_w),
        .c_draining_o(c_draining_o_boundary_w),
        .lease_active_o(lease_active_o_boundary_w),
        .protocol_error_o(protocol_error_o_boundary_w)
    );
endmodule
