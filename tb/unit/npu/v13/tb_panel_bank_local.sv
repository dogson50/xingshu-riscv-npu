// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 端到端窄口协议+真实四bank RAM+所有权管理器；独立golden数组核对两拍读回。
module tb_panel_bank_local;
 parameter integer W=64,DEPTH=13;
 localparam AW=$clog2(DEPTH),TAW=AW+(W==64);
 reg clk=0;always #5 clk=~clk;
 reg resetn=0,bv=0,bo=0,bb=0,sv=0,so=0,sb=0,fv=0,fo=0,fb=0,fi=0;
 reg [TAW-1:0] sa=0;reg [W-1:0] sd=0;reg [W/8-1:0] sk=0;
 wire br,be,sr,fr,fe,mbv,mbr,mbe,mbo,mbb,mv,mr,mo,mb,mfv,mfr,mfe,mfo,mfb,mfi,busy;
 wire [TAW-1:0] ma;wire [W-1:0] md;wire store_ready;
 reg gate=1,random_stall=0;reg [31:0] rng=32'h31415927;
 reg aq=0,rel=0,ab=0,bbank=0;wire aqr,aqe,relr,ramv,lease,err;
 reg rd=0;reg [AW-1:0] ra=0,rb=0;wire [127:0] qa,qb;
 wire [3:0] retained,loading,inuse;wire [1:0] cf,cu;
 reg dis=0,disop=0,disbank=0;wire disr,dise;
 assign mr=store_ready && gate;
 npu_v13_panel_load_narrow #(.TRANSPORT_W(W),.DEPTH(DEPTH),.AW(AW),.TAW(TAW)) tr(
 .clk(clk),.resetn(resetn),.s_begin_valid_i(bv),.s_begin_ready_o(br),.s_begin_error_o(be),.s_begin_operand_i(bo),.s_begin_bank_i(bb),
 .s_valid_i(sv),.s_ready_o(sr),.s_operand_i(so),.s_bank_i(sb),.s_addr_i(sa),.s_data_i(sd),.s_keep_i(sk),
 .s_finish_valid_i(fv),.s_finish_ready_o(fr),.s_finish_error_o(fe),.s_finish_operand_i(fo),.s_finish_bank_i(fb),.s_finish_error_i(fi),
 .m_begin_valid_o(mbv),.m_begin_ready_i(mbr),.m_begin_error_i(mbe),.m_begin_operand_o(mbo),.m_begin_bank_o(mbb),
 .m_valid_o(mv),.m_ready_i(mr),.m_operand_o(mo),.m_bank_o(mb),.m_addr_o(ma),.m_data_o(md),
 .m_finish_valid_o(mfv),.m_finish_ready_i(mfr),.m_finish_error_i(mfe),.m_finish_operand_o(mfo),.m_finish_bank_o(mfb),.m_finish_error_o(mfi),.busy_o(busy));
 npu_v13_managed_panel_store #(.LOAD_W(W),.MAX_MN(16),.MAX_K(DEPTH),.DEPTH(DEPTH),.AW(AW)) store(
 .clk(clk),.resetn(resetn),.load_begin_valid_i(mbv),.load_begin_ready_o(mbr),.load_begin_error_o(mbe),.load_begin_operand_i(mbo),.load_begin_bank_i(mbb),
 .load_valid_i(mv && gate),.load_ready_o(store_ready),.load_operand_i(mo),.load_bank_i(mb),.load_addr_i(ma),.load_data_i(md),
 .load_finish_valid_i(mfv),.load_finish_ready_o(mfr),.load_finish_error_o(mfe),.load_finish_operand_i(mfo),.load_finish_bank_i(mfb),.load_finish_error_i(mfi),
 .discard_valid_i(dis),.discard_ready_o(disr),.discard_error_o(dise),.discard_operand_i(disop),.discard_bank_i(disbank),
 .acquire_valid_i(aq),.acquire_ready_o(aqr),.acquire_error_o(aqe),.release_valid_i(rel),.release_ready_o(relr),.release_error_i(1'b0),
 .req_a_bank_i(ab),.req_b_bank_i(bbank),.req_c_bank_i(1'b0),.req_tag_i(16'h1234),.rd_valid_i(rd),.rd_a_addr_i(ra),.rd_b_addr_i(rb),
 .ram_valid_o(ramv),.ram_a_o(qa),.ram_b_o(qb),.retained_o(retained),.loading_o(loading),.in_use_o(inuse),.c_free_o(cf),.c_in_use_o(cu),.lease_active_o(lease),.error_o(err));
 reg [127:0] gold[0:3][0:DEPTH-1];reg [127:0] eqa[0:1],eqb[0:1];reg [1:0] ev=0;
 integer accepted=0,narrow=0,writes=0,reads=0,stalls=0,fences=0,errors=0,resets=0,fullrate=0,prev=-10,cycle=0;
 reg mh=0;reg [W+TAW+1:0] held;
 always @(negedge clk)begin
  rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  gate<=!random_stall || rng[1:0]!=0;
 end
 always @(posedge clk) begin
  cycle=cycle+1;
  if(!resetn)begin ev=0;mh=0;end
  else begin
   if(err)$fatal(1,"LOCAL manager error");
   if(sv && sr)begin accepted=accepted+1;if(prev==cycle-1)fullrate=fullrate+1;prev=cycle;end
   if(mv && mr)narrow=narrow+1;
   if(sv && !sr)stalls=stalls+1;
   if(fv && !fr)fences=fences+1;
   if(fv && fr && fe)errors=errors+1;
   if(|store.u_ram.local_pending)writes=writes+1;
   if(fv && fr && mfv && |store.u_ram.local_pending)$fatal(1,"LOCAL finish passed pending RAM write");
   if(mh && (!mv || {mo,mb,ma,md}!==held))$fatal(1,"LOCAL narrow payload changed while blocked");
   mh=mv && !mr;held={mo,mb,ma,md};
   ev[1]=ev[0];eqa[1]=eqa[0];eqb[1]=eqb[0];ev[0]=rd;
   if(rd)begin eqa[0]=gold[ab][ra];eqb[0]=gold[2+bbank][rb];end
  end
  #1;
  if(resetn)begin
   if(ramv!==ev[1])$fatal(1,"LOCAL read latency mismatch");
   if(ramv)begin if(qa!==eqa[1] || qb!==eqb[1])$fatal(1,"LOCAL data mismatch read=%0d a=%h/%h b=%h/%h",reads,qa,eqa[1],qb,eqb[1]);reads=reads+1;end
  end
 end
 task automatic restart;
 begin @(negedge clk);resetn=0;bv=0;sv=0;fv=0;rd=0;aq=0;rel=0;dis=0;repeat(3)@(negedge clk);resetn=1;resets=resets+1;repeat(2)@(negedge clk);
 if(retained || loading || inuse || busy || ramv)$fatal(1,"LOCAL reset leaked state");end endtask
 task automatic start(input integer p);
 begin @(negedge clk);bv=1;bo=p/2;bb=p%2;do @(posedge clk);while(!br);if(be)$fatal(1,"LOCAL begin rejected");@(negedge clk);bv=0;end endtask
 task automatic sendbeat(input integer p,a,input [W-1:0] data,input [W/8-1:0] keep);
 begin @(negedge clk);sv=1;so=p/2;sb=p%2;sa=a;sd=data;sk=keep;do @(posedge clk);while(!sr);end endtask
 task automatic finish(input integer p,input bit cancel,expect_error);
 begin @(negedge clk);sv=0;fv=1;fo=p/2;fb=p%2;fi=cancel;do @(posedge clk);while(!fr);
 if(fe!==expect_error)$fatal(1,"LOCAL finish error mismatch p=%0d got=%b want=%b",p,fe,expect_error);
 @(negedge clk);fv=0;fi=0;end endtask
 task automatic putword(input integer p,a,seed);
 reg [127:0] data,masked;reg [15:0] keep;
 begin for(integer b=0;b<16;b=b+1)begin data[8*b+:8]=(seed*37+p*71+a*19+b*13);keep[b]=((b+a+seed)%5!=0);end
 masked=0;for(integer b=0;b<16;b=b+1)if(keep[b])masked[8*b+:8]=data[8*b+:8];
 for(integer h=0;h<128/W;h=h+1)sendbeat(p,a*(128/W)+h,data[h*W+:W],keep[h*(W/8)+:W/8]);
 gold[p][a]=masked;end endtask
 task automatic fill(input integer p,seed);
 begin start(p);for(integer a=0;a<DEPTH;a=a+1)putword(p,a,seed);finish(p,0,0);if(!retained[p] || loading[p])$fatal(1,"LOCAL not retained after visible finish");end endtask
 task automatic acquire(input bit bank);
 begin @(negedge clk);ab=bank;bbank=bank;aq=1;do @(posedge clk);while(!aqr);if(aqe)$fatal(1,"LOCAL acquire rejected");@(negedge clk);aq=0;end endtask
 task automatic release_pair;
 begin @(negedge clk);rd=0;repeat(3)@(negedge clk);rel=1;do @(posedge clk);while(!relr);@(negedge clk);rel=0;end endtask
 task automatic scan(input integer passes);
 begin for(integer k=0;k<passes*DEPTH;k=k+1)begin @(negedge clk);rd=1;ra=k%DEPTH;rb=DEPTH-1-k%DEPTH;end
 @(negedge clk);rd=0;repeat(3)@(negedge clk);end endtask
 initial begin
  #160;restart();finish(0,0,1); // 无活动会话的finish必须消费报错，不触碰manager。
  // 缺半/奇地址先到、错目标/跨字高半、地址越界、主动放弃与错误finish。
  if(W==64)begin start(0);sendbeat(0,0,64'h55,'1);finish(0,0,1);if(retained[0])$fatal(1,"LOCAL partial published");
   start(0);sendbeat(0,1,64'h66,'1);finish(0,0,1);
   start(0);sendbeat(0,0,64'h77,'1);sendbeat(0,3,64'h88,'1);finish(0,0,1);
   start(0);sendbeat(0,0,64'h99,'1);restart();start(0);sendbeat(0,1,64'haa,'1);finish(0,0,1);
  end
  start(0);sendbeat(1,0,'1,'1);finish(0,0,1);
  if(DEPTH*(128/W)<(1<<TAW))begin start(0);sendbeat(0,DEPTH*(128/W),'1,'1);finish(0,0,1);end
  start(0);putword(0,DEPTH-1,91);finish(1,0,1);if(!busy || !loading[0])$fatal(1,"LOCAL wrong finish killed session");finish(0,1,0);
  if(retained[0])$fatal(1,"LOCAL canceled load published");
  // 在完整128提交之前复位，随后重装读取，不允许旧低半拼入新数据。
  start(0);putword(0,0,99);restart();
  fill(0,1);fill(2,2);acquire(0);
  random_stall=1;
  fork begin fill(1,3);fill(3,4);end begin scan(12);end join
  if(inuse!==4'b0101)$fatal(1,"LOCAL other-bank loading broke lease");release_pair();
  acquire(1);scan(3);release_pair();
  // 重复租约读取保留bank，不重新搬运。
  begin integer before_load;before_load=accepted;acquire(0);scan(2);release_pair();if(accepted!=before_load)$fatal(1,"LOCAL reuse reloaded");end
  if(reads<17*DEPTH || stalls==0 || fences==0 || errors!=3+(DEPTH*(128/W)<(1<<TAW))+(W==64?4:0) || fullrate<DEPTH || retained!==4'b1111)$fatal(1,"LOCAL coverage missing");
  $display("BANK_LOCAL_PASS width=%0d depth=%0d accepted=%0d narrow=%0d writes=%0d reads=%0d stalls=%0d fences=%0d errors=%0d resets=%0d fullrate=%0d",W,DEPTH,accepted,narrow,writes,reads,stalls,fences,errors,resets,fullrate);$finish;
 end
 initial begin #4000000;$fatal(1,"LOCAL TIMEOUT");end
endmodule
