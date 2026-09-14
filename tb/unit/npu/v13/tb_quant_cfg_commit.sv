// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p8定向契约：配置背靠背接收、最后一条写可见、立即lock读、错误不改表、复位取消待提交。
// 黄金参数由测试输入独立维护，不读取DUT内部RAM或寄存器。
module tb_quant_cfg_commit;
 reg clk=0;always #2.5 clk=~clk;
 reg resetn=0,locked=0,cv=0;reg [15:0] ci=0;reg [77:0] cw=0;
 wire cr,ce,idle;reg [3:0] iv=0,orr=0;wire [3:0] ir,ov,oe;
 reg [63:0] im=0;wire [511:0] ob;wire [495:0] omu;wire [95:0] osh;
 wire [127:0] oz;wire [15:0] ore;
 npu_v13_quant_params #(.CHANNELS(19)) dut(
 .clk(clk),.resetn(resetn),.lock_i(locked),.read_open_i({4{locked}}),.cfg_valid_i(cv),.cfg_ready_o(cr),.cfg_error_o(ce),
 .cfg_index_i(ci),.cfg_bias_i(cw[31:0]),.cfg_multiplier_i(cw[62:32]),.cfg_shift_i(cw[68:63]),.cfg_zero_point_i(cw[76:69]),.cfg_relu_i(cw[77]),
 .in_valid_i(iv),.in_ready_o(ir),.in_axis_i(1'b0),.in_data_i(512'b0),.in_keep_i(16'hffff),.in_m_i(im),.in_n_i(64'b0),.in_tag_i(64'h0004000300020001),
 .out_valid_o(ov),.out_ready_i(orr),.out_data_o(),.out_bias_o(ob),.out_multiplier_o(omu),.out_shift_o(osh),.out_zero_point_o(oz),
 .out_keep_o(),.out_relu_o(ore),.out_m_o(),.out_n_o(),.out_tag_o(),.out_error_o(oe),.idle_o(idle));
 reg [77:0] golden[0:18];reg [18:0] present=0;
 integer writes=0,invalids=0,probes=0,blocked=0,canceled=0;
 function automatic [77:0] coeff(input integer idx,epoch);
  reg [31:0] b;reg [30:0] m;reg [5:0] s;reg [7:0] z;reg r;
  begin b=32'h87650000+idx*1729+epoch;m=31'h52345678-idx*99+epoch;s=(idx+epoch)%64;z=idx*7+epoch;r=epoch%2;coeff={r,z,s,m,b};end
 endfunction
 task automatic configure(input integer idx,epoch);
  begin
   @(negedge clk);cv=1;ci=idx;cw=coeff(idx,epoch);
   @(posedge clk);if(!cr)$fatal(1,"CFG_COMMIT unexpected config stall");
   if(ce!==(idx>=19))$fatal(1,"CFG_COMMIT bad config error");
   if(idx<19)begin golden[idx]=cw;present[idx]=1;writes=writes+1;end else invalids=invalids+1;
   #1;if(idx<19 && idle)$fatal(1,"CFG_COMMIT idle before local RAM commit");
  end
 endtask
 task automatic probe(input integer idx,input bit expect_pending);
  reg [77:0] expected_word,actual_word;integer delay;
  begin
   @(negedge clk);cv=0;locked=1;iv=15;orr=0;
   for(integer g=0;g<4;g=g+1)im[g*16+:16]=idx;
   #1;if(expect_pending)begin
    if(ir!==0 || idle)$fatal(1,"CFG_COMMIT read crossed pending write");blocked=blocked+1;
   end
   @(posedge clk);delay=0;
   while(ir!==15)begin delay=delay+1;if(delay>30)$fatal(1,"CFG_COMMIT input timeout");@(posedge clk);end
   @(negedge clk);iv=0;
   delay=0;while(ov!==15)begin @(negedge clk);delay=delay+1;if(delay>30)$fatal(1,"CFG_COMMIT output timeout");end
   expected_word=present[idx]?golden[idx]:78'b0;
   // 输出独立保持四拍；每岛、每lane均检查完整78bit精确系数和缺参标志。
   repeat(4)begin
    for(integer g=0;g<4;g=g+1)begin
     if(!ov[g] || oe[g]!==!present[idx])$fatal(1,"CFG_COMMIT response validity idx=%0d island=%0d",idx,g);
     for(integer l=0;l<4;l=l+1)begin
      actual_word={ore[g*4+l],oz[(g*4+l)*8+:8],osh[(g*4+l)*6+:6],omu[(g*4+l)*31+:31],ob[(g*4+l)*32+:32]};
      if(actual_word!==expected_word)$fatal(1,"CFG_COMMIT stale/mixed coefficient idx=%0d island=%0d lane=%0d",idx,g,l);
     end
    end
    @(negedge clk);
   end
   orr=15;@(posedge clk);@(negedge clk);orr=0;
   if(!idle)$fatal(1,"CFG_COMMIT did not drain");locked=0;probes=probes+1;
  end
 endtask
 initial begin
  #150;repeat(5)@(negedge clk);resetn=1;
  for(integer j=0;j<18;j=j+1)configure(j,0);
  configure(7,1);configure(7,2); // 相邻拍同地址必须最后一次写胜出。
  probe(7,1);
  for(integer j=0;j<19;j=j+1)probe(j,0); // 18未初始化，必须报告缺参。
  configure(19,8);configure(65535,9);probe(7,0);probe(18,0);
  configure(18,4);probe(18,1);
  configure(7,5); // 在接受后、RAM提交前复位；不允许旧参数或待提交参数重新生效。
  @(negedge clk);resetn=0;cv=0;locked=0;present=0;canceled=canceled+1;
  repeat(4)@(negedge clk);resetn=1;
  probe(7,0);configure(7,6);probe(7,1);
  if(writes!=23 || invalids!=2 || probes!=25 || blocked!=3 || canceled!=1)$fatal(1,"CFG_COMMIT coverage writes=%0d probes=%0d",writes,probes);
  $display("CFG_COMMIT_PASS writes=%0d invalids=%0d probes=%0d blocked=%0d canceled=%0d",writes,invalids,probes,blocked,canceled);$finish;
 end
 initial begin #200000;$fatal(1,"CFG_COMMIT TIMEOUT");end
endmodule
