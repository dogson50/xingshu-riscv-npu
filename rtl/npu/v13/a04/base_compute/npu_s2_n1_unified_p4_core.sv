// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// S2-N1 unified 16x16 output-stationary compute core with native P4-striped drain.
//
// Physical compute remains sixteen regular 4x4 DSP tiles (256 INT8 MAC/cycle).
// The output boundary never constructs a 512-bit global matrix row.  Instead,
// every drain cycle exports four independent 128-bit P4 words:
//
//   local_row = drain_step[3:2]
//   col_group = drain_step[1:0]
//   lane g    = tile[g][col_group].row[local_row], g=0..3
//
// Therefore cycle 0 carries rows {0,4,8,12}, columns 0..3; cycle 1 carries
// the same rows, columns 4..7; and cycle 15 carries rows {3,7,11,15},
// columns 12..15.  A complete 16x16 packet is still drained in 16 cycles.
module npu_s2_n1_unified_p4_core #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W  = 32
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         valid_i,
    input  wire                         first_i,
    input  wire                         last_i,
    input  wire [16*DATA_W-1:0]         a_rows_i,
    input  wire [16*DATA_W-1:0]         b_cols_i,
    output wire                         launch_ready_o,
    output reg                          p4_valid_o,
    output reg  [1:0]                   local_row_o,
    output reg  [1:0]                   col_group_o,
    output reg  [4*ACC_W-1:0]           lane0_data_o,
    output reg  [4*ACC_W-1:0]           lane1_data_o,
    output reg  [4*ACC_W-1:0]           lane2_data_o,
    output reg  [4*ACC_W-1:0]           lane3_data_o,
    output wire                         drain_start_o,
    output wire                         packet_done_o,
    output wire                         drain_busy_o,
    output reg                          protocol_error_o
);
    // Retained-panel BRAM output terminates at this local compute boundary.
    reg valid_r;
    reg first_r;
    reg last_r;
    reg [16*DATA_W-1:0] a_rows_r;
    reg [16*DATA_W-1:0] b_cols_r;

    always @(posedge clk) begin
        if (!resetn) begin
            valid_r <= 1'b0;
            first_r <= 1'b0;
            last_r  <= 1'b0;
        end else begin
            valid_r <= valid_i;
            first_r <= valid_i && first_i;
            last_r  <= valid_i && last_i;
        end
        a_rows_r <= a_rows_i;
        b_cols_r <= b_cols_i;
    end

    // A new packet may enter the array every 16 clocks.  K>=16 naturally
    // meets this spacing; the packet backend inserts a gap for short K.
    reg [3:0] launch_spacing_r;
    wire raw_first_fire_w = valid_i && first_i;
    assign launch_ready_o = resetn && (launch_spacing_r == 0);

    wire [4*ACC_W-1:0] tile_row_data_w [0:3][0:3];
    wire [3:0] tile_row_complete_w [0:3][0:3];
    wire tile_complete_w [0:3][0:3];

    reg drain_active_r;
    reg [3:0] drain_step_r;
    wire [1:0] drain_local_row_w = drain_step_r[3:2];
    wire [1:0] drain_col_group_w = drain_step_r[1:0];

    genvar tr;
    genvar tc;
    generate
        for (tr=0; tr<4; tr=tr+1) begin : G_TILE_ROW
            for (tc=0; tc<4; tc=tc+1) begin : G_TILE_COL
                npu_g1_tile4x4_capture #(
                    .DATA_W(DATA_W), .ACC_W(ACC_W)
                ) u_tile (
                    .clk(clk), .resetn(resetn),
                    .valid_i(valid_r), .first_i(first_r), .last_i(last_r),
                    .a_rows_i(a_rows_r[tr*4*DATA_W +: 4*DATA_W]),
                    .b_cols_i(b_cols_r[tc*4*DATA_W +: 4*DATA_W]),
                    .drain_local_row_i(drain_local_row_w),
                    .drain_row_data_o(tile_row_data_w[tr][tc]),
                    .row_complete_o(tile_row_complete_w[tr][tc]),
                    .tile_complete_o(tile_complete_w[tr][tc])
                );
            end
        end
    endgenerate

    // All 4x4 tiles have identical phase.  Exposing this early marker lets the
    // packet backend prefetch only the narrow packet context one cycle before
    // the first registered P4-striped output appears.
    wire row0_start_w = tile_row_complete_w[0][0][0];
    wire drain_last_w = drain_active_r && (drain_step_r == 4'd15);
    assign drain_start_o = resetn && row0_start_w;

    function automatic [4*ACC_W-1:0] select_tile_col;
        input [1:0] col_group;
        input [4*ACC_W-1:0] col0;
        input [4*ACC_W-1:0] col1;
        input [4*ACC_W-1:0] col2;
        input [4*ACC_W-1:0] col3;
        begin
            case (col_group)
                2'd0: select_tile_col = col0;
                2'd1: select_tile_col = col1;
                2'd2: select_tile_col = col2;
                default: select_tile_col = col3;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            launch_spacing_r <= 0;
            drain_active_r <= 1'b0;
            drain_step_r <= 0;
            p4_valid_o <= 1'b0;
            local_row_o <= 0;
            col_group_o <= 0;
            protocol_error_o <= 1'b0;
        end else begin
            // Four local 128-bit registers are the only wide output boundary.
            p4_valid_o <= drain_active_r;
            if (drain_active_r) begin
                local_row_o <= drain_local_row_w;
                col_group_o <= drain_col_group_w;
                lane0_data_o <= select_tile_col(drain_col_group_w,
                    tile_row_data_w[0][0], tile_row_data_w[0][1],
                    tile_row_data_w[0][2], tile_row_data_w[0][3]);
                lane1_data_o <= select_tile_col(drain_col_group_w,
                    tile_row_data_w[1][0], tile_row_data_w[1][1],
                    tile_row_data_w[1][2], tile_row_data_w[1][3]);
                lane2_data_o <= select_tile_col(drain_col_group_w,
                    tile_row_data_w[2][0], tile_row_data_w[2][1],
                    tile_row_data_w[2][2], tile_row_data_w[2][3]);
                lane3_data_o <= select_tile_col(drain_col_group_w,
                    tile_row_data_w[3][0], tile_row_data_w[3][1],
                    tile_row_data_w[3][2], tile_row_data_w[3][3]);
            end

            if (raw_first_fire_w)
                launch_spacing_r <= 4'd15;
            else if (launch_spacing_r != 0)
                launch_spacing_r <= launch_spacing_r - 1'b1;

            // Step 15 of the old packet and row0 capture of the new packet may
            // coincide.  The registered P4 boundary preserves both events.
            if (row0_start_w) begin
                if (!drain_active_r || drain_last_w) begin
                    drain_active_r <= 1'b1;
                    drain_step_r <= 4'd0;
                end else begin
                    protocol_error_o <= 1'b1;
                end
            end else if (drain_active_r) begin
                if (drain_last_w) begin
                    drain_active_r <= 1'b0;
                    drain_step_r <= 4'd0;
                end else begin
                    drain_step_r <= drain_step_r + 1'b1;
                end
            end

            if (raw_first_fire_w && !launch_ready_o)
                protocol_error_o <= 1'b1;
        end
    end

    assign drain_busy_o = drain_active_r;
    assign packet_done_o = p4_valid_o && (local_row_o == 2'd3) &&
                           (col_group_o == 2'd3);

    // synthesis translate_off
    integer ar;
    integer ac;
    always @(posedge clk) if (resetn) begin
        for (ar=0; ar<4; ar=ar+1)
            for (ac=0; ac<4; ac=ac+1) begin
                if (tile_row_complete_w[ar][ac] !== tile_row_complete_w[0][0])
                    $fatal(1,"S2-N1 tile row-complete phase mismatch tr=%0d tc=%0d",ar,ac);
                if (tile_complete_w[ar][ac] !== tile_complete_w[0][0])
                    $fatal(1,"S2-N1 tile completion phase mismatch tr=%0d tc=%0d",ar,ac);
            end
    end
    // synthesis translate_on
endmodule
