// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// Fair two-input single-slot elastic register. Each local pair absorbs one word.
module merge2_pipe_exp #(parameter integer W=180)(
    input wire clk,resetn,
    input wire [1:0] valid_i,
    output reg [1:0] ready_o,
    input wire [2*W-1:0] data_i,
    output reg valid_o,
    input wire ready_i,
    output reg [W-1:0] data_o
);
    reg rr_r,sel;
    reg found;
    wire can_take=!valid_o || ready_i;

    always @* begin
        found=1'b0;
        sel=rr_r;
        ready_o=2'b00;
        if(valid_i[rr_r]) begin
            found=1'b1;
            sel=rr_r;
        end else if(valid_i[~rr_r]) begin
            found=1'b1;
            sel=~rr_r;
        end
        if(resetn && can_take && found) ready_o[sel]=1'b1;
    end

    always @(posedge clk) begin
        if(!resetn) begin
            valid_o<=1'b0;
            rr_r<=1'b0;
        end else if(can_take) begin
            valid_o<=found;
            if(found) begin
                if(sel) data_o<=data_i[W+:W];
                else    data_o<=data_i[0+:W];
                rr_r<=~sel;
            end
        end
    end
endmodule

// P87-E keeps only two local 181-bit pair slots and removes the third wide stage used by P87-D.
// A final combinational fair 2:1 selector drives the existing BRAM FIFO; pair slots support pop-and-refill.
// Each island still sustains one word/cycle while halving P87-D added payload registers.
module merge4_exp #(parameter integer W=180)(
    input wire clk,resetn,
    input wire [3:0] valid_i,
    output wire [3:0] ready_o,
    input wire [4*W-1:0] data_i,
    output wire valid_o,
    input wire ready_i,
    output wire [W-1:0] data_o
);
    wire [1:0] p_valid;
    reg  [1:0] p_ready;
    wire [W-1:0] p0_data,p1_data;
    wire [1:0] r0,r1;
    reg rr_r,sel,found;

    merge2_pipe_exp #(.W(W)) u_pair01(
        .clk(clk),.resetn(resetn),
        .valid_i(valid_i[1:0]),.ready_o(r0),.data_i(data_i[2*W-1:0]),
        .valid_o(p_valid[0]),.ready_i(p_ready[0]),.data_o(p0_data));
    merge2_pipe_exp #(.W(W)) u_pair23(
        .clk(clk),.resetn(resetn),
        .valid_i(valid_i[3:2]),.ready_o(r1),.data_i(data_i[4*W-1:2*W]),
        .valid_o(p_valid[1]),.ready_i(p_ready[1]),.data_o(p1_data));

    assign ready_o={r1,r0};
    assign valid_o=resetn && found;
    assign data_o=sel ? p1_data : p0_data;

    // Pop only when the BRAM FIFO accepts; selection and payload stay stable under backpressure.
    always @* begin
        found=1'b0;
        sel=rr_r;
        p_ready=2'b00;
        if(p_valid[rr_r]) begin
            found=1'b1;
            sel=rr_r;
        end else if(p_valid[~rr_r]) begin
            found=1'b1;
            sel=~rr_r;
        end
        if(resetn && found && ready_i) p_ready[sel]=1'b1;
    end

    always @(posedge clk) begin
        if(!resetn) rr_r<=1'b0;
        else if(valid_o && ready_i) rr_r<=~sel;
    end
endmodule

