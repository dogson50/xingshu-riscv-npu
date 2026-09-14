// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// S2-N1 native P4-striped packet backend.
//
// This is a drop-in replacement at the formal A04 command-backend boundary,
// but the internal result architecture is native to the unified S2 compute
// schedule.  It removes the central 512-bit matrix row, four 512-bit shadows,
// four large result BRAM FIFOs and reservation/capture/retire accounting.
// Four local 181-bit two-entry slices carry {data, keep, coordinate, tag} from
// the four registered P4 lanes directly to the four resident PSUM banks.
module npu_v13_packet_backend #(
    parameter integer AW=12, MAX_K=512, TOTAL_SLOTS=32, CAPTURE_SLOTS=4,
    parameter integer UW=$clog2(TOTAL_SLOTS+1)
)(
    input wire clk,resetn,
    input wire cfg_valid_i,
    input wire [1:0] cfg_mode_i,
    output wire cfg_ready_o,cfg_error_o,
    output wire [1:0] active_mode_o,
    output wire cluster_idle_o,
    input wire start_i,
    input wire [15:0] tag_i,
    input wire buffers_owned_i,
    input wire schedule_finished_i,
    input wire desc_valid_i,
    output wire desc_ready_o,
    input wire [AW-1:0] desc_a_i,desc_b_i,
    input wire [15:0] desc_k_i,desc_m_i,desc_n_i,
    input wire [4:0] desc_rows_i,desc_cols_i,
    input wire allow_beat_i,
    output wire rd_valid_o,
    output wire [AW-1:0] rd_a_addr_o,rd_b_addr_o,
    input wire ram_valid_i,
    input wire [127:0] ram_a_i,ram_b_i,
    output wire [3:0] c_valid_o,
    input wire [3:0] c_ready_i,
    output wire [511:0] c_data_o,
    output wire [15:0] c_keep_o,
    output wire [63:0] c_m_o,c_n_o,c_tag_o,
    output wire [3:0] c_tile_last_o,
    output wire done_valid_o,
    input wire done_ready_i,
    output wire [15:0] done_tag_o,
    output wire done_error_o,busy_o,
    output wire input_beat_o,packet_issue_o,reserve_wait_o,
    output wire [4*UW-1:0] slots_used_o,
    output wire [15:0] pending_o,outstanding_o,
    output wire error_o
);
    reg [15:0] tag_r;
    reg busy_r,done_valid_r,job_error_r;

    // Only GEMM mode 0 is implemented, matching the formal transport command.
    reg [1:0] active_mode_r;
    reg cfg_error_r;
    assign cfg_ready_o=resetn && !busy_r && cluster_idle_o;
    assign cfg_error_o=cfg_error_r;
    assign active_mode_o=active_mode_r;
    always @(posedge clk) begin
        if(!resetn) begin
            active_mode_r<=2'b00;
            cfg_error_r<=1'b0;
        end else if(cfg_valid_i && cfg_ready_o) begin
            active_mode_r<=cfg_mode_i;
            if(cfg_mode_i!=2'b00)
                cfg_error_r<=1'b1;
        end
    end

    wire reserve_w,pv_w,issue_idle_w,issue_error_w,feeder_idle_w;
    wire [15:0] mask_w,rm_w,rn_w,rt_w,pk_w;
    wire [AW-1:0] pa_w,pb_w;
    wire [4:0] prows_w,pcols_w;
    wire issue_ready_w,packet_ready_w;
    wire [3:0] reserve_ready_w=4'b1111;
    assign desc_ready_o=issue_ready_w && busy_r && !done_valid_r;

    npu_v13_packet_issue_ctrl #(.AW(AW),.MAX_K(MAX_K)) u_issue(
        .clk(clk),.resetn(resetn),
        .desc_valid_i(desc_valid_i && busy_r && !done_valid_r),
        .desc_ready_o(issue_ready_w),
        .desc_a_i(desc_a_i),.desc_b_i(desc_b_i),.desc_k_i(desc_k_i),
        .desc_rows_i(desc_rows_i),.desc_cols_i(desc_cols_i),
        .desc_m_i(desc_m_i),.desc_n_i(desc_n_i),.desc_tag_i(tag_r),
        .buffers_owned_i(buffers_owned_i),
        .reserve_valid_o(reserve_w),.reserve_ready_i(reserve_ready_w),
        .reserve_mask_o(mask_w),.reserve_m_o(rm_w),.reserve_n_o(rn_w),
        .reserve_tag_o(rt_w),
        .packet_valid_o(pv_w),.packet_ready_i(packet_ready_w),
        .packet_a_o(pa_w),.packet_b_o(pb_w),.packet_k_o(pk_w),
        .packet_rows_o(prows_w),.packet_cols_o(pcols_w),
        .idle_o(issue_idle_w),.error_o(issue_error_w));

    // Packet context queue contains no result payload and no reservation state.
    // {tag, base_m, base_n, active_rows, active_cols}
    localparam integer CTX_W=58;
    reg [CTX_W-1:0] ctx_q_r[0:3];
    reg [2:0] ctx_count_r;
    reg [CTX_W-1:0] next_ctx_r,active_ctx_r;
    reg next_ctx_valid_r,active_ctx_valid_r,ctx_error_r;

    wire core_launch_ready_w;
    wire feeder_packet_ready_w;
    wire feed_valid_w,feed_first_w,feed_last_w;
    localparam integer CORE_FIRST_II=16;
    localparam integer FEED_FIRST_LATENCY=4;
    localparam integer FIRST_TO_ADMIT_GAP=CORE_FIRST_II-FEED_FIRST_LATENCY;
    localparam integer TAIL_TO_SHORT_ADMIT_MAX=CORE_FIRST_II-FEED_FIRST_LATENCY;
    reg launch_pending_r;
    reg [3:0] launch_lookahead_r;
    reg tail_pending_r;
    reg [3:0] tail_guard_r;
    wire short_k_tail_safe_w=!tail_pending_r && pk_w!=0 &&
        tail_guard_r <= (pk_w[3:0]-1'b1);
    wire next_tail_safe_w=(pk_w>=CORE_FIRST_II) || short_k_tail_safe_w;
    wire packet_admit_w=!launch_pending_r && launch_lookahead_r==0 &&
        next_tail_safe_w && ctx_count_r<4;
    assign packet_ready_w=feeder_packet_ready_w && packet_admit_w;
    assign packet_issue_o=pv_w && packet_ready_w;

    always @(posedge clk) begin
        if(!resetn) begin
            launch_pending_r<=1'b0;
            launch_lookahead_r<=0;
            tail_pending_r<=1'b0;
            tail_guard_r<=0;
        end else begin
            if(feed_valid_w && feed_first_w) begin
                launch_pending_r<=1'b0;
                launch_lookahead_r<=FIRST_TO_ADMIT_GAP-1;
            end else if(launch_lookahead_r!=0) begin
                launch_lookahead_r<=launch_lookahead_r-1'b1;
            end
            if(packet_issue_o)
                launch_pending_r<=1'b1;

            if(feed_valid_w && feed_last_w) begin
                tail_guard_r<=TAIL_TO_SHORT_ADMIT_MAX-1;
                tail_pending_r<=1'b0;
            end else begin
                if(tail_guard_r!=0)
                    tail_guard_r<=tail_guard_r-1'b1;
                if(feed_valid_w && feed_first_w)
                    tail_pending_r<=1'b1;
            end
        end
    end
    assign reserve_wait_o=!issue_idle_w && !pv_w && !reserve_w;
    wire [CTX_W-1:0] issue_ctx_w={rt_w,rm_w,rn_w,prows_w,pcols_w};

    wire [4:0] feed_rows_w,feed_cols_w;
    wire [127:0] feed_a_w,feed_b_w;
    panel_feeder_exp #(.G(16),.S(1),.WORD_W(128),.AW(AW),
        .KW($clog2(MAX_K+1))) u_feeder(
        .clk(clk),.resetn(resetn),
        .packet_valid_i(pv_w && packet_admit_w),
        .packet_ready_o(feeder_packet_ready_w),
        .a_base_i(pa_w),.b_base_i(pb_w),.steps_i(pk_w),
        .last_lanes_i(3'd1),.rows_i(prows_w),.cols_i(pcols_w),
        .allow_beat_i(allow_beat_i),
        .rd_valid_o(rd_valid_o),.rd_a_addr_o(rd_a_addr_o),
        .rd_b_addr_o(rd_b_addr_o),
        .ram_valid_i(ram_valid_i),.ram_a_i(ram_a_i),.ram_b_i(ram_b_i),
        .valid_o(feed_valid_w),.init_o(feed_first_w),.last_o(feed_last_w),
        .rows_o(feed_rows_w),.cols_o(feed_cols_w),
        .a_o(feed_a_w),.b_o(feed_b_w),.idle_o(feeder_idle_w));
    assign input_beat_o=feed_valid_w;

    wire core_p4_valid_w;
    wire [1:0] core_local_row_w,core_col_group_w;
    wire [127:0] core_lane0_w,core_lane1_w,core_lane2_w,core_lane3_w;
    wire core_drain_start_w,core_packet_done_w,core_drain_busy_w,core_error_w;
    npu_s2_n1_unified_p4_core u_s2_core(
        .clk(clk),.resetn(resetn),.valid_i(feed_valid_w),
        .first_i(feed_first_w),.last_i(feed_last_w),
        .a_rows_i(feed_a_w),.b_cols_i(feed_b_w),
        .launch_ready_o(core_launch_ready_w),
        .p4_valid_o(core_p4_valid_w),.local_row_o(core_local_row_w),
        .col_group_o(core_col_group_w),
        .lane0_data_o(core_lane0_w),.lane1_data_o(core_lane1_w),
        .lane2_data_o(core_lane2_w),.lane3_data_o(core_lane3_w),
        .drain_start_o(core_drain_start_w),
        .packet_done_o(core_packet_done_w),
        .drain_busy_o(core_drain_busy_w),
        .protocol_error_o(core_error_w));

    wire p4_first_w=core_p4_valid_w && core_local_row_w==0 &&
        core_col_group_w==0;
    wire p4_last_w=core_packet_done_w;
    wire [CTX_W-1:0] emit_ctx_w=p4_first_w ? next_ctx_r : active_ctx_r;
    wire emit_ctx_valid_w=p4_first_w ? next_ctx_valid_r : active_ctx_valid_r;
    wire [15:0] emit_tag_w=emit_ctx_w[57:42];
    wire [15:0] emit_m_w=emit_ctx_w[41:26];
    wire [15:0] emit_n_w=emit_ctx_w[25:10];
    wire [4:0] emit_rows_w=emit_ctx_w[9:5];
    wire [4:0] emit_cols_w=emit_ctx_w[4:0];

    reg [2:0] core_inflight_r;
    integer qi;
    always @(posedge clk) begin
        if(!resetn) begin
            ctx_count_r<=0;
            next_ctx_valid_r<=1'b0;
            active_ctx_valid_r<=1'b0;
            ctx_error_r<=1'b0;
            core_inflight_r<=0;
        end else begin
            if(start_i)
                ctx_error_r<=1'b0;
            case({packet_issue_o,core_drain_start_w})
                2'b10: begin
                    if(ctx_count_r<4) begin
                        ctx_q_r[ctx_count_r]<=issue_ctx_w;
                        ctx_count_r<=ctx_count_r+1'b1;
                    end else ctx_error_r<=1'b1;
                end
                2'b01: begin
                    if(ctx_count_r==0) ctx_error_r<=1'b1;
                    else begin
                        next_ctx_r<=ctx_q_r[0];
                        next_ctx_valid_r<=1'b1;
                        for(qi=0;qi<3;qi=qi+1)
                            ctx_q_r[qi]<=ctx_q_r[qi+1];
                        ctx_count_r<=ctx_count_r-1'b1;
                    end
                end
                2'b11: begin
                    if(ctx_count_r==0) ctx_error_r<=1'b1;
                    else begin
                        next_ctx_r<=ctx_q_r[0];
                        next_ctx_valid_r<=1'b1;
                        for(qi=0;qi<2;qi=qi+1)
                            ctx_q_r[qi]<=ctx_q_r[qi+1];
                        ctx_q_r[ctx_count_r-1'b1]<=issue_ctx_w;
                    end
                end
                default: ;
            endcase

            // First beat reads prefetched next_ctx; later beats use active_ctx.
            // This also handles old step15/new drain_start overlap without ever
            // relabeling the old packet's final P4 word.
            if(p4_first_w) begin
                if(next_ctx_valid_r) begin
                    active_ctx_r<=next_ctx_r;
                    active_ctx_valid_r<=1'b1;
                    next_ctx_valid_r<=1'b0;
                end else ctx_error_r<=1'b1;
            end else if(p4_last_w) begin
                active_ctx_valid_r<=1'b0;
            end
            if(core_p4_valid_w && !emit_ctx_valid_w)
                ctx_error_r<=1'b1;

            case({packet_issue_o,core_packet_done_w})
                2'b10: core_inflight_r<=core_inflight_r+1'b1;
                2'b01: begin
                    if(core_inflight_r==0) ctx_error_r<=1'b1;
                    else core_inflight_r<=core_inflight_r-1'b1;
                end
                default: ;
            endcase
        end
    end

    // Four physical output lanes, each with its own local data and control.
    wire [511:0] core_lane_data_w={core_lane3_w,core_lane2_w,
                                   core_lane1_w,core_lane0_w};
    wire [3:0] slice_in_ready_w,slice_idle_w,slice_overflow_w;
    wire [1:0] col_group_base_w=core_col_group_w;
    genvar g;
    generate for(g=0;g<4;g=g+1) begin:G_P4_LANE
        localparam integer ROW_BASE=4*g;
        wire [4:0] row_offset_w=ROW_BASE+{3'b000,core_local_row_w};
        wire [4:0] col_offset_w={1'b0,col_group_base_w,2'b00};
        wire row_group_active_w=(ROW_BASE<emit_rows_w);
        wire col_group_active_w=(col_offset_w<emit_cols_w);
        wire row_in_range_w=(row_offset_w<emit_rows_w);
        wire [3:0] lane_keep_w;
        genvar e;
        for(e=0;e<4;e=e+1) begin:G_KEEP
            assign lane_keep_w[e]=row_in_range_w &&
                (col_offset_w+e<emit_cols_w);
        end
        wire [15:0] lane_m_w=emit_m_w+row_offset_w;
        wire [15:0] lane_n_w=emit_n_w+col_offset_w;
        wire lane_valid_w=core_p4_valid_w && emit_ctx_valid_w &&
            row_group_active_w && col_group_active_w;
        wire [180:0] slice_in_data_w={core_local_row_w==2'd3,
            emit_tag_w,lane_m_w,lane_n_w,lane_keep_w,
            core_lane_data_w[g*128+:128]};
        wire [180:0] slice_out_data_w;
        assign slice_overflow_w[g]=lane_valid_w && !slice_in_ready_w[g];
        npu_v13_stream_slice2 #(.WIDTH(181)) u_slice(
            .clk(clk),.resetn(resetn),
            .in_valid_i(lane_valid_w),.in_ready_o(slice_in_ready_w[g]),
            .in_data_i(slice_in_data_w),
            .out_valid_o(c_valid_o[g]),.out_ready_i(c_ready_i[g]),
            .out_data_o(slice_out_data_w),.idle_o(slice_idle_w[g]));
        assign {c_tile_last_o[g],c_tag_o[g*16+:16],c_m_o[g*16+:16],
                c_n_o[g*16+:16],c_keep_o[g*4+:4],
                c_data_o[g*128+:128]}=slice_out_data_w;
    end endgenerate

    // These compatibility observability ports belonged to the deleted result
    // reservation fabric.  Native completion below tracks actual pipeline
    // emptiness instead of manufacturing equivalent slot counters.
    assign slots_used_o={4*UW{1'b0}};
    assign pending_o=16'b0;
    assign outstanding_o=16'b0;

    assign cluster_idle_o=(core_inflight_r==0) && !core_drain_busy_w &&
        !core_p4_valid_w && ctx_count_r==0 && !next_ctx_valid_r &&
        !active_ctx_valid_r && (&slice_idle_w);
    wire internal_error_w=issue_error_w || core_error_w || ctx_error_r ||
        (|slice_overflow_w) || cfg_error_r;
    wire completion_ready_w=busy_r && !done_valid_r && schedule_finished_i &&
        issue_idle_w && feeder_idle_w && cluster_idle_o;

    always @(posedge clk) begin
        if(!resetn) begin
            tag_r<=0;
            busy_r<=1'b0;
            done_valid_r<=1'b0;
            job_error_r<=1'b0;
        end else begin
            if(start_i && !busy_r) begin
                tag_r<=tag_i;
                busy_r<=1'b1;
                done_valid_r<=1'b0;
                job_error_r<=1'b0;
            end
            if(busy_r && internal_error_w)
                job_error_r<=1'b1;
            if(completion_ready_w)
                done_valid_r<=1'b1;
            if(done_valid_r && done_ready_i) begin
                done_valid_r<=1'b0;
                busy_r<=1'b0;
            end
        end
    end

    assign done_valid_o=resetn && done_valid_r;
    assign done_tag_o=tag_r;
    assign done_error_o=job_error_r;
    assign busy_o=busy_r;
    assign error_o=internal_error_w || job_error_r;

    // synthesis translate_off
    always @(posedge clk) if(resetn) begin
        if(feed_valid_w && feed_first_w && !core_launch_ready_w)
            $fatal(1,"S2-N1 core first beat arrived before launch ready");
        if(core_drain_start_w && ctx_count_r==0)
            $fatal(1,"S2-N1 drain without packet context");
        if(core_p4_valid_w && !emit_ctx_valid_w)
            $fatal(1,"S2-N1 P4 output without active context");
        if(|slice_overflow_w)
            $fatal(1,"S2-N1 local elastic slice overflow lanes=%b",slice_overflow_w);
        if(issue_error_w)
            $fatal(1,"S2-N1 issue controller error");
        if(core_error_w)
            $fatal(1,"S2-N1 core protocol error");
        if(start_i && busy_r)
            $fatal(1,"S2-N1 overlapping start");
    end
    // synthesis translate_on
endmodule
