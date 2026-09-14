// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
module tb_feature_transport_pack;
parameter integer TRANSPORT_W=64;localparam EW=TRANSPORT_W+TRANSPORT_W/8+51;
reg  clk;
reg  resetn;
reg  s_valid_i;
wire  s_ready_o;
reg [31:0] s_data_i;
reg [3:0] s_keep_i;
reg [48:0] s_meta_i;
reg  s_error_i;
reg  s_last_i;
wire  m_valid_o;
reg  m_ready_i;
wire [TRANSPORT_W-1:0] m_data_o;
wire [TRANSPORT_W/8-1:0] m_keep_o;
wire [48:0] m_meta_o;
wire  m_error_o;
wire  m_last_o;
wire  busy_o;
    npu_v13_feature_transport_pack #(.TRANSPORT_W(TRANSPORT_W)) dut(.*);
    initial clk=0;always #2.5 clk=~clk;
    integer cycle=0,wp=0,rp=0,holds=0,accepted=0;reg gate=1,held=0;
    reg [EW-1:0] expected[0:1023],saved;
    always @* m_ready_i=resetn && gate && cycle%11<6;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(!resetn)held=0;
        else begin
            if(held && (!m_valid_o || {m_last_o,m_error_o,m_meta_o,m_keep_o,m_data_o}!==saved))$fatal(1,"PACK held output changed");
            held=m_valid_o && !m_ready_i;saved={m_last_o,m_error_o,m_meta_o,m_keep_o,m_data_o};if(held)holds=holds+1;
            if(s_valid_i && s_ready_o)accepted=accepted+1;
            if(m_valid_o && m_ready_i)begin
                if(rp==wp || {m_last_o,m_error_o,m_meta_o,m_keep_o,m_data_o}!==expected[rp])$fatal(1,"PACK golden mismatch index=%0d actual=%h expected=%h",rp,{m_last_o,m_error_o,m_meta_o,m_keep_o,m_data_o},expected[rp]);
                rp=rp+1;
            end
        end
    end
    function automatic [7:0] val(input integer m,n);val=m*19+n*7+3;endfunction
    task automatic row(input integer m,bytes,corrupt,inject_error);
        reg [TRANSPORT_W-1:0] data;reg [TRANSPORT_W/8-1:0] keep;reg [48:0] meta;reg e;
        begin
            for(integer n=0;n<bytes;n=n+TRANSPORT_W/8)begin
                data=0;keep=0;meta={1'b0,16'h2345,m[15:0],n[15:0]};
                for(integer b=0;b<TRANSPORT_W/8;b=b+1)if(n+b<bytes)begin data[b*8+:8]=val(m,n+b);keep[b]=1;end
                e=(n==0 && (corrupt!=0 || inject_error!=0));
                expected[wp]={n+TRANSPORT_W/8>=bytes,e,meta,keep,data};wp=wp+1;
            end
            for(integer n=0;n<bytes;n=n+4)begin
                @(negedge clk);s_valid_i=1;s_data_i=32'hffffffff;s_keep_i=0;s_error_i=(n==0 && inject_error!=0);
                s_meta_i={1'b0,16'h2345,m[15:0],n[15:0]};if(corrupt && n==4)s_meta_i[15:0]=12;
                s_last_i=(n+4>=bytes);
                for(integer b=0;b<4;b=b+1)if(n+b<bytes)begin s_data_i[b*8+:8]=val(m,n+b);s_keep_i[b]=1;end
                do @(posedge clk);while(!s_ready_o);
            end
            @(negedge clk);s_valid_i=0;
        end
    endtask
    task automatic rst;
        begin @(negedge clk);resetn=0;s_valid_i=0;rp=wp;repeat(3)@(negedge clk);resetn=1;repeat(2)@(negedge clk);
            if(m_valid_o || busy_o)$fatal(1,"PACK reset leaked partial/output");end
    endtask
    initial begin
        resetn=0;s_valid_i=0;s_data_i=0;s_keep_i=0;s_meta_i=0;s_error_i=0;s_last_i=0;
        rst();
        for(integer len=1;len<=35;len=len+1)row(len,len,0,0);
        row(42,8,1,0);row(43,8,0,1);wait(rp==wp);@(negedge clk);
        // 重置一个只收了首P4、没有last的半字；不允许与下一任务拼接。
        s_valid_i=1;s_data_i=32'hdeadbeef;s_keep_i=15;s_last_i=0;s_meta_i=0;
        do @(posedge clk);while(!s_ready_o);@(negedge clk);s_valid_i=0;rst();
        gate=0;row(44,3,0,0);wait(m_valid_o);repeat(7)@(negedge clk);rst();gate=1;
        row(45,19,0,0);wait(rp==wp);repeat(5)@(negedge clk);
        if(holds==0 || busy_o)$fatal(1,"PACK coverage/drain mismatch");
        $display("FEATURE_TRANSPORT_PACK_PASS width=%0d accepted=%0d output_index=%0d held=%0d",TRANSPORT_W,accepted,rp,holds);$finish;
    end
    initial begin #200000;$fatal(1,"PACK TIMEOUT");end
endmodule
