// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 默认容量独立压力联仿；与快速TB保留同样端口契约/黄金算术，执行更大的测试向量。
// MAX_MN=128/MAX_K=512；不得用32x32仿真或仅有默认容量综合替代本数值验收。
// 依次计算127x1025x125、117x517x127、128x3x128和1x1x1（M*K*N）。
// 仍检查动态shape、两种系数轴、两bank保护、读算重叠、反压、错误和复位取消。
// 黄金模型按完整K独立计算，并独立实现整数舍入；不以DUT输出/内部RAM作为参考。
module tb_gemm_feature_capacity;
    parameter integer STALL=1,RESET_ABORT=0;
    localparam MN=128,MK=512,AW=12;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,jv=0,xv=0,dr=0,allow=1,jbank=0,jaxis=0;
    reg [15:0] jm=0,jn=0,jtag=0,xk=0;reg [31:0] jk=0;reg xb=0;
    wire jr,xr,dv,db,busy,error;wire [15:0] dt;wire [2:0] ds;wire [31:0] kd;
    reg lbv=0,lbo=0,lbb=0,lv=0,lo=0,lb=0,lfv=0,lfo=0,lfb=0;
    reg disv=0,disop=0,disbank=0;reg [AW-1:0] la=0;reg [127:0] ld=0;
    wire lbr,lbe,lr,lfr,lfer,disr,dise;wire [3:0] retained,loading,inuse,pc,fc;wire beat,packet;
    reg cfgv=0;wire cfgr,cfge;reg [15:0] cfgi=0;reg [77:0] cfgword=0;
    reg frelv=0,frelb=0;wire frelr;wire [1:0] fr,ff;
    reg rv=0,rb=0,rr=0;reg [15:0] rm=0,rn=0;wire rready,ov,ob,oe;wire [31:0] od;wire [3:0] ok;wire [15:0] om,on,ot;
    npu_v13_gemm_feature_backend #(.MAX_MN(MN),.MAX_K(MK),.TOTAL_SLOTS(16),.FIFO_DEPTH(4)) dut(
        .clk(clk),.resetn(resetn),.job_valid_i(jv),.job_ready_o(jr),.job_m_i(jm),.job_n_i(jn),.job_tag_i(jtag),.job_k_i(jk),.job_feature_bank_i(jbank),.job_quant_axis_i(jaxis),
        .chunk_valid_i(xv),.chunk_ready_o(xr),.chunk_k_i(xk),.chunk_a_bank_i(xb),.chunk_b_bank_i(xb),.chunk_c_bank_i(xb),.chunk_a_base_i(32'd0),.chunk_b_base_i(32'd0),
        .done_valid_o(dv),.done_ready_i(dr),.done_tag_o(dt),.done_status_o(ds),.done_feature_bank_o(db),.k_done_o(kd),
        .cfg_valid_i(cfgv),.cfg_ready_o(cfgr),.cfg_error_o(cfge),.cfg_index_i(cfgi),.cfg_bias_i(cfgword[31:0]),.cfg_multiplier_i(cfgword[62:32]),
        .cfg_shift_i(cfgword[68:63]),.cfg_zero_point_i(cfgword[76:69]),.cfg_relu_i(cfgword[77]),
        .load_begin_valid_i(lbv),.load_begin_ready_o(lbr),.load_begin_error_o(lbe),.load_begin_operand_i(lbo),.load_begin_bank_i(lbb),
        .load_valid_i(lv),.load_ready_o(lr),.load_operand_i(lo),.load_bank_i(lb),.load_addr_i(la),.load_data_i(ld),
        .load_finish_valid_i(lfv),.load_finish_ready_o(lfr),.load_finish_error_o(lfer),.load_finish_operand_i(lfo),.load_finish_bank_i(lfb),.load_finish_error_i(1'b0),
        .discard_valid_i(disv),.discard_ready_o(disr),.discard_error_o(dise),.discard_operand_i(disop),.discard_bank_i(disbank),.allow_beat_i(allow),
        .retained_o(retained),.loading_o(loading),.in_use_o(inuse),.feature_ready_o(fr),.feature_free_o(ff),
        .feature_release_valid_i(frelv),.feature_release_ready_o(frelr),.feature_release_bank_i(frelb),
        .rd_valid_i(rv),.rd_ready_o(rready),.rd_bank_i(rb),.rd_m_i(rm),.rd_n_i(rn),.rd_valid_o(ov),.rd_ready_i(rr),
        .rd_data_o(od),.rd_keep_o(ok),.rd_bank_o(ob),.rd_error_o(oe),.rd_m_o(om),.rd_n_o(on),.rd_tag_o(ot),
        .input_beat_o(beat),.packet_issue_o(packet),.psum_commit_o(pc),.feature_commit_o(fc),.busy_o(busy),.error_o(error));
    function automatic integer sample(input integer operand,epoch,axis,ki);
        integer t;begin t=(axis*7+ki*11+epoch*17+operand*19)%37;
            if(t==0)sample=-128;else if(t==1)sample=127;else sample=t-18;end
    endfunction
    function automatic [77:0] coefficient(input integer idx);
        reg [31:0] b;reg [30:0] mu;reg [5:0] sh;reg [7:0] z;reg re;
        begin b=idx*73-1600;mu=31'h40000000+idx*76543;sh=36+idx%5;z=idx*7-90;re=idx%2;
            coefficient={re,z,sh,mu,b};end
    endfunction
    function automatic [7:0] golden(input integer m,n,k,epoch,axis);
        reg signed [31:0] acc,b;reg [77:0] c;reg signed [7:0] z;
        reg signed [63:0] sum,p,q;reg [63:0] mag,quot,remn,half;integer sh;
        begin acc=0;for(integer t=0;t<k;t=t+1)acc=acc+sample(0,epoch,m,t)*sample(1,epoch,n,t);
            c=coefficient(axis ? n : m);b=c[31:0];z=c[76:69];sh=c[68:63];sum=acc;sum=sum+b;
            p=sum*$signed({1'b0,c[62:32]});mag=p<0 ? -p : p;quot=mag>>sh;
            if(sh>0)begin remn=mag&((64'd1<<sh)-1);half=64'd1<<(sh-1);if(remn>=half)quot=quot+1;end
            q=p<0 ? -$signed(quot) : $signed(quot);q=q+z;
            if(c[77] && q<z)q=z;if(q>127)q=127;if(q < -128)q=-128;golden=q[7:0];end
    endfunction
    integer gm[0:1],gn[0:1],gk[0:1],ge[0:1],ga[0:1],gt[0:1];reg [1:0] live=0;
    integer cycles=0,beats=0,packets=0,commits=0,requests=0,responses=0,overlap=0,load_overlap=0,holds=0,successes=0,failures=0,blocked=0,ii1=0;
    // 以实际握手证明高地址/最大K覆盖；不能只从配置常量推断曾使用容量末端。
    integer high_load=0,high_coeff=0,high_read=0,max_k_chunks=0;
    // 只缓存尚未返回的请求；累计wp/rp不回绕，环形槽可验证任意长扫描，避免巨型TB静态数组。
    // 槽满必须fatal，不能覆盖未比较的期望值；逐响应黄金检查和累计覆盖计数保持不变。
    reg [85:0] expected[0:255];integer wp=0,rp=0,last_request=-10,last_commit=-10;
    reg rh=0,dh=0,hold_read=0,read_fullrate=0;reg [85:0] rheld;reg [51:0] dheld;
    always @(negedge clk)if(resetn)begin allow=!STALL || cycles%11!=3;rr=!hold_read && (read_fullrate || !STALL || cycles%13<8);end
    always @(posedge clk)begin
        if(!resetn)begin rh=0;dh=0;end
        else begin
            cycles=cycles+1;if(error)$fatal(1,"GEMM_FEATURE backend protocol error");
            if(lv && lr && la==4095)high_load=high_load+1;
            if(cfgv && cfgr && cfgi==127)high_coeff=high_coeff+1;
            if(xv && xr && xk==512)max_k_chunks=max_k_chunks+1;
            if(beat)beats=beats+1;if(packet)packets=packets+1;
            if(lv && lr && |inuse)load_overlap=load_overlap+1;
            for(integer g=0;g<4;g=g+1)if(fc[g])begin
                commits=commits+1;last_commit=cycles;if(fr[jbank])$fatal(1,"feature READY before commit");end
            if(dh && (!dv || {dt,ds,db,kd}!==dheld))$fatal(1,"done changed while stalled");
            dh=dv && !dr;dheld={dt,ds,db,kd};if(dh)holds=holds+1;
            if(dv && ds==0 && (!fr[db] || cycles<=last_commit))$fatal(1,"done before write-visible fence");
            if(rh && (!ov || {ob,oe,ot,om,on,ok,od}!==rheld))$fatal(1,"read response changed while stalled");
            rh=ov && !rr;rheld={ob,oe,ot,om,on,ok,od};
            if(rv && rready)begin: QUEUE
                reg bad;reg [3:0] mask;reg [31:0] data;reg [15:0] tag;
                if(wp-rp>=256)$fatal(1,"capacity scoreboard overflow");
                if(rm==127 && rn==124)high_read=high_read+1;
                bad=!live[rb] || rm>=gm[rb] || rn>=gn[rb] || rn%4!=0;mask=0;data=0;tag=live[rb] ? gt[rb] : 0;
                for(integer l=0;l<4;l=l+1)if(!bad && rn+l<gn[rb])begin mask[l]=1;data[l*8+:8]=golden(rm,rn+l,gk[rb],ge[rb],ga[rb]);end
                expected[wp%256]={rb,bad,tag,rm,rn,mask,data};wp=wp+1;requests=requests+1;
                if(|fc || |inuse)overlap=overlap+1;if(cycles==last_request+1)ii1=ii1+1;last_request=cycles;
            end
            if(ov && rr)begin
                if(rp==wp || {ob,oe,ot,om,on,ok,od}!==expected[rp%256])$fatal(1,"GEMM_FEATURE read mismatch index=%0d actual=%h expected=%h",rp,{ob,oe,ot,om,on,ok,od},expected[rp%256]);
                rp=rp+1;responses=responses+1;
            end
        end
    end
    task automatic cfg_all(input integer missing);
        begin for(integer i=0;i<MN;i=i+1)if(i!=missing)begin
            @(negedge clk);cfgv=1;cfgi=i;cfgword=coefficient(i);do @(posedge clk);while(!cfgr);
            if(cfge)$fatal(1,"cfg rejected");@(negedge clk);cfgv=0;end end
    endtask
    task automatic discard(input integer operand,bank);
        begin @(negedge clk);disv=1;disop=operand;disbank=bank;do @(posedge clk);while(!disr);
            if(dise)$fatal(1,"discard error");@(negedge clk);disv=0;end
    endtask
    task automatic load_panel(input integer operand,bank,epoch,kbase);
        begin if(retained[operand*2+bank])discard(operand,bank);
            @(negedge clk);lbv=1;lbo=operand;lbb=bank;do @(posedge clk);while(!lbr);
            if(lbe)$fatal(1,"load begin error");@(negedge clk);lbv=0;lo=operand;lb=bank;
            for(integer block=0;block<MN/16;block=block+1)for(integer k=0;k<MK;k=k+1)begin
                lv=1;la=block*MK+k;for(integer l=0;l<16;l=l+1)ld[l*8+:8]=sample(operand,epoch,block*16+l,kbase+k);
                do @(posedge clk);while(!lr);@(negedge clk);end
            lv=0;lfv=1;lfo=operand;lfb=bank;do @(posedge clk);while(!lfr);
            if(lfer)$fatal(1,"load finish error");@(negedge clk);lfv=0;end
    endtask
    task automatic load_pair(input integer bank,epoch,kbase);
        begin load_panel(0,bank,epoch,kbase);load_panel(1,bank,epoch,kbase);end
    endtask
    task automatic start_job(input integer bank,m,n,k,epoch,axis,tag);
        begin @(negedge clk);jm=m;jn=n;jk=k;jtag=tag;jbank=bank;jaxis=axis;jv=1;
            do @(posedge clk);while(!jr);@(negedge clk);jv=0;
            gm[bank]=m;gn[bank]=n;gk[bank]=k;ge[bank]=epoch;ga[bank]=axis;gt[bank]=tag;live[bank]=0;end
    endtask
    task automatic chunk(input integer k,bank);
        begin @(negedge clk);xk=k;xb=bank;xv=1;do @(posedge clk);while(!xr);@(negedge clk);xv=0;end
    endtask
    task automatic finish_job(input integer status);
        begin wait(dv);@(negedge clk);
            if(ds!==status[2:0] || dt!==jtag || db!==jbank)$fatal(1,"GEMM_FEATURE done mismatch status=%0d expected=%0d",ds,status);
            if(status==0)begin successes=successes+1;live[jbank]=1;if(kd!==jk)$fatal(1,"full K not completed");end
            else begin failures=failures+1;if(!ff[jbank] || fr[jbank])$fatal(1,"failed feature bank published");end
            repeat(23)@(negedge clk);if(jr)$fatal(1,"parent accepted during held done");
            dr=1;@(posedge clk);@(negedge clk);dr=0;end
    endtask
    task automatic matrix(input integer bank,m,n,k0,k1,k2,epoch,axis,tag);
        integer total,kbase,cur,nc,basebeats,basepackets,basecommits;
        begin total=k0+k1+k2;nc=k2>0 ? 3 : (k1>0 ? 2 : 1);
            basebeats=beats;basepackets=packets;basecommits=commits;
            load_pair(0,epoch,0);start_job(bank,m,n,total,epoch,axis,tag);kbase=0;
            for(integer c=0;c<nc;c=c+1)begin cur=c==0 ? k0 : (c==1 ? k1 : k2);chunk(cur,c%2);kbase=kbase+cur;
                if(c+1<nc)load_pair((c+1)%2,epoch,kbase);end
            finish_job(0);
            if(beats-basebeats!=((m+15)/16)*((n+15)/16)*total || packets-basepackets!=((m+15)/16)*((n+15)/16)*nc || commits-basecommits!=m*((n+3)/4))
                $fatal(1,"GEMM_FEATURE throughput/event conservation");end
    endtask
    task automatic scan(input integer bank,repeats);
        begin for(integer r=0;r<repeats;r=r+1)for(integer m=gm[bank]-1;m>=0;m=m-1)for(integer n=0;n<gn[bank];n=n+4)begin
            @(negedge clk);rv=1;rb=bank;rm=m;rn=n;do @(posedge clk);while(!rready);end
            @(negedge clk);rv=0;wait(rp==wp);@(negedge clk);end
    endtask
    task automatic release_feature(input integer bank);
        begin @(negedge clk);frelb=bank;frelv=1;do @(posedge clk);while(!frelr);@(negedge clk);frelv=0;live[bank]=0;end
    endtask
    initial begin
        #160;repeat(6)@(negedge clk);resetn=1;cfg_all(-1);
        if(RESET_ABORT)begin
            load_pair(0,9,0);start_job(0,29,21,16,9,0,16'h6000);chunk(16,0);
            wait(beat);repeat(2)@(negedge clk);resetn=0;repeat(6)@(negedge clk);resetn=1;
            repeat(30)@(negedge clk);if(dv || fr!=0 || busy)$fatal(1,"reset leaked result");cfg_all(-1);
        end
        matrix(0,127,125,512,512,1,1,0,16'h6100);
        fork
            matrix(1,117,127,257,257,3,2,1,16'h6101);
            scan(0,3);
        join
        // 两个READY bank都不能被新任务抢占，即使输入A/B可用也不能先发packet。
        @(negedge clk);jbank=0;jv=1;
        repeat(31)begin @(posedge clk);if(jr || packet)$fatal(1,"packet without free feature capacity");blocked=blocked+1;end
        @(negedge clk);jv=0;
        read_fullrate=1;scan(1,1);read_fullrate=0;release_feature(0);
        matrix(0,128,128,3,0,0,3,0,16'h6102);scan(0,1);release_feature(0);release_feature(1);
        start_job(0,0,16,1,0,0,16'h6200);finish_job(1);
        start_job(0,16,16,1,0,0,16'h6201);chunk(0,0);finish_job(2);
        // 清系数有效标记，故意缺少通道7；错误必须排空并归还bank，不能永远停住。
        @(negedge clk);resetn=0;repeat(6)@(negedge clk);resetn=1;cfg_all(7);
        load_pair(0,4,0);start_job(0,8,8,2,4,0,16'h6202);chunk(2,0);finish_job(5);
        cfg_all(-1);matrix(0,1,1,1,0,0,5,1,16'h6103);scan(0,1);release_feature(0);
        if(successes!=4 || failures!=3 || requests!=responses || overlap==0 || load_overlap==0 || holds==0 || blocked!=31 || ii1<100)
            $fatal(1,"GEMM_FEATURE coverage missing");
        if(high_load==0 || high_coeff==0 || high_read==0 || max_k_chunks!=2)
            $fatal(1,"default capacity high-address/max-K coverage missing");
        $display("CAPACITY_COVERAGE MN=%0d MK=%0d last_load=%0d coeff127=%0d read127_124=%0d chunks512=%0d",MN,MK,high_load,high_coeff,high_read,max_k_chunks);
        $display("GEMM_FEATURE_CAPACITY_PASS successes=%0d failures=%0d beats=%0d packets=%0d commits=%0d reads=%0d overlap=%0d load_overlap=%0d held_done=%0d capacity_blocked=%0d ii1_reads=%0d reset_abort=%0d",successes,failures,beats,packets,commits,requests,overlap,load_overlap,holds,blocked,ii1,RESET_ABORT);
        $finish;
    end
    // 只增加可观测性，不改激励、黄金函数或计分板；避免重负载无日志被误判死锁。
    initial forever begin
        #50000;
        $display("CAPACITY_PROGRESS time=%0t cycles=%0d beats=%0d packets=%0d commits=%0d reads=%0d done=%0d",$time,cycles,beats,packets,commits,requests,successes);
    end
    initial begin #10000000;$fatal(1,"GEMM_FEATURE TIMEOUT");end
endmodule
