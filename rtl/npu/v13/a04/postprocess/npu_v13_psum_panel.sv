// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// P79完整四岛集成实验：以P23四岛GEMM整链为基线，将P73局部前端+P4 PSUM实例化四份。
// 每岛只在本地BRAM保存128-bit payload；跨岛/跨后处理边界仍保持4路独立ready/valid。
// 不强制四岛同拍汇合，稳态每岛保持1个P4 word/cycle（4个INT32 lane）。
module npu_v13_psum_panel #(
    parameter integer MAX_M=128, MAX_N=128,
    parameter integer DEPTH=(MAX_M/4)*(MAX_N/4),
    parameter integer AW=(DEPTH<=2 ? 1 : $clog2(DEPTH)),
    parameter integer FRONT_STORE_DEPTH=128
)(
    input wire clk,
    input wire resetn,
    input wire ctx_valid_i,
    output wire ctx_ready_o,
    input wire [15:0] ctx_m_i,ctx_n_i,ctx_tag_i,
    input wire ctx_first_i,ctx_final_i,
    input wire [3:0] c_valid_i,
    output wire [3:0] c_ready_o,
    input wire [511:0] c_data_i,
    input wire [15:0] c_keep_i,
    input wire [63:0] c_m_i,c_n_i,c_tag_i,
    input wire end_valid_i,
    output wire end_ready_o,
    output wire done_valid_o,
    input wire done_ready_i,
    output wire done_error_o,
    output wire [3:0] out_valid_o,
    input wire [3:0] out_ready_i,
    output wire [511:0] out_data_o,
    output wire [15:0] out_keep_o,
    output wire [63:0] out_m_o,out_n_o,out_tag_o,
    output wire [3:0] commit_o,
    output wire busy_o
);
    reg active_r,ended_r,bad_r;
    reg [15:0] m_r,n_r,tag_r;
    reg first_r,final_r;
    wire [3:0] island_idle_w,island_error_w;

    assign ctx_ready_o=resetn && !active_r && (&island_idle_w);
    assign end_ready_o=resetn && active_r && !ended_r;
    assign done_valid_o=resetn && active_r && ended_r && (&island_idle_w);
    assign done_error_o=bad_r || (|island_error_w);
    assign busy_o=active_r || !( &island_idle_w );

    always @(posedge clk) begin
        if(!resetn) begin
            active_r<=1'b0;
            ended_r<=1'b0;
            bad_r<=1'b0;
        end else begin
            if(ctx_valid_i && ctx_ready_o) begin
                active_r<=1'b1;
                ended_r<=1'b0;
                m_r<=ctx_m_i;
                n_r<=ctx_n_i;
                tag_r<=ctx_tag_i;
                first_r<=ctx_first_i;
                final_r<=ctx_final_i;
                bad_r<=(ctx_m_i==0 || ctx_n_i==0 || ctx_m_i>MAX_M || ctx_n_i>MAX_N);
            end
            else if(|island_error_w) bad_r<=1'b1;
            if(end_valid_i && end_ready_o) ended_r<=1'b1;
            if(done_valid_o && done_ready_i) active_r<=1'b0;
        end
    end

    genvar g;
    generate for(g=0;g<4;g=g+1) begin:G_ISLAND
        wire permit=resetn && active_r && !ended_r;
        wire local_ready;
        wire [AW-1:0] local_out_addr,local_commit_addr;
        wire [47:0] local_out_meta,local_commit_meta;
        wire local_commit_error,local_commit_final;
        wire [3:0] local_commit_keep;
        wire [$clog2(FRONT_STORE_DEPTH+1)-1:0] local_used;

        assign c_ready_o[g]=permit && local_ready;
        assign {out_tag_o[g*16+:16],out_m_o[g*16+:16],out_n_o[g*16+:16]}=local_out_meta;

        npu_v24_local_result_psum_island #(
            .ISLAND_ID(g),.MAX_M(MAX_M),.MAX_N(MAX_N),
            .STORE_DEPTH(FRONT_STORE_DEPTH),.PSUM_DEPTH(DEPTH),.PSUM_AW(AW)
        ) u_local_result_psum(
            .clk(clk),.resetn(resetn),.clear_error_i(ctx_valid_i && ctx_ready_o),
            .ctx_m_i(m_r),.ctx_n_i(n_r),.ctx_tag_i(tag_r),
            .ctx_first_i(first_r),.ctx_final_i(final_r),
            .in_valid_i(permit && c_valid_i[g]),.in_ready_o(local_ready),
            .in_data_i(c_data_i[g*128+:128]),.in_keep_i(c_keep_i[g*4+:4]),
            .in_m_i(c_m_i[g*16+:16]),.in_n_i(c_n_i[g*16+:16]),
            .in_tag_i(c_tag_i[g*16+:16]),.in_tile_last_i(1'b0),
            .out_valid_o(out_valid_o[g]),.out_ready_i(out_ready_i[g]),
            .out_data_o(out_data_o[g*128+:128]),.out_keep_o(out_keep_o[g*4+:4]),
            .out_addr_o(local_out_addr),.out_meta_o(local_out_meta),
            .commit_valid_o(commit_o[g]),.commit_error_o(local_commit_error),
            .commit_final_o(local_commit_final),.commit_keep_o(local_commit_keep),
            .commit_addr_o(local_commit_addr),.commit_meta_o(local_commit_meta),
            .idle_o(island_idle_w[g]),.error_o(island_error_w[g]),
            .store_used_o(local_used)
        );
    end endgenerate

    // synthesis translate_off
    initial begin
        if(MAX_M<32 || MAX_N<8 || (MAX_M&(MAX_M-1))!=0 || (MAX_N&(MAX_N-1))!=0 ||
           DEPTH!=(MAX_M/4)*(MAX_N/4) || AW!=$clog2(DEPTH) || FRONT_STORE_DEPTH<4)
            $fatal(1,"P79 four-island static capacity");
    end
    always @(posedge clk) if(resetn && end_valid_i && end_ready_o && (|c_valid_i))
        $fatal(1,"P79 end must follow all backend result transfers");
    // synthesis translate_on
endmodule


