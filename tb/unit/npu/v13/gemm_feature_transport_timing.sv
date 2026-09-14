// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 第二批整链OOC时序夹具：真实命令/输入BRAM/256DSP/PSUM/量化/feature全部保留。
// 输入先同域寄存，全部输出再同域观察；仅外部端口到夹具的路径可豁免。
// 不把ready、动态M/N/K、量化系数、bank或reset绑常量，避免测出被裁剪的假通过。
// 本文件不是板级顶层，也不是功能黄金模型；数值验证见tb_gemm_feature_backend。
module gemm_feature_transport_timing #(
    parameter integer MAX_MN=128, MAX_K=512, TRANSPORT_W=64,
    parameter integer AW=$clog2((MAX_MN/16)*MAX_K),
    parameter integer IW=316+AW+TRANSPORT_W+TRANSPORT_W/8+(TRANSPORT_W==64), OW=146+TRANSPORT_W+TRANSPORT_W/8
)(
    input wire clk, // 唯一计算时钟；200/300MHz分开布局布线。
    input wire [IW-1:0] stimulus_i, // 任意动态输入，包含所有控制和数据端口。
    output reg [OW-1:0] observation_o // 寄存所有DUT输出，既保留负载也测输出边界。
);
    reg [IW-1:0] launch_r;
    wire resetn,jv,jr,jfb,jaxis,xv,xr,dv,dr,dfb,xab,xbb,xcb;
    wire [15:0] jm,jn,jt,xk,dt;
    wire [31:0] jk,xa,xb,kd;
    wire [2:0] ds;
    wire cfgv,cfgr,cfge,crelu;
    wire [15:0] ci;
    wire signed [31:0] cbias;
    wire [30:0] cmult;
    wire [5:0] cshift;
    wire signed [7:0] czp;
    wire lbv,lbr,lbe,lbo,lbb,lv,lr,lo,lb,lfv,lfr,lfer,lfo,lfb,lfe;
    wire disv,disr,dise,disop,disbank,allow;
    wire [AW+(TRANSPORT_W==64)-1:0] la;
    wire [TRANSPORT_W-1:0] ld;wire [TRANSPORT_W/8-1:0] lkeep;wire rlast,olast;
    wire [3:0] retained,loading,inuse,pcommit,fcommit;
    wire [1:0] fready,ffree;
    wire frelv,frelr,frelb,rv,rr,rb,ov,orr,ob,oe;
    wire [15:0] rm,rn,om,on,ot;
    wire [TRANSPORT_W-1:0] od;
    wire [TRANSPORT_W/8-1:0] ok;
    wire beat,packet,busy,error;
    assign {resetn,jv,jm,jn,jt,jk,jfb,jaxis,xv,xk,xab,xbb,xcb,xa,xb,dr,
        cfgv,ci,cbias,cmult,cshift,czp,crelu,
        lbv,lbo,lbb,lv,lo,lb,la,ld,lkeep,lfv,lfo,lfb,lfe,disv,disop,disbank,allow,
        frelv,frelb,rv,rb,rm,rn,rlast,orr}=launch_r;
    always @(posedge clk) begin
        launch_r<=stimulus_i;
        observation_o<={jr,xr,dv,dt,ds,dfb,kd,cfgr,cfge,lbr,lbe,lr,lfr,lfer,disr,dise,
            retained,loading,inuse,fready,ffree,frelr,rr,ov,olast,od,ok,ob,oe,om,on,ot,
            pcommit,fcommit,beat,packet,busy,error};
    end
    npu_v13_gemm_feature_transport #(.TRANSPORT_W(TRANSPORT_W),.MAX_MN(MAX_MN),.MAX_K(MAX_K)) u_dut(
        .clk(clk),.resetn(resetn),.job_valid_i(jv),.job_ready_o(jr),.job_m_i(jm),.job_n_i(jn),.job_tag_i(jt),.job_k_i(jk),
        .job_feature_bank_i(jfb),.job_quant_axis_i(jaxis),
        .chunk_valid_i(xv),.chunk_ready_o(xr),.chunk_k_i(xk),.chunk_a_bank_i(xab),.chunk_b_bank_i(xbb),.chunk_c_bank_i(xcb),
        .chunk_a_base_i(xa),.chunk_b_base_i(xb),.done_valid_o(dv),.done_ready_i(dr),.done_tag_o(dt),.done_status_o(ds),.done_feature_bank_o(dfb),.k_done_o(kd),
        .cfg_valid_i(cfgv),.cfg_ready_o(cfgr),.cfg_error_o(cfge),.cfg_index_i(ci),.cfg_bias_i(cbias),.cfg_multiplier_i(cmult),
        .cfg_shift_i(cshift),.cfg_zero_point_i(czp),.cfg_relu_i(crelu),
        .load_begin_valid_i(lbv),.load_begin_ready_o(lbr),.load_begin_error_o(lbe),.load_begin_operand_i(lbo),.load_begin_bank_i(lbb),
        .load_valid_i(lv),.load_ready_o(lr),.load_operand_i(lo),.load_bank_i(lb),.load_addr_i(la),.load_data_i(ld),.load_keep_i(lkeep),
        .load_finish_valid_i(lfv),.load_finish_ready_o(lfr),.load_finish_error_o(lfer),.load_finish_operand_i(lfo),.load_finish_bank_i(lfb),.load_finish_error_i(lfe),
        .discard_valid_i(disv),.discard_ready_o(disr),.discard_error_o(dise),.discard_operand_i(disop),.discard_bank_i(disbank),.allow_beat_i(allow),
        .retained_o(retained),.loading_o(loading),.in_use_o(inuse),.feature_ready_o(fready),.feature_free_o(ffree),
        .feature_release_valid_i(frelv),.feature_release_ready_o(frelr),.feature_release_bank_i(frelb),
        .rd_last_i(rlast),.rd_last_o(olast),.rd_valid_i(rv),.rd_ready_o(rr),.rd_bank_i(rb),.rd_m_i(rm),.rd_n_i(rn),.rd_valid_o(ov),.rd_ready_i(orr),
        .rd_data_o(od),.rd_keep_o(ok),.rd_bank_o(ob),.rd_error_o(oe),.rd_m_o(om),.rd_n_o(on),.rd_tag_o(ot),
        .input_beat_o(beat),.packet_issue_o(packet),.psum_commit_o(pcommit),.feature_commit_o(fcommit),.busy_o(busy),.error_o(error));
    // synthesis translate_off
    initial begin
        if($bits({resetn,jv,jm,jn,jt,jk,jfb,jaxis,xv,xk,xab,xbb,xcb,xa,xb,dr,
            cfgv,ci,cbias,cmult,cshift,czp,crelu,
            lbv,lbo,lbb,lv,lo,lb,la,ld,lkeep,lfv,lfo,lfb,lfe,disv,disop,disbank,allow,
            frelv,frelb,rv,rb,rm,rn,rlast,orr})!=IW) $fatal(1,"GEMM_TRANSPORT fixture input width");
        if($bits({jr,xr,dv,dt,ds,dfb,kd,cfgr,cfge,lbr,lbe,lr,lfr,lfer,disr,dise,
            retained,loading,inuse,fready,ffree,frelr,rr,ov,olast,od,ok,ob,oe,om,on,ot,
            pcommit,fcommit,beat,packet,busy,error})!=OW) $fatal(1,"GEMM_TRANSPORT fixture output width");
        $display("GEMM_TRANSPORT_FIXTURE_WIDTH_PASS IW=%0d OW=%0d",IW,OW);
    end
    // synthesis translate_on
endmodule
