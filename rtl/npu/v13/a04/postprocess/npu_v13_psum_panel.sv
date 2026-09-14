// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// S2-N1 native direct P4 PSUM panel.
//
// Unlike the A04-aligned path, this module does not buffer each island in a
// 131-word result front store.  The P4-striped compute boundary already emits
// one addressable 128-bit word per island per cycle.  Each island therefore has
// only one validation register followed directly by its resident BRAM PSUM.
// Validation failures are consumed and reported as a sticky task error so a
// malformed beat cannot deadlock completion.
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
    localparam integer MAX_M_AW=$clog2(MAX_M);
    localparam integer MAX_N_AW=$clog2(MAX_N);
    localparam integer LOCAL_ROW_AW=$clog2(MAX_M/4);
    localparam integer LOCAL_COL_AW=$clog2(MAX_N/4);

    reg active_r,ended_r,bad_r;
    reg [15:0] m_r,n_r,tag_r;
    reg first_r,final_r;
    wire [3:0] lane_idle_w,lane_error_w,lane_commit_error_w,lane_validation_error_w;

    assign ctx_ready_o=resetn && !active_r && (&lane_idle_w);
    assign end_ready_o=resetn && active_r && !ended_r;
    assign done_valid_o=resetn && active_r && ended_r && (&lane_idle_w);
    assign done_error_o=bad_r || (|lane_error_w);
    assign busy_o=active_r || !( &lane_idle_w );

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
                bad_r<=(ctx_m_i==0 || ctx_n_i==0 ||
                       ctx_m_i>MAX_M || ctx_n_i>MAX_N);
            end else if((|lane_error_w) || (|lane_commit_error_w) || (|lane_validation_error_w)) begin
                bad_r<=1'b1;
            end
            if(end_valid_i && end_ready_o)
                ended_r<=1'b1;
            if(done_valid_o && done_ready_i)
                active_r<=1'b0;
        end
    end

    genvar g;
    generate for(g=0;g<4;g=g+1) begin:G_ISLAND
        localparam [1:0] ISLAND_ID=g;
        wire permit_w=resetn && active_r && !ended_r;
        wire [15:0] ingress_m_w=c_m_i[g*16+:16];
        wire [15:0] ingress_n_w=c_n_i[g*16+:16];
        wire [15:0] ingress_tag_w=c_tag_i[g*16+:16];
        wire [3:0] ingress_keep_w=c_keep_i[g*4+:4];
        wire [LOCAL_ROW_AW-1:0] ingress_local_row_w=
            {ingress_m_w[MAX_M_AW-1:4],ingress_m_w[1:0]};
        wire [LOCAL_COL_AW-1:0] ingress_local_col_w=
            ingress_n_w[MAX_N_AW-1:2];
        wire [AW-1:0] ingress_addr_w=
            {ingress_local_row_w,ingress_local_col_w};
        wire ingress_m_oob_w=|(ingress_m_w>>MAX_M_AW);
        wire ingress_n_oob_w=|(ingress_n_w>>MAX_N_AW);
        wire ingress_fixed_bad_w=ingress_m_oob_w || ingress_n_oob_w ||
            ingress_n_w[1:0]!=0 || ingress_m_w[3:2]!=ISLAND_ID;
        wire ingress_tag_bad_w=(ingress_tag_w!=tag_r);
        wire ingress_m_in_ctx_w=(ingress_m_w<m_r);
        wire [3:0] ingress_n_in_ctx_w;
        genvar l;
        for(l=0;l<4;l=l+1) begin:G_KEEP_CHECK
            assign ingress_n_in_ctx_w[l]=
                ({1'b0,ingress_n_w}+l < {1'b0,n_r});
        end
        wire [3:0] ingress_expected_keep_w=
            {4{ingress_m_in_ctx_w}} & ingress_n_in_ctx_w;
        wire ingress_bad_w=ingress_fixed_bad_w || ingress_tag_bad_w ||
            (ingress_keep_w!=ingress_expected_keep_w);

        // One local validation/decoupling stage.  Its full state is local to
        // the associated PSUM bank; no central wide enable or address fanout.
        reg stage_valid_r,stage_bad_r,stage_first_r,stage_final_r;
        reg [127:0] stage_data_r;
        reg [3:0] stage_keep_r;
        reg [AW-1:0] stage_addr_r;
        reg [47:0] stage_meta_r;
        wire psum_ready_w,psum_idle_w,psum_error_w;
        wire stage_take_w=resetn && stage_valid_r &&
            (stage_bad_r || psum_ready_w);
        wire stage_space_w=!stage_valid_r || stage_take_w;
        assign c_ready_o[g]=permit_w && stage_space_w;
        wire stage_push_w=c_valid_i[g] && c_ready_o[g];

        always @(posedge clk) begin
            if(!resetn) begin
                stage_valid_r<=1'b0;
                stage_bad_r<=1'b0;
            end else begin
                if(stage_take_w)
                    stage_valid_r<=1'b0;
                if(stage_push_w) begin
                    stage_valid_r<=1'b1;
                    stage_bad_r<=ingress_bad_w;
                    stage_first_r<=first_r;
                    stage_final_r<=final_r;
                    stage_data_r<=c_data_i[g*128+:128];
                    stage_keep_r<=ingress_keep_w;
                    stage_addr_r<=ingress_addr_w;
                    stage_meta_r<={ingress_tag_w,ingress_m_w,ingress_n_w};
                end
                if(ctx_valid_i && ctx_ready_o)
                    stage_bad_r<=1'b0;
            end
        end

        wire [AW-1:0] local_out_addr_w,local_commit_addr_w;
        wire [47:0] local_out_meta_w,local_commit_meta_w;
        wire local_commit_final_w;
        wire [3:0] local_commit_keep_w;
        npu_v13_psum_p4 #(.DEPTH(DEPTH),.ADDR_W(AW),.META_W(48)) u_psum(
            .clk(clk),.resetn(resetn),
            .in_valid_i(stage_valid_r && !stage_bad_r),
            .in_ready_o(psum_ready_w),
            .in_addr_i(stage_addr_r),.in_data_i(stage_data_r),
            .in_keep_i(stage_keep_r),.in_first_i(stage_first_r),
            .in_final_i(stage_final_r),.in_meta_i(stage_meta_r),
            .out_valid_o(out_valid_o[g]),.out_ready_i(out_ready_i[g]),
            .out_data_o(out_data_o[g*128+:128]),
            .out_keep_o(out_keep_o[g*4+:4]),
            .out_addr_o(local_out_addr_w),.out_meta_o(local_out_meta_w),
            .commit_valid_o(commit_o[g]),
            .commit_error_o(lane_commit_error_w[g]),
            .commit_final_o(local_commit_final_w),
            .commit_keep_o(local_commit_keep_w),
            .commit_addr_o(local_commit_addr_w),
            .commit_meta_o(local_commit_meta_w),
            .idle_o(psum_idle_w),.error_o(psum_error_w));

        assign {out_tag_o[g*16+:16],out_m_o[g*16+:16],
                out_n_o[g*16+:16]}=local_out_meta_w;
        assign lane_validation_error_w[g]=stage_take_w && stage_bad_r;
        assign lane_idle_w[g]=!stage_valid_r && psum_idle_w;
        assign lane_error_w[g]=psum_error_w;
    end endgenerate

    // synthesis translate_off
    initial begin
        if(MAX_M<32 || MAX_N<8 || (MAX_M&(MAX_M-1))!=0 ||
           (MAX_N&(MAX_N-1))!=0 || DEPTH!=(MAX_M/4)*(MAX_N/4) ||
           AW!=LOCAL_ROW_AW+LOCAL_COL_AW)
            $fatal(1,"S2-N1 direct PSUM static capacity");
    end
    always @(posedge clk) if(resetn && end_valid_i && end_ready_o && (|c_valid_i))
        $fatal(1,"S2-N1 PSUM end must follow all backend transfers");
    // synthesis translate_on
endmodule


