// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 联合OOC同域launch/observation夹具。只豁免外部端口到夹具的路径；
// ready、reset、job/chunk/load全部动态寄存，DUT内部没有false_path或multicycle。
module multik_timing #(
    parameter integer MAX_MN=128,MAX_K=512,AW=$clog2((MAX_MN/16)*MAX_K),
    parameter integer IW=313+AW,OW=805
)(
    input wire clk, // 目标计算时钟，200/300MHz分开实现。
    input wire [IW-1:0] stimulus_i, // 测量夹具输入，不是板级引脚接口规范。
    output reg [OW-1:0] observation_o // 寄存观察所有对外有效状态和结果，防止无负载裁剪。
);
    reg [IW-1:0] launch_r;
    wire resetn,jv,jr,xv,xr,dv,dr,xab,xbb,xcb;
    wire [15:0] jm,jn,jt,xk,dt;wire [31:0] jk,xa,xb,kd;wire [2:0] ds;
    wire lbv,lbr,lbe,lbo,lbb,lv,lr,lo,lb,lfv,lfr,lfer,lfo,lfb,lfe,disv,disr,dise,disop,disbank,allow;
    wire [AW-1:0] la;wire [127:0] ld;
    wire [3:0] cv,cr,retained,loading,inuse,commit;
    wire [511:0] cd;wire [15:0] keep;wire [63:0] om,on,ot;wire beat,packet,busy,error;
    assign {resetn,jv,jm,jn,jt,jk,xv,xk,xab,xbb,xcb,xa,xb,dr,
        lbv,lbo,lbb,lv,lo,lb,la,ld,lfv,lfo,lfb,lfe,disv,disop,disbank,allow,cr}=launch_r;
    always @(posedge clk) begin
        launch_r<=stimulus_i;
        observation_o<={jr,xr,dv,dt,ds,kd,lbr,lbe,lr,lfr,lfer,disr,dise,
            cv,cd,keep,om,on,ot,retained,loading,inuse,beat,packet,commit,busy,error};
    end
    npu_v13_multik_backend #(.MAX_MN(MAX_MN),.MAX_K(MAX_K)) u_dut(
        .clk(clk),.resetn(resetn),.job_valid_i(jv),.job_ready_o(jr),.job_m_i(jm),.job_n_i(jn),.job_tag_i(jt),.job_k_i(jk),
        .chunk_valid_i(xv),.chunk_ready_o(xr),.chunk_k_i(xk),.chunk_a_bank_i(xab),.chunk_b_bank_i(xbb),.chunk_c_bank_i(xcb),
        .chunk_a_base_i(xa),.chunk_b_base_i(xb),.done_valid_o(dv),.done_ready_i(dr),.done_tag_o(dt),.done_status_o(ds),.k_done_o(kd),
        .load_begin_valid_i(lbv),.load_begin_ready_o(lbr),.load_begin_error_o(lbe),.load_begin_operand_i(lbo),.load_begin_bank_i(lbb),
        .load_valid_i(lv),.load_ready_o(lr),.load_operand_i(lo),.load_bank_i(lb),.load_addr_i(la),.load_data_i(ld),
        .load_finish_valid_i(lfv),.load_finish_ready_o(lfr),.load_finish_error_o(lfer),
        .load_finish_operand_i(lfo),.load_finish_bank_i(lfb),.load_finish_error_i(lfe),
        .discard_valid_i(disv),.discard_ready_o(disr),.discard_error_o(dise),.discard_operand_i(disop),.discard_bank_i(disbank),
        .allow_beat_i(allow),.c_valid_o(cv),.c_ready_i(cr),.c_data_o(cd),.c_keep_o(keep),.c_m_o(om),.c_n_o(on),.c_tag_o(ot),
        .retained_o(retained),.loading_o(loading),.in_use_o(inuse),.input_beat_o(beat),.packet_issue_o(packet),
        .psum_commit_o(commit),.busy_o(busy),.error_o(error));
    // synthesis translate_off
    initial begin
        if($bits({resetn,jv,jm,jn,jt,jk,xv,xk,xab,xbb,xcb,xa,xb,dr,
            lbv,lbo,lbb,lv,lo,lb,la,ld,lfv,lfo,lfb,lfe,disv,disop,disbank,allow,cr})!=IW)$fatal(1,"MULTIK fixture input width");
        if($bits({jr,xr,dv,dt,ds,kd,lbr,lbe,lr,lfr,lfer,disr,dise,
            cv,cd,keep,om,on,ot,retained,loading,inuse,beat,packet,commit,busy,error})!=OW)$fatal(1,"MULTIK fixture output width");
    end
    // synthesis translate_on
endmodule
