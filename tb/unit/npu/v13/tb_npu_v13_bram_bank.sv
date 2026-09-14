// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 用端口初始化，参考存储体只用于评分；同时验证不同深度/读延迟。
module bram_bank_checker #(parameter LAT=2, DEPTH=13, AW=4)(output reg done=0);
    reg clk=0,resetn=0,wv=0,rv=0;
    reg [AW-1:0] wa=0,ra=0; reg [31:0] wd=0; reg [7:0] tag=0;
    wire wr,rr,we,qv,qe; wire [31:0] qd; wire [7:0] qt;
    npu_v13_bram_bank #(.DEPTH(DEPTH),.ADDR_W(AW),.READ_LATENCY(LAT)) dut(
        .clk(clk),.resetn(resetn),.wr_valid_i(wv),.wr_ready_o(wr),.wr_addr_i(wa),.wr_data_i(wd),.wr_error_o(we),
        .rd_valid_i(rv),.rd_ready_o(rr),.rd_addr_i(ra),.rd_tag_i(tag),
        .rd_rsp_valid_o(qv),.rd_rsp_data_o(qd),.rd_rsp_tag_o(qt),.rd_rsp_error_o(qe));
    always #5 clk=~clk;
    reg [31:0] reference_mem[0:DEPTH-1];
    reg pv=0,pe=0; reg [31:0] pd; reg [7:0] pt;
    reg ev,ee; reg [31:0] ed; reg [7:0] et;
    integer checks=0,reads=0,writes=0,errors=0,runlen=0,maxrun=0;
    task automatic tick(input bit rst,write_v,input integer write_a,input reg [31:0] write_d,
                        input bit read_v,input integer read_a,input reg [7:0] read_tag);
        reg nv,ne; reg [31:0] nd;
        begin
            @(negedge clk); resetn=rst;wv=write_v;wa=write_a;wd=write_d;rv=read_v;ra=read_a;tag=read_tag;
            #1;
            if(wr!==rst || rr!==rst || we!==(rst && write_v && wa>=DEPTH)) $fatal(1,"BRAM request response");
            nv=rst && read_v; ne=(ra>=DEPTH || (rst && write_v && wa<DEPTH && wa==ra));
            nd=0;if(nv && !ne) nd=reference_mem[ra];
            ev=(LAT==1)?nv:pv;ee=(LAT==1)?ne:pe;ed=(LAT==1)?nd:pd;et=(LAT==1)?read_tag:pt;
            if(!rst) ev=0;
            @(posedge clk);
            if(rst && write_v && wa<DEPTH) begin reference_mem[wa]=wd;writes=writes+1;end
            if(nv) begin reads=reads+1;runlen=runlen+1; if(runlen>maxrun) maxrun=runlen;end else runlen=0;
            if(nv && ne) errors=errors+1;
            #1;
            if(qv!==ev) $fatal(1,"BRAM latency valid LAT=%0d DEPTH=%0d cycle=%0d",LAT,DEPTH,checks);
            if(ev && (qt!==et || qe!==ee || (!ee && qd!==ed)))
                $fatal(1,"BRAM response LAT=%0d DEPTH=%0d cycle=%0d data=%h want=%h tag=%h/%h err=%b/%b",LAT,DEPTH,checks,qd,ed,qt,et,qe,ee);
            pv=nv;pe=ne;pd=nd;pt=read_tag;checks=checks+1;
        end
    endtask
    integer i,seed;
    initial begin
        seed=32'h6f175+LAT+DEPTH;
        tick(0,1,0,999,1,0,0);
        for(i=0;i<DEPTH;i=i+1) tick(1,1,i,32'h12560000+i,0,0,0);
        for(i=0;i<DEPTH*3;i=i+1) tick(1,0,0,0,1,i%DEPTH,i);
        // 连续同时读写：证明写端口不会占用读端口；深度 1 时按约定返回冲突错误。
        for(i=0;i<DEPTH*2;i=i+1) tick(1,1,i%DEPTH,32'habc00000+i,1,(i+1)%DEPTH,i);
        tick(1,1,DEPTH-1,32'h12345678,1,DEPTH-1,8'hce); // 同地址：写生效，读报错
        tick(1,0,0,0,1,DEPTH-1,8'hcf);
        tick(1,1,0,32'hdeadbeef,1,DEPTH-1,8'hd0); // 不同地址可并行，DEPTH=1 则冲突
        if(DEPTH<(1<<AW)) begin
            tick(1,1,DEPTH,32'hbad0bad0,1,DEPTH,8'hd1);
            tick(1,0,0,0,1,0,8'hd2);
        end
        for(i=0;i<1000;i=i+1)
            tick(1,($random(seed)&3)!=0,$random(seed),$random(seed),($random(seed)&7)!=0,$random(seed),i);
        // 在尚有 L2 响应时复位，丢弃在途 valid；RAM 内容保留且复位期间不能写。
        tick(1,0,0,0,1,0,8'hf0);
        tick(0,1,0,32'hbad0bad0,1,0,8'hf1);
        tick(0,0,0,0,0,0,0);
        tick(1,0,0,0,1,0,8'hf2);
        tick(1,0,0,0,0,0,0);tick(1,0,0,0,0,0,0);
        if(maxrun<DEPTH*3 || errors==0) $fatal(1,"BRAM throughput/error coverage");
        $display("BRAM_CASE_PASS latency=%0d depth=%0d checks=%0d reads=%0d writes=%0d error_reads=%0d max_consecutive_reads=%0d",LAT,DEPTH,checks,reads,writes,errors,maxrun);
        done=1;
    end
endmodule
module tb_npu_v13_bram_bank;
    wire [3:0] done;
    bram_bank_checker #(.LAT(1)) c0(done[0]);
    bram_bank_checker #(.LAT(2)) c1(done[1]);
    bram_bank_checker #(.LAT(2),.DEPTH(32),.AW(5)) c2(done[2]);
    bram_bank_checker #(.LAT(2),.DEPTH(1),.AW(1)) c3(done[3]);
    initial begin wait(&done); $display("NPU_V13_BRAM_BANK_TB_PASS configurations=4");$finish;end
    initial begin #200000; $fatal(1,"BRAM_TB_TIMEOUT");end
endmodule
