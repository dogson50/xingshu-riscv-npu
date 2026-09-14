// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p12独立事务oracle：只按已握手beat形成期望队列，不读取DUT内部寄存器。
module tb_load_validated_beat;
 parameter integer W=64;
 localparam integer DEPTH=13,AW=$clog2(DEPTH),TAW=AW+(W==64),BW=TAW+W+2;
 reg clk=0;always #5 clk=~clk;
 reg resetn=0,bv=0,bo=0,bb=0,sv=0,so=0,sb=0,fv=0,fo=0,fb=0,fi=0;
 reg [TAW-1:0] sa=0;reg [W-1:0] sd=0;reg [W/8-1:0] sk=0;
 reg mr=1,mfr=1,random_stall=0;reg [31:0] rng=32'h910bc431;
 wire br,be,sr,fr,fe,mbv,mbo,mbb,mv,mo,mb,mfv,mfo,mfb,mfi,busy;
 wire [TAW-1:0] ma;wire [W-1:0] md;
 npu_v13_panel_load_narrow #(.TRANSPORT_W(W),.DEPTH(DEPTH)) dut(
 .clk(clk),.resetn(resetn),.s_begin_valid_i(bv),.s_begin_ready_o(br),.s_begin_error_o(be),.s_begin_operand_i(bo),.s_begin_bank_i(bb),
 .s_valid_i(sv),.s_ready_o(sr),.s_operand_i(so),.s_bank_i(sb),.s_addr_i(sa),.s_data_i(sd),.s_keep_i(sk),
 .s_finish_valid_i(fv),.s_finish_ready_o(fr),.s_finish_error_o(fe),.s_finish_operand_i(fo),.s_finish_bank_i(fb),.s_finish_error_i(fi),
 .m_begin_valid_o(mbv),.m_begin_ready_i(1'b1),.m_begin_error_i(1'b0),.m_begin_operand_o(mbo),.m_begin_bank_o(mbb),
 .m_valid_o(mv),.m_ready_i(mr),.m_operand_o(mo),.m_bank_o(mb),.m_addr_o(ma),.m_data_o(md),
 .m_finish_valid_o(mfv),.m_finish_ready_i(mfr),.m_finish_error_i(1'b0),.m_finish_operand_o(mfo),.m_finish_bank_o(mfb),.m_finish_error_o(mfi),.busy_o(busy));
 reg [BW-1:0] queue[0:16383];integer head=0,tail=0,qcount=0;
 integer session_target=0,expected_high=-1;
 bit session_active=0,session_bad=0;
 integer accepted=0,delivered=0,invalids=0,stalls=0,simultaneous=0,fenced=0,wrong_finish=0,dropped=0,resets=0;
 reg [W-1:0] expected_data;bit legal,wrong;
 always @(negedge clk) if(random_stall)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=(rng[2:0]!=0);end
 always @(posedge clk)begin
  if(!resetn)begin dropped=dropped+qcount;head=0;tail=0;qcount=0;session_active=0;session_bad=0;expected_high=-1;end
  else begin
   if(mv!==(qcount!=0))$fatal(1,"VALIDATED registered valid mismatch q=%0d valid=%b",qcount,mv);
   if(mv && {mo,mb,ma,md}!==queue[head])$fatal(1,"VALIDATED payload/order mismatch");
   wrong=!session_active || {fo,fb}!=session_target;
   if(fv && !wrong && qcount!=0)begin
    if(fr || mfv)$fatal(1,"VALIDATED finish crossed pending beat");fenced=fenced+1;
   end
   if(sv && !sr)stalls=stalls+1;
   if(sv && sr && mv && mr)simultaneous=simultaneous+1;
   if(mv && mr)begin head=head+1;qcount=qcount-1;delivered=delivered+1;end
   if(bv && br && !be)begin
    if(session_active || qcount)$fatal(1,"VALIDATED begin crossed live session");
    session_active=1;session_target={bo,bb};session_bad=0;expected_high=-1;
   end
   if(sv && sr)begin
    if(!session_active)$fatal(1,"VALIDATED input outside session");
    accepted=accepted+1;legal=!session_bad && ({so,sb}==session_target) && (sa<DEPTH*(128/W));
    if(W==64)begin
     if(expected_high<0)legal=legal && (sa%2==0);
     else legal=legal && (sa==expected_high);
    end
    if(legal)begin
     if(W==64)begin if(expected_high<0)expected_high=sa+1;else expected_high=-1;end
     expected_data=0;for(integer b=0;b<W/8;b=b+1)if(sk[b])expected_data[b*8+:8]=sd[b*8+:8];
     queue[tail]={so,sb,sa,expected_data};tail=tail+1;qcount=qcount+1;
     if(qcount>1)$fatal(1,"VALIDATED overflow");
    end else begin session_bad=1;expected_high=-1;invalids=invalids+1;end
   end
   if(fv && fr)begin
    if(fe!==(wrong || session_bad || expected_high>=0))$fatal(1,"VALIDATED finish error mismatch");
    if(wrong)begin wrong_finish=wrong_finish+1;if(mfv)$fatal(1,"VALIDATED wrong finish forwarded");end
    else begin
     if(qcount || !mfv || !mfr || {mfo,mfb}!=session_target || mfi!==(fi || session_bad || expected_high>=0))$fatal(1,"VALIDATED finish fence/identity/error");
     session_active=0;session_bad=0;expected_high=-1;
    end
   end
  end
 end
 task automatic restart;
 begin @(negedge clk);resetn=0;sv=0;bv=0;fv=0;random_stall=0;repeat(3)@(negedge clk);resetn=1;resets=resets+1;repeat(2)@(negedge clk);if(busy || mv)$fatal(1,"VALIDATED reset leaked state");end endtask
 task automatic start(input integer p);
 begin @(negedge clk);bv=1;bo=p/2;bb=p%2;do @(posedge clk);while(!br);@(negedge clk);bv=0;end endtask
 task automatic beat(input integer p,a,seed);
 begin @(negedge clk);sv=1;so=p/2;sb=p%2;sa=a;
 for(integer b=0;b<W/8;b=b+1)begin sd[b*8+:8]=seed*37+b*19;sk[b]=((b+seed)%5!=0);end
 do @(posedge clk);while(!sr);end endtask
 task automatic finish(input integer p,input bit cancel);
 begin @(negedge clk);sv=0;fv=1;fo=p/2;fb=p%2;fi=cancel;do @(posedge clk);while(!fr);@(negedge clk);fv=0;fi=0;end endtask
 initial begin
  #160;restart();mr=1;
  start(0);for(integer h=0;h<128/W;h=h+1)beat(0,h,10+h);
  @(negedge clk);sv=0;mr=0;fv=1;fo=0;fb=0;
  repeat(12)@(posedge clk);
  // pending期间错误目标finish只报错，保持原beat与会话；随后真正finish仍须等下游放行。
  @(negedge clk);fb=1;@(posedge clk);if(!fr || !fe)$fatal(1,"VALIDATED wrong finish blocked");
  @(negedge clk);fb=0;repeat(6)@(posedge clk);
  // 乱改未握手输入，不得组合穿透已登记载荷/valid。
  @(negedge clk);sa='1;sd='1;sk=0;#1;if(!mv || {mo,mb,ma,md}!==queue[head])$fatal(1,"VALIDATED forward combinational leak");
  mr=1;do @(posedge clk);while(!fr);@(negedge clk);fv=0;
  start(1);mr=0;beat(1,0,40);@(negedge clk);so=0;sb=0;sa=1;sd=0; // wrong target held behind pending
  repeat(6)begin @(posedge clk);if(sr)$fatal(1,"VALIDATED overwritten pending");end
  @(negedge clk);mr=1;do @(posedge clk);while(!sr);finish(1,0);
  start(2);mr=0;beat(2,0,90);restart();mr=1;
  for(integer job=0;job<40;job=job+1)begin
   start(job%4);random_stall=1;
   for(integer word=0;word<72;word=word+1)begin
    for(integer h=0;h<128/W;h=h+1)beat(job%4,(word%DEPTH)*(128/W)+h,job*211+word*3+h);
   end
   if(job%5==0)begin beat((job+1)%4,0,1);beat(job%4,0,2);end
   finish(job%4,job%7==0);
  end
  random_stall=0;mr=1;repeat(5)@(negedge clk);
  if(busy || mv || qcount || session_active || accepted!=delivered+invalids+dropped || invalids!=17 || dropped!=1 || fenced<18 || wrong_finish!=1 || simultaneous<1000 || stalls<20)$fatal(1,"VALIDATED coverage missing a=%0d d=%0d i=%0d drop=%0d sim=%0d",accepted,delivered,invalids,dropped,simultaneous);
  $display("VALIDATED_BEAT_PASS width=%0d accepted=%0d delivered=%0d invalids=%0d dropped=%0d stalls=%0d simultaneous=%0d fenced=%0d wrong_finish=%0d resets=%0d",W,accepted,delivered,invalids,dropped,stalls,simultaneous,fenced,wrong_finish,resets);$finish;
 end
 initial begin #1000000;$fatal(1,"VALIDATED TIMEOUT");end
endmodule
