// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// G1-S0 physical 4x4 compute block.
//
// This is deliberately not an autonomous packet/result protocol domain.  The
// tile only contains the local 4x4 systolic datapath, the boundary skew, and one
// physical completion latch per PE.  All 16 tiles are launched by one global
// context and are drained by one deterministic controller in the parent.
module npu_g1_tile4x4_capture #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W  = 32
) (
    input  wire                         clk,
    input  wire                         resetn,
    input  wire                         valid_i,
    input  wire                         first_i,
    input  wire                         last_i,
    input  wire [4*DATA_W-1:0]          a_rows_i,
    input  wire [4*DATA_W-1:0]          b_cols_i,
    input  wire [1:0]                   drain_local_row_i,
    output reg  [4*ACC_W-1:0]           drain_row_data_o,
    output wire [3:0]                   row_complete_o,
    output wire                         tile_complete_o
);
    // Boundary skew makes A[row,k] and B[k,col] meet in PE(row,col).
    reg signed [DATA_W-1:0] a_skew_r [0:3][0:2];
    reg signed [DATA_W-1:0] b_skew_r [0:3][0:2];

    // One shared local wavefront, not a per-result ready/credit protocol.
    reg [5:0] valid_delay_r;
    reg [5:0] first_delay_r;
    reg [5:0] last_delay_r;

    wire signed [DATA_W-1:0] a_link_w [0:3][0:3];
    wire signed [17:0] b_cascade_link_w [0:3][0:3];
    wire signed [ACC_W-1:0] pe_result_w [0:3][0:3];
    wire pe_result_valid_w [0:3][0:3];

    // Exactly one local result-holding word per PE.  There is no descriptor,
    // tag, reserve pointer, ready tree, or second matrix payload.
    (* ram_style="registers" *) reg signed [ACC_W-1:0] completion_r [0:15];

    integer row_i;
    integer col_i;
    integer delay_i;
    integer cap_i;

    always @(posedge clk) begin
        for (row_i=1; row_i<4; row_i=row_i+1) begin
            a_skew_r[row_i][0] <= a_rows_i[row_i*DATA_W +: DATA_W];
            for (delay_i=1; delay_i<row_i; delay_i=delay_i+1)
                a_skew_r[row_i][delay_i] <= a_skew_r[row_i][delay_i-1];
        end
        for (col_i=1; col_i<4; col_i=col_i+1) begin
            b_skew_r[col_i][0] <= b_cols_i[col_i*DATA_W +: DATA_W];
            for (delay_i=1; delay_i<col_i; delay_i=delay_i+1)
                b_skew_r[col_i][delay_i] <= b_skew_r[col_i][delay_i-1];
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            valid_delay_r <= 6'b0;
            first_delay_r <= 6'b0;
            last_delay_r  <= 6'b0;
        end else begin
            valid_delay_r <= {valid_delay_r[4:0], valid_i};
            first_delay_r <= {first_delay_r[4:0], valid_i && first_i};
            last_delay_r  <= {last_delay_r[4:0], valid_i && last_i};
        end
    end

    genvar rg;
    genvar cg;
    generate
        for (rg=0; rg<4; rg=rg+1) begin : G_ROW
            for (cg=0; cg<4; cg=cg+1) begin : G_COL
                localparam integer WAVE_DELAY = rg+cg;
                wire signed [DATA_W-1:0] pe_a_w;
                wire signed [DATA_W-1:0] pe_b_w;
                wire signed [17:0] pe_b_cascade_w;
                wire pe_valid_w;
                wire pe_first_w;
                wire pe_last_w;

                if (cg == 0) begin : G_A_BOUNDARY
                    if (rg == 0)
                        assign pe_a_w = a_rows_i[rg*DATA_W +: DATA_W];
                    else
                        assign pe_a_w = a_skew_r[rg][rg-1];
                end else begin : G_A_FORWARD
                    assign pe_a_w = a_link_w[rg][cg-1];
                end

                if (rg == 0) begin : G_B_BOUNDARY
                    assign pe_b_cascade_w = 18'b0;
                    if (cg == 0)
                        assign pe_b_w = b_cols_i[cg*DATA_W +: DATA_W];
                    else
                        assign pe_b_w = b_skew_r[cg][cg-1];
                end else begin : G_B_CASCADE
                    assign pe_b_w = {DATA_W{1'b0}};
                    assign pe_b_cascade_w = b_cascade_link_w[rg-1][cg];
                end

                if (WAVE_DELAY == 0) begin : G_CTL_DIRECT
                    assign pe_valid_w = valid_i;
                    assign pe_first_w = valid_i && first_i;
                    assign pe_last_w  = valid_i && last_i;
                end else begin : G_CTL_DELAY
                    assign pe_valid_w = valid_delay_r[WAVE_DELAY-1];
                    assign pe_first_w = first_delay_r[WAVE_DELAY-1];
                    assign pe_last_w  = last_delay_r[WAVE_DELAY-1];
                end

                npu_v13_systolic_pe_stream #(
                    .DATA_W(DATA_W), .ACC_W(ACC_W),
                    .USE_B_CASCADE(rg != 0)
                ) u_pe (
                    .clk(clk), .resetn(resetn),
                    .valid_i(pe_valid_w), .init_i(pe_first_w),
                    .last_i(pe_last_w), .a_i(pe_a_w), .b_i(pe_b_w),
                    .b_cascade_i(pe_b_cascade_w),
                    .b_cascade_o(b_cascade_link_w[rg][cg]),
                    .a_o(a_link_w[rg][cg]), .acc_o(),
                    .result_valid_o(pe_result_valid_w[rg][cg]),
                    .result_o(pe_result_w[rg][cg])
                );
            end
        end
    endgenerate

    // Capture each PE exactly when its post-MAC final value is valid.  Distributed
    // arrival time is useful: the global drain can start three clocks before the
    // farthest PE completes instead of waiting for a whole-matrix rendezvous.
    always @(posedge clk) begin
        for (cap_i=0; cap_i<16; cap_i=cap_i+1)
            if (pe_result_valid_w[cap_i/4][cap_i%4])
                completion_r[cap_i] <= pe_result_w[cap_i/4][cap_i%4];
    end

    // Local row read is purely positional.  The parent registers the selected
    // row before a BRAM write, so this mux never drives a global matrix bus.
    always @* begin
        case (drain_local_row_i)
            2'd0: drain_row_data_o = {completion_r[3], completion_r[2],
                                      completion_r[1], completion_r[0]};
            2'd1: drain_row_data_o = {completion_r[7], completion_r[6],
                                      completion_r[5], completion_r[4]};
            2'd2: drain_row_data_o = {completion_r[11], completion_r[10],
                                      completion_r[9], completion_r[8]};
            default: drain_row_data_o = {completion_r[15], completion_r[14],
                                         completion_r[13], completion_r[12]};
        endcase
    end

    // In each local row, col=3 is the last PE to complete.  These pulses are
    // deterministic phase markers, not handshake signals.
    assign row_complete_o[0] = pe_result_valid_w[0][3];
    assign row_complete_o[1] = pe_result_valid_w[1][3];
    assign row_complete_o[2] = pe_result_valid_w[2][3];
    assign row_complete_o[3] = pe_result_valid_w[3][3];
    assign tile_complete_o   = pe_result_valid_w[3][3];
endmodule
