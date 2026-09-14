// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 独立诊断：穷举默认合法shape的每岛word数，逐行数学计数不复用DUT公式。
// 立即end且无写入必须失败；不能因expected尚未更新/旧值为0而错误发布READY。
module tb_feature_count_fence;
 reg clk=0;always #2.5 clk=~clk;
 reg resetn=0,bv=0,ev=0,dr=0;reg [15:0] m=0,n=0,tag=0;
 wire br,er,dv,de;wire [1:0] ready,free;wire [15:0] dt;
 npu_v13_feature_store dut(.clk(clk),.resetn(resetn),
  .begin_valid_i(bv),.begin_ready_o(br),.begin_bank_i(1'b0),.begin_m_i(m),.begin_n_i(n),.begin_tag_i(tag),
  .in_valid_i(4'b0),.in_data_i(128'b0),.in_keep_i(16'b0),.in_m_i(64'b0),.in_n_i(64'b0),.in_tag_i(64'b0),
  .end_valid_i(ev),.end_ready_o(er),.end_error_i(1'b0),.done_valid_o(dv),.done_ready_i(dr),.done_error_o(de),.done_tag_o(dt),
  .bank_ready_o(ready),.bank_free_o(free),.release_valid_i(1'b0),.release_bank_i(1'b0),
  .rd_valid_i(1'b0),.rd_bank_i(1'b0),.rd_m_i(16'b0),.rd_n_i(16'b0),.rd_ready_i(1'b1));
 integer tests=0,resets=0;integer expected[0:3];
 task automatic one_shape(input integer mi,ni);
  begin
   for(integer g=0;g<4;g=g+1)expected[g]=0;
   for(integer row=0;row<mi;row=row+1)expected[(row/4)%4]=expected[(row/4)%4]+(ni+3)/4;
   @(negedge clk);m=mi;n=ni;tag=tests;bv=1;
   do @(posedge clk);while(!br);
   @(negedge clk);bv=0;ev=1;
   do @(posedge clk);while(!er);
   @(negedge clk);ev=0;
   wait(dv);@(negedge clk);
   for(integer g=0;g<4;g=g+1)if(dut.expected_r[g] !== (expected[g]&2047))$fatal(1,"COUNT mismatch m=%0d n=%0d group=%0d actual=%0d expected=%0d",mi,ni,g,dut.expected_r[g],expected[g]);
   if(!de || ready!=0 || free!=3 || dt!==tag)$fatal(1,"COUNT_FENCE empty transaction published/stale tag");
   repeat(2)begin @(negedge clk);if(!dv || !de || dt!==tag || ready!=0)$fatal(1,"COUNT_FENCE done hold");end
   dr=1;@(posedge clk);@(negedge clk);dr=0;tests=tests+1;
  end
 endtask
 initial begin
  #160;repeat(4)@(negedge clk);resetn=1;
  for(integer mi=1;mi<=128;mi=mi+1)for(integer ni=1;ni<=128;ni=ni+1)one_shape(mi,ni);
  one_shape(0,0);one_shape(129,128);one_shape(128,129);one_shape(65535,65535);
  // 分别在计数操作数/乘积/输出在途时复位，随后新事务不能受旧token影响。
  for(integer delay=0;delay<3;delay=delay+1)begin
   @(negedge clk);m=128;n=128;bv=1;do @(posedge clk);while(!br);
   @(negedge clk);bv=0;repeat(delay)@(negedge clk);resetn=0;
   repeat(3)@(negedge clk);resetn=1;repeat(5)@(negedge clk);
   if(dv || ready!=0 || free!=3)$fatal(1,"COUNT_FENCE reset leaked state");
   resets=resets+1;one_shape(1,1);
  end
  $display("FEATURE_COUNT_FENCE_PASS shapes=%0d legal=16384 reset_phases=%0d",tests,resets);$finish;
 end
 initial begin #2000000;$fatal(1,"COUNT_FENCE TIMEOUT");end
endmodule
