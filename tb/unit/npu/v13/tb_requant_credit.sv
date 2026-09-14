// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 独立64bit整数黄金模型，不复用DUT的幅值截断/饱和优化表达式。
module tb_requant_credit #(parameter SLOTS=16, MW=32);
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,iv=0,orr=0;wire ir,ov,idle;
    reg [127:0] data=0,bias=0;reg [123:0] mult=0;reg [23:0] shift=0;
    reg [31:0] zp=0;reg [3:0] keep=0,relu=0;reg [MW-1:0] meta=0;
    wire [31:0] od;wire [MW-1:0] om;wire [3:0] ok;
`ifdef POST_NETLIST
    npu_v13_requant_p4 dut(
`else
    npu_v13_requant_p4 #(.META_W(MW),.OUTPUT_SLOTS(SLOTS)) dut(
`endif
        .clk(clk),.resetn(resetn),.in_valid_i(iv),.in_ready_o(ir),.in_data_i(data),.in_keep_i(keep),
        .in_bias_i(bias),.in_multiplier_i(mult),.in_shift_i(shift),.in_zero_point_i(zp),.in_relu_i(relu),.in_meta_i(meta),
        .out_valid_o(ov),.out_ready_i(orr),.out_data_o(od),.out_keep_o(ok),.out_meta_o(om),.idle_o(idle));
    integer cycles=0,accepted=0,retired=0,canceled=0,rd=0,wr=0,stalls=0,ii_count=0;
    integer shift_seen[0:63],satlo=0,sathi=0,zero_mult=0,empty=0,ties=0;
    reg [31:0] expected_data[0:8191];reg [MW-1:0] expected_meta[0:8191];reg [3:0] expected_keep[0:8191];
    reg held=0,all_ready=0,force_stall=0;reg [MW+35:0] payload;
    reg [31:0] rng=32'hfe02875a;
    function automatic [31:0] random_word;
        begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);random_word=rng;end
    endfunction
    function automatic [7:0] golden(input reg signed[31:0] x,b,input reg[30:0] mu,input integer sh,input reg signed[7:0] z,input bit re,en);
        reg signed[63:0] p,sum,q;reg [63:0] mag,quot,remn,half;
        begin
            sum=x;sum=sum+b;p=sum*$signed({1'b0,mu});mag=p<0 ? -p : p;
            quot=mag>>sh;
            if(sh>0)begin
                remn=mag&((64'd1<<sh)-1);half=64'd1<<(sh-1);
                if(remn>=half)quot=quot+1;
                if(remn==half)ties=ties+1;
            end
            q=p<0 ? -$signed(quot) : $signed(quot);q=q+z;
            if(re && q<z)q=z;
            if(q>127)begin q=127;if(en)sathi=sathi+1;end
            if(q < -128)begin q=-128;if(en)satlo=satlo+1;end
            golden=en ? q[7:0] : 0;
        end
    endfunction
    integer highwater=0,full_stall=0,idle_checks=0;
    always @(negedge clk)if(resetn)orr=!force_stall && (all_ready || (cycles%127>=64 && cycles%17<11));
    always @(posedge clk)begin
        if(!resetn)held=0;
        else begin
            cycles=cycles+1;
            // 仅依赖公开握手记录；不访问DUT寄存器或内部assert。
            if(ir !== (wr-rd<SLOTS))$fatal(1,"CREDIT ready mismatch outstanding=%0d slots=%0d",wr-rd,SLOTS);
            if(idle !== (wr==rd))$fatal(1,"CREDIT idle lost queued/inflight tokens");
            idle_checks=idle_checks+1;
            if(wr-rd>highwater)highwater=wr-rd;
            if(wr-rd==SLOTS && !orr)full_stall=full_stall+1;
            if(held && (!ov || payload!=={om,ok,od}))$fatal(1,"REQUANT changed while stalled");
            held=ov && !orr;payload={om,ok,od};if(held)stalls=stalls+1;
            if(iv && ir)begin
                expected_keep[wr]=keep;expected_meta[wr]=meta;
                for(integer l=0;l<4;l=l+1)begin
                    expected_data[wr][l*8+:8]=golden(data[l*32+:32],bias[l*32+:32],mult[l*31+:31],shift[l*6+:6],zp[l*8+:8],relu[l],keep[l]);
                    shift_seen[shift[l*6+:6]]=shift_seen[shift[l*6+:6]]+1;
                    if(mult[l*31+:31]==0)zero_mult=zero_mult+1;
                end
                if(keep==0)empty=empty+1;
                wr=wr+1;accepted=accepted+1;
            end
            if(ov && orr)begin
                if(rd==wr || od!==expected_data[rd] || om!==expected_meta[rd] || ok!==expected_keep[rd])
                    $fatal(1,"REQUANT mismatch rd=%0d got=%h expect=%h meta=%h/%h",rd,od,expected_data[rd],om,expected_meta[rd]);
                rd=rd+1;retired=retired+1;
            end
            if(all_ready && iv && ir && ov && orr)ii_count=ii_count+1;
        end
    end
    task automatic drive(input integer idx);
        reg[31:0] rw;
        begin
            meta=idx;keep=random_word();relu=random_word();
            for(integer l=0;l<4;l=l+1)begin
                data[l*32+:32]=random_word();bias[l*32+:32]=random_word();rw=random_word();mult[l*31+:31]=rw[30:0];
                shift[l*6+:6]=(idx+l*11)%64;zp[l*8+:8]=random_word();
                case(idx%16)
                    0: begin data[l*32+:32]=32'h80000000;bias[l*32+:32]=32'h80000000;mult[l*31+:31]=31'h7fffffff;end
                    1: begin data[l*32+:32]=32'h7fffffff;bias[l*32+:32]=32'h7fffffff;mult[l*31+:31]=31'h7fffffff;end
                    2: mult[l*31+:31]=0;
                    3: begin data[l*32+:32]=l%2 ? -3 : 3;bias[l*32+:32]=0;mult[l*31+:31]=1;shift[l*6+:6]=1;end
                    4: begin data[l*32+:32]=l%2 ? -1 : 1;bias[l*32+:32]=0;mult[l*31+:31]=1;shift[l*6+:6]=1;end
                    5: begin data[l*32+:32]=idx%513-256;bias[l*32+:32]=0;mult[l*31+:31]=1;shift[l*6+:6]=0;end
                    6: begin data[l*32+:32]=32'h80000000;bias[l*32+:32]=32'h7fffffff;mult[l*31+:31]=1;shift[l*6+:6]=0;end
                endcase
            end
        end
    endtask
    task automatic drain;
        begin
            @(negedge clk);iv=0;all_ready=1;force_stall=0;
            wait(idle);@(negedge clk);if(rd!=wr)$fatal(1,"REQUANT lost data");
        end
    endtask
    task automatic send(input integer idx);
        begin @(negedge clk);drive(idx);iv=1;do @(posedge clk);while(!ir);end
    endtask
    initial begin
        for(integer s=0;s<64;s=s+1)shift_seen[s]=0;
        #150;repeat(5)@(negedge clk);resetn=1;force_stall=1;all_ready=0;
        // 停输出后仍接受精确SLOTS个预约；等待所有迟到算术结果进入窄队列。
        for(integer i=0;i<SLOTS;i=i+1)send(i);
        @(negedge clk);drive(999);iv=1;repeat(40)@(negedge clk);
        if(ir || !ov || highwater!=SLOTS)$fatal(1,"CREDIT missing full coverage");
        // FULL队列暖复位，旧内容不清但不能再次可见。
        iv=0;canceled=canceled+wr-rd;rd=wr;resetn=0;
        repeat(5)@(negedge clk);resetn=1;force_stall=0;all_ready=1;
        for(integer i=0;i<1200;i=i+1)send(1000+i);
        drain();all_ready=0;
        for(integer i=0;i<3000;i=i+1)begin
            send(3000+i);
            if(i%7==0)begin @(negedge clk);iv=0;repeat(i%4)@(negedge clk);end
        end
        drain();
        // 空泡和在途token混合时reset，防止自由运行旧payload复活。
        force_stall=1;all_ready=0;
        for(integer i=0;i<3;i=i+1)send(7000+i);
        @(negedge clk);iv=0;canceled=canceled+wr-rd;rd=wr;resetn=0;
        repeat(5)@(negedge clk);resetn=1;force_stall=0;all_ready=1;
        for(integer i=0;i<512;i=i+1)send(8000+i);
        drain();repeat(8)@(negedge clk);
        for(integer s=0;s<64;s=s+1)if(shift_seen[s]==0)$fatal(1,"missing shift %0d",s);
        if(accepted!=retired+canceled || canceled!=SLOTS+3 || full_stall<30 || highwater!=SLOTS || ii_count<1600 || satlo==0 || sathi==0 || zero_mult==0 || ties==0 || empty==0)
            $fatal(1,"CREDIT missing coverage a=%0d r=%0d cancel=%0d ii=%0d full=%0d",accepted,retired,canceled,ii_count,full_stall);
        $display("REQUANT_CREDIT_PASS slots=%0d mw=%0d accepted=%0d retired=%0d canceled=%0d stalls=%0d ii1=%0d highwater=%0d full_stall=%0d idle_checks=%0d shifts=64",SLOTS,MW,accepted,retired,canceled,stalls,ii_count,highwater,full_stall,idle_checks);$finish;
    end
    initial begin #1000000;$fatal(1,"REQUANT TIMEOUT");end
endmodule
