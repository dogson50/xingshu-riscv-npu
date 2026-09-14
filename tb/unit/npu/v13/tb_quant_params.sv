// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 非2幂19通道；黄金表按真实cfg握手更新，不读取DUT层次/内部RAM。
module tb_quant_params;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,locked=0,cv=0,axis=0;wire cr,ce,idle;
    reg [15:0] ci=0;reg [77:0] cw=0;
    reg [3:0] iv=0,orr=0;wire [3:0] ir,ov,oe;
    reg [511:0] idata=0;reg [15:0] ik=0;reg [63:0] im=0,incol=0,it=0;
    wire [511:0] od,ob;wire [495:0] omu;wire [95:0] osh;wire [127:0] oz;
    wire [15:0] ok,ore;wire [63:0] om,on,ot;
`ifdef PARAMS_NETLIST
    npu_v13_quant_params dut(
`else
    npu_v13_quant_params #(.CHANNELS(19)) dut(
`endif
        .clk(clk),.resetn(resetn),.lock_i(locked),.read_open_i({4{locked}}),.cfg_valid_i(cv),.cfg_ready_o(cr),.cfg_index_i(ci),
        .cfg_bias_i(cw[31:0]),.cfg_multiplier_i(cw[62:32]),.cfg_shift_i(cw[68:63]),
        .cfg_zero_point_i(cw[76:69]),.cfg_relu_i(cw[77]),.cfg_error_o(ce),
        .in_valid_i(iv),.in_ready_o(ir),.in_axis_i(axis),.in_data_i(idata),.in_keep_i(ik),.in_m_i(im),.in_n_i(incol),.in_tag_i(it),
        .out_valid_o(ov),.out_ready_i(orr),.out_data_o(od),.out_bias_o(ob),.out_multiplier_o(omu),.out_shift_o(osh),
        .out_zero_point_o(oz),.out_keep_o(ok),.out_relu_o(ore),.out_m_o(om),.out_n_o(on),.out_tag_o(ot),.out_error_o(oe),.idle_o(idle));
    reg [77:0] golden[0:18];reg [18:0] initialized=0;
    reg [179:0] expected_payload[0:3][0:4095];reg [311:0] expected_coeff[0:3][0:4095];
    reg expected_bad[0:3][0:4095];integer wr[0:3],rd[0:3];
    reg [492:0] held_payload[0:3];reg [3:0] held=0,fired=0;
    integer accepted=0,retired=0,errors=0,cfgwrites=0,cfgerrors=0,stalls=0,cycles=0,fullrate=0,canceled=0;
    reg [31:0] rng=32'h283716aa;
    function automatic [31:0] random_word;
        begin rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);random_word=rng;end
    endfunction
    function automatic [77:0] coefficient(input integer idx,epoch);
        reg [31:0] b;reg [30:0] mu;reg [5:0] sh;reg [7:0] z;reg re;
        begin b=idx*876543-12345678+epoch;mu=31'h76543210-idx*779+epoch;
            sh=(idx+epoch)%64;z=idx*31+epoch;re=idx%2;coefficient={re,z,sh,mu,b};end
    endfunction
    integer g,l,j,ix;reg bad;reg [77:0] coeff;reg [311:0] actual_coeff;reg [492:0] actual;
    always @(posedge clk)begin
        if(!resetn)begin initialized=0;held=0;fired=0;end
        else begin
            cycles=cycles+1;fired=iv&ir;
            if((iv&ir)==15)fullrate=fullrate+1;
            if(locked && cr)$fatal(1,"PARAMS config write allowed while locked");
            if(cv && cr)begin
                if(ce !== (ci>=19))$fatal(1,"PARAMS cfg error mismatch");
                if(ci<19)begin golden[ci]=cw;initialized[ci]=1;cfgwrites=cfgwrites+1;end
                else cfgerrors=cfgerrors+1;
            end
            for(g=0;g<4;g=g+1)begin
                if(iv[g] && ir[g])begin
                    expected_payload[g][wr[g]]={it[g*16+:16],im[g*16+:16],incol[g*16+:16],ik[g*4+:4],idata[g*128+:128]};
                    bad=0;
                    for(l=0;l<4;l=l+1)begin
                        ix=axis ? incol[g*16+:16]+l : im[g*16+:16];coeff=0;
                        if(ik[g*4+l])begin
                            if(ix>=19 || (axis && incol[g*16+:2]!=0))bad=1;
                            else if(!initialized[ix])bad=1;
                            else coeff=golden[ix];
                        end
                        expected_coeff[g][wr[g]][l*78+:78]=coeff;
                    end
                    expected_bad[g][wr[g]]=bad;wr[g]=wr[g]+1;accepted=accepted+1;
                end
                for(l=0;l<4;l=l+1)actual_coeff[l*78+:78]={ore[g*4+l],oz[(g*4+l)*8+:8],osh[(g*4+l)*6+:6],omu[(g*4+l)*31+:31],ob[(g*4+l)*32+:32]};
                actual={oe[g],actual_coeff,ot[g*16+:16],om[g*16+:16],on[g*16+:16],ok[g*4+:4],od[g*128+:128]};
                if(held[g] && (!ov[g] || actual!==held_payload[g]))$fatal(1,"PARAMS changed stalled output island=%0d",g);
                held[g]=ov[g] && !orr[g];held_payload[g]=actual;if(held[g])stalls=stalls+1;
                if(ov[g] && orr[g])begin
                    if(rd[g]>=wr[g] || actual!=={expected_bad[g][rd[g]],expected_coeff[g][rd[g]],expected_payload[g][rd[g]]})
                        $fatal(1,"PARAMS response mismatch island=%0d entry=%0d axis=%0d actual=%h expected=%h",g,rd[g],axis,actual,{expected_bad[g][rd[g]],expected_coeff[g][rd[g]],expected_payload[g][rd[g]]});
                    if(oe[g])errors=errors+1;rd[g]=rd[g]+1;retired=retired+1;
                end
            end
        end
    end
    task automatic configure(input integer index,epoch);
        begin @(negedge clk);ci=index;cw=coefficient(index,epoch);cv=1;
            do @(posedge clk);while(!cr);@(negedge clk);cv=0;end
    endtask
    task automatic drain;
        begin
            while(|iv)begin @(negedge clk);iv=iv&~fired;orr=15;end
            wait(idle);@(negedge clk);
            for(integer a=0;a<4;a=a+1)if(rd[a]!=wr[a])$fatal(1,"PARAMS missing responses");
        end
    endtask
    task automatic traffic(input integer clocks,input bit bubbles);
        reg [31:0] v;
        begin
            for(integer c=0;c<clocks;c=c+1)begin
                @(negedge clk);
                for(integer a=0;a<4;a=a+1)begin
                    orr[a]=!bubbles || ((c+a*3)%19<12 && !(c>=70 && c<170));
                    if(!iv[a] || fired[a])begin
                        v=random_word();iv[a]=!bubbles || (v%5!=0);ik[a*4+:4]=v[19:16];
                        im[a*16+:16]=(v%24);incol[a*16+:16]=((v>>8)%7)*4;
                        if(c%71==0)incol[a*16+:16]=3;
                        if(c%83==0)im[a*16+:16]=16'hffff;
                        it[a*16+:16]=c+a*1000;
                        for(integer b=0;b<4;b=b+1)idata[(a*4+b)*32+:32]=random_word();
                    end
                end
            end
            drain();
        end
    endtask
    initial begin
        for(integer a=0;a<4;a=a+1)begin wr[a]=0;rd[a]=0;end
        // Vivado glbl在上电前100ns保持GSR，综合FDRE此时不接受正常参数有效标记写。
        // 与其他后处理TB一致：先等150ns，再同步复位5拍；不能在器件未启动时记黄金写入。
        // RTL和网表使用同样等待，后面的随机种子、握手、数值和错误检查完全不变。
        #150;
        repeat(5)@(negedge clk);resetn=1;
        for(integer c=0;c<19;c=c+1)if(c!=7)configure(c,0);
        configure(19,0);configure(65535,0);
        @(negedge clk);locked=1;axis=0;orr=15;
        traffic(256,0);traffic(800,1);
        @(negedge clk);axis=1;ci=7;cw=coefficient(7,99);cv=1;
        // 活动期间连续提出改写，必须始终不握手，也不能偷改已初始化的其他系数。
        traffic(900,1);cv=0;
        @(negedge clk);locked=0;
        for(integer c=0;c<19;c=c+1)configure(c,1);
        @(negedge clk);locked=1;axis=1;traffic(256,0);
        // 取消堵在流水内的请求；复位不清RAM，但清参数有效标志，旧内容不得重新生效。
        @(negedge clk);orr=0;iv=15;ik=16'hffff;im=0;incol=0;
        @(posedge clk);@(negedge clk);iv=0;repeat(6)@(negedge clk);
        for(integer a=0;a<4;a=a+1)begin canceled=canceled+wr[a]-rd[a];rd[a]=wr[a];end
        resetn=0;locked=0;repeat(4)@(negedge clk);resetn=1;locked=1;
        traffic(128,0);
        if(accepted!=retired+canceled || canceled!=4 || errors<100 || cfgwrites!=37 || cfgerrors!=2 || fullrate<400 || stalls<100)
            $fatal(1,"PARAMS insufficient coverage");
        $display("PARAMS_PASS accepted=%0d retired=%0d canceled=%0d errors=%0d writes=%0d cfgerrors=%0d stalls=%0d fullrate_cycles=%0d",accepted,retired,canceled,errors,cfgwrites,cfgerrors,stalls,fullrate);
        $finish;
    end
    initial begin #1000000;$fatal(1,"PARAMS TIMEOUT");end
endmodule
