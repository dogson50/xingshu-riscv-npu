// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
module tb_panel_load_transport;
parameter integer TRANSPORT_W=64;localparam DEPTH=5,AW=3,TAW=AW+(TRANSPORT_W==64);
reg  clk;
reg  resetn;
reg  s_begin_valid_i;
wire  s_begin_ready_o;
wire  s_begin_error_o;
reg  s_begin_operand_i;
reg  s_begin_bank_i;
reg  s_valid_i;
wire  s_ready_o;
reg  s_operand_i;
reg  s_bank_i;
reg [TAW-1:0] s_addr_i;
reg [TRANSPORT_W-1:0] s_data_i;
reg [TRANSPORT_W/8-1:0] s_keep_i;
reg  s_finish_valid_i;
wire  s_finish_ready_o;
wire  s_finish_error_o;
reg  s_finish_operand_i;
reg  s_finish_bank_i;
reg  s_finish_error_i;
wire  m_begin_valid_o;
reg  m_begin_ready_i;
reg  m_begin_error_i;
wire  m_begin_operand_o;
wire  m_begin_bank_o;
wire  m_valid_o;
reg  m_ready_i;
wire  m_operand_o;
wire  m_bank_o;
wire [AW-1:0] m_addr_o;
wire [127:0] m_data_o;
wire  m_finish_valid_o;
reg  m_finish_ready_i;
reg  m_finish_error_i;
wire  m_finish_operand_o;
wire  m_finish_bank_o;
wire  m_finish_error_o;
wire  busy_o;
    npu_v13_panel_load_transport #(.TRANSPORT_W(TRANSPORT_W),.DEPTH(DEPTH),.AW(AW)) dut(.*);
    initial clk=0;always #2.5 clk=~clk;
    integer cycles=0,writes=0,finishes=0,cancels=0,delay_count=0,held_cycles=0;
    reg gate=1,held=0;reg [AW+129:0] saved;reg [127:0] mem[0:DEPTH-1];
    always @* begin m_ready_i=resetn && gate && cycles%7<3;m_finish_ready_i=resetn && delay_count==0 && !m_valid_o;end
    always @(posedge clk)begin
        cycles=cycles+1;
        if(!resetn)begin delay_count=0;held=0;end
        else begin
            if(delay_count>0)delay_count=delay_count-1;
            if(held && (!m_valid_o || {m_operand_o,m_bank_o,m_addr_o,m_data_o}!==saved))$fatal(1,"LOAD held output changed");
            held=m_valid_o && !m_ready_i;saved={m_operand_o,m_bank_o,m_addr_o,m_data_o};if(held)held_cycles=held_cycles+1;
            if(m_valid_o && m_ready_i)begin mem[m_addr_o]=m_data_o;writes=writes+1;delay_count=4;end
            if(m_finish_valid_o && m_finish_ready_i)begin finishes=finishes+1;if(m_finish_error_o)cancels=cancels+1;end
            if(s_finish_valid_i && s_finish_ready_o && !s_finish_error_o && !s_finish_error_i && delay_count!=0)$fatal(1,"LOAD finish before visible");
        end
    end
    task automatic start(input integer op,b);
        begin @(negedge clk);s_begin_valid_i=1;s_begin_operand_i=op;s_begin_bank_i=b;
            do @(posedge clk);while(!s_begin_ready_o);if(s_begin_error_o)$fatal(1,"LOAD begin rejected");
            @(negedge clk);s_begin_valid_i=0;s_operand_i=op;s_bank_i=b;s_finish_operand_i=op;s_finish_bank_i=b;end
    endtask
    task automatic beat(input integer addr,input [TRANSPORT_W-1:0] data,input [TRANSPORT_W/8-1:0] keep);
        begin @(negedge clk);s_valid_i=1;s_addr_i=addr;s_data_i=data;s_keep_i=keep;
            do @(posedge clk);while(!s_ready_o);@(negedge clk);s_valid_i=0;end
    endtask
    task automatic word(input integer addr,input [127:0] data,input [15:0] keep);
        begin for(integer h=0;h<128/TRANSPORT_W;h=h+1)beat(addr*(128/TRANSPORT_W)+h,data[h*TRANSPORT_W+:TRANSPORT_W],keep[h*(TRANSPORT_W/8)+:TRANSPORT_W/8]);end
    endtask
    task automatic finish(input integer err,abort_now);
        begin @(negedge clk);s_finish_valid_i=1;s_finish_error_i=abort_now;
            do @(posedge clk);while(!s_finish_ready_o);if(s_finish_error_o!==err[0])$fatal(1,"LOAD finish error mismatch got=%b expected=%b",s_finish_error_o,err[0]);
            @(negedge clk);s_finish_valid_i=0;s_finish_error_i=0;end
    endtask
    task automatic rst;
        begin @(negedge clk);resetn=0;s_valid_i=0;s_begin_valid_i=0;s_finish_valid_i=0;repeat(3)@(negedge clk);resetn=1;
            repeat(3)@(negedge clk);if(m_valid_o || busy_o)$fatal(1,"LOAD reset leaked output/session");end
    endtask
    integer base;
    initial begin
        resetn=0;s_begin_valid_i=0;s_begin_operand_i=0;s_begin_bank_i=0;s_valid_i=0;s_operand_i=0;s_bank_i=0;
        s_addr_i=0;s_data_i=0;s_keep_i=0;s_finish_valid_i=0;s_finish_operand_i=0;s_finish_bank_i=0;s_finish_error_i=0;
        m_begin_ready_i=1;m_begin_error_i=0;m_finish_error_i=0;
        rst();start(0,1);
        word(0,128'hffeeddccbbaa99887766554433221100,16'h00ff);
        word(4,128'h0123456789abcdeffedcba9876543210,16'hffff);finish(0,0);
        if(mem[0]!==128'h00000000000000007766554433221100 || mem[4]!==128'h0123456789abcdeffedcba9876543210 || writes!=2)$fatal(1,"LOAD data/address/keep mismatch");
        start(1,0);beat(DEPTH*(128/TRANSPORT_W),0,'1);finish(1,0);if(writes!=2)$fatal(1,"LOAD illegal address wrote memory");
        start(0,0);s_operand_i=1;beat(0,'1,'1);finish(1,0);if(writes!=2)$fatal(1,"LOAD wrong bank wrote memory");
        start(1,1);s_finish_bank_i=0;finish(1,0);if(!busy_o)$fatal(1,"LOAD wrong finish ended real session");s_finish_bank_i=1;
        word(1,128'hdeadbeef123456789abcdef0a5a5a5a5,16'hffff);finish(0,0);
        start(0,1);s_begin_valid_i=1;repeat(3)begin @(negedge clk);if(s_begin_ready_o)$fatal(1,"LOAD overlapping session accepted");end s_begin_valid_i=0;finish(0,1);
        if(TRANSPORT_W==64)begin
            start(0,0);beat(0,64'h1234,8'hff);finish(1,0);
            start(1,0);beat(1,64'h1234,8'hff);finish(1,0);
            start(1,0);beat(0,64'h1234,8'hff);beat(3,64'h5678,8'hff);finish(1,0);
            start(0,0);beat(0,64'hbeef,8'hff);rst();
        end
        start(0,0);gate=0;word(2,128'hfedcba98765432100123456789abcdef,16'hffff);
        wait(m_valid_o);repeat(5)@(negedge clk);base=writes;rst();gate=1;if(writes!=base)$fatal(1,"LOAD reset committed blocked word");
        start(1,1);word(2,128'h123456789abcdef0fedcba9876543210,16'hffff);finish(0,0);
        if(mem[2]!==128'h123456789abcdef0fedcba9876543210 || held_cycles==0 || cancels<3)$fatal(1,"LOAD recovery/coverage mismatch");
        $display("PANEL_LOAD_TRANSPORT_PASS width=%0d writes=%0d finishes=%0d cancels=%0d held=%0d",TRANSPORT_W,writes,finishes,cancels,held_cycles);$finish;
    end
    initial begin #100000;$fatal(1,"LOAD TIMEOUT");end
endmodule
