// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p8上层预约栅栏：begin持续请求不能越过最后cfg的本地提交；读回独立INT8黄金。
module tb_post_config_fence;
 reg clk=0;always #2.5 clk=~clk;
 reg resetn=0,cv=0,bv=0,ev=0,dr=0,rv=0,rr=0,release_v=0;
 reg [15:0] ci=0;reg signed [7:0] zero=0;wire cr,ce,br,er,dv,de,db,busy;
 reg [3:0] iv=0;wire [3:0] ir;wire [15:0] dt;wire [1:0] ready_b,free_b;
 wire rd_req_ready,rdv,rde,rdb,release_ready;wire [31:0] data;wire [3:0] keep,commits;
 wire [15:0] rm,rn,rt;
 npu_v13_postprocess_engine #(.MAX_M(16),.MAX_N(16),.CHANNELS(19)) dut(
 .clk(clk),.resetn(resetn),.cfg_valid_i(cv),.cfg_ready_o(cr),.cfg_error_o(ce),.cfg_index_i(ci),
 .cfg_bias_i(32'sd0),.cfg_multiplier_i(31'd0),.cfg_shift_i(6'd0),.cfg_zero_point_i(zero),.cfg_relu_i(1'b0),
 .begin_valid_i(bv),.begin_ready_o(br),.begin_bank_i(1'b0),.begin_axis_i(1'b0),.begin_m_i(16'd1),.begin_n_i(16'd1),.begin_tag_i(16'h55),
 .in_valid_i(iv),.in_ready_o(ir),.in_data_i(512'b0),.in_keep_i(16'h0001),.in_m_i(64'b0),.in_n_i(64'b0),.in_tag_i(64'h55),
 .end_valid_i(ev),.end_ready_o(er),.end_error_i(1'b0),.done_valid_o(dv),.done_ready_i(dr),.done_error_o(de),.done_bank_o(db),.done_tag_o(dt),
 .bank_ready_o(ready_b),.bank_free_o(free_b),.release_valid_i(release_v),.release_ready_o(release_ready),.release_bank_i(1'b0),
 .rd_valid_i(rv),.rd_ready_o(rd_req_ready),.rd_bank_i(1'b0),.rd_m_i(16'd0),.rd_n_i(16'd0),
 .rd_valid_o(rdv),.rd_ready_i(rr),.rd_data_o(data),.rd_keep_o(keep),.rd_bank_o(rdb),.rd_error_o(rde),.rd_m_o(rm),.rd_n_o(rn),.rd_tag_o(rt),
 .write_commit_o(commits),.busy_o(busy));
 integer started=0,finished=0,readbacks=0,cfgs=0,blocked=0,errors=0,write_commits=0;
 always @(posedge clk)if(resetn)begin
  if(bv&&br)started=started+1;
  if(cv&&cr)begin cfgs=cfgs+1;if(ce)errors=errors+1;end
  if(|commits)write_commits=write_commits+1;
 end
 task automatic configure(input integer index,z);
  begin
   @(negedge clk);ci=index;zero=z;cv=1;bv=1;
   @(posedge clk);if(!cr || br || ce!==(index>=19))$fatal(1,"POST_FENCE config/begin priority");
   #1;
  end
 endtask
 task automatic run_job(input bit pending,input bit expect_error);
  begin
   @(negedge clk);cv=0;bv=1;
   #1;if(pending)begin if(br)$fatal(1,"POST_FENCE begin crossed local write fence");blocked=blocked+1;end
   @(posedge clk);while(!br)@(posedge clk);
   @(negedge clk);bv=0;iv=1;
   @(posedge clk);while(!ir[0])@(posedge clk);
   @(negedge clk);iv=0;ev=1;
   @(posedge clk);while(!er)@(posedge clk);
   @(negedge clk);ev=0;
   while(!dv)@(negedge clk);
   repeat(5)begin
    if(!dv || de!==expect_error || db!==0 || dt!==16'h55)$fatal(1,"POST_FENCE completion mismatch");
    if(expect_error && ready_b[0])$fatal(1,"POST_FENCE failed bank published");
    @(negedge clk);
   end
   dr=1;@(posedge clk);@(negedge clk);dr=0;finished=finished+1;
   if(!expect_error)begin
    if(!ready_b[0])$fatal(1,"POST_FENCE success bank missing");
    rv=1;@(posedge clk);while(!rd_req_ready)@(posedge clk);
    @(negedge clk);rv=0;while(!rdv)@(negedge clk);
    repeat(5)begin
     if(!rdv || rde || rdb || rm!=0 || rn!=0 || rt!=16'h55 || keep!==4'b0001 || data!==32'd37)
      $fatal(1,"POST_FENCE output golden mismatch data=%h keep=%h error=%b",data,keep,rde);
     @(negedge clk);
    end
    rr=1;@(posedge clk);@(negedge clk);rr=0;readbacks=readbacks+1;
    release_v=1;@(posedge clk);while(!release_ready)@(posedge clk);
    @(negedge clk);release_v=0;
   end
   if(free_b!==2'b11)$fatal(1,"POST_FENCE bank not free");
  end
 endtask
 initial begin
  #150;repeat(5)@(negedge clk);resetn=1;
  configure(0,10);configure(0,20);configure(0,37);run_job(1,0);
  configure(65535,99);run_job(0,0); // 错误配置不能改写上一版参数，也不制造待提交写。
  configure(0,99);
  @(negedge clk);resetn=0;cv=0;bv=0;repeat(4)@(negedge clk);resetn=1;
  run_job(0,1); // reset取消待提交并清初始化标记：缺参必须失败，不输出旧37或新99。
  if(started!=3 || finished!=3 || readbacks!=2 || cfgs!=5 || blocked!=1 || errors!=1 || write_commits!=2)
   $fatal(1,"POST_FENCE coverage start=%0d finish=%0d reads=%0d cfgs=%0d writes=%0d",started,finished,readbacks,cfgs,write_commits);
  $display("POST_FENCE_PASS started=%0d finished=%0d readbacks=%0d cfgs=%0d blocked=%0d cfgerrors=%0d commits=%0d",started,finished,readbacks,cfgs,blocked,errors,write_commits);$finish;
 end
 initial begin #200000;$fatal(1,"POST_FENCE TIMEOUT");end
endmodule
