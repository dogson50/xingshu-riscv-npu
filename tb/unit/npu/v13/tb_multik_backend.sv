// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 真实命令FIFO/executor/256DSP计算阵列+四路PSUM数值联合。
// 黄金值来自父任务的完整K和独立INT8数学函数，不用DUT的部分和/地址作为参考。
module tb_multik_backend;
    parameter integer STALL=1,BUBBLES=1,RESET_ABORT=0;
    localparam integer MN=64,MK=64,AW=8;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,jv=0,xv=0,dr=0,allow=1;
    reg [15:0] jm=0,jn=0,jtag=0,xk=0;
    reg [31:0] jk=0,xa=0,xb=0;
    reg xab=0,xbb=0,xcb=0;
    wire jr,xr,dv,busy,error;wire [15:0] dt;wire [2:0] ds;wire [31:0] kd;
    reg lbv=0,lbo=0,lbb=0,lv=0,lo=0,lb=0,lfv=0,lfo=0,lfb=0,lfe=0;
    reg disv=0,disop=0,disbank=0;
    reg [AW-1:0] la=0;reg [127:0] ld=0;
    wire lbr,lbe,lr,lfr,lfer,disr,dise;
    wire [3:0] cv,keep_commit,retained,loading,inuse;
    reg [3:0] ready=0;
    wire [511:0] cd;wire [15:0] keep;wire [63:0] om,on,ot;
    wire beat,packet;
    npu_v13_multik_backend #(.MAX_MN(MN),.MAX_K(MK),.TOTAL_SLOTS(16),.FIFO_DEPTH(4)) dut(
        .clk(clk),.resetn(resetn),.job_valid_i(jv),.job_ready_o(jr),.job_m_i(jm),.job_n_i(jn),.job_tag_i(jtag),.job_k_i(jk),
        .chunk_valid_i(xv),.chunk_ready_o(xr),.chunk_k_i(xk),.chunk_a_bank_i(xab),.chunk_b_bank_i(xbb),.chunk_c_bank_i(xcb),
        .chunk_a_base_i(xa),.chunk_b_base_i(xb),.done_valid_o(dv),.done_ready_i(dr),.done_tag_o(dt),.done_status_o(ds),.k_done_o(kd),
        .load_begin_valid_i(lbv),.load_begin_ready_o(lbr),.load_begin_error_o(lbe),.load_begin_operand_i(lbo),.load_begin_bank_i(lbb),
        .load_valid_i(lv),.load_ready_o(lr),.load_operand_i(lo),.load_bank_i(lb),.load_addr_i(la),.load_data_i(ld),
        .load_finish_valid_i(lfv),.load_finish_ready_o(lfr),.load_finish_error_o(lfer),
        .load_finish_operand_i(lfo),.load_finish_bank_i(lfb),.load_finish_error_i(lfe),
        .discard_valid_i(disv),.discard_ready_o(disr),.discard_error_o(dise),.discard_operand_i(disop),.discard_bank_i(disbank),
        .allow_beat_i(allow),.c_valid_o(cv),.c_ready_i(ready),.c_data_o(cd),.c_keep_o(keep),.c_m_o(om),.c_n_o(on),.c_tag_o(ot),
        .retained_o(retained),.loading_o(loading),.in_use_o(inuse),.input_beat_o(beat),.packet_issue_o(packet),
        .psum_commit_o(keep_commit),.busy_o(busy),.error_o(error));
    function automatic integer sample(input integer operand,epoch,axis,ki);
        integer t;
        begin
            t=(axis*7+ki*11+epoch*17+operand*19)%37;
            if(t==0)sample=-128;else if(t==1)sample=127;else sample=t-18;
        end
    endfunction
    integer cycles=0,ref_m=0,ref_n=0,ref_k=0,ref_epoch=0,ref_tag=0,expected_status=0;
    integer seen[0:MN*MN-1];
    integer elements=0,words=0,beats=0,packets=0,commits=0,chunk_count=0,fences=0;
    integer successes=0,rejections=0,overlap=0,stalls=0,done_holds=0,stall_until=0,abort_checks=0;
    integer expected_chunks=0,submitted_k=0,job_base_beats=0,job_base_packets=0,job_base_commits=0;
    reg ref_active=0;
    reg [3:0] held=0;
    reg [179:0] held_payload[0:3];
    reg dh=0;reg [50:0] dp;
    // 确定性反压/气泡。长暂停不会停时钟，也不会通过reset丢弃已承诺的结果。
    always @(negedge clk) if(resetn) begin
        allow=!BUBBLES || cycles%11!=3;
        for(integer g=0;g<4;g=g+1) ready[g]=(cycles>=stall_until) && (!STALL || (cycles+g*7)%19<13);
    end
    always @(posedge clk) begin
        if(!resetn) begin held=0;dh=0;ref_active=0;end
        else begin
            cycles=cycles+1;
            if(error)$fatal(1,"MULTIK backend protocol error");
            if(beat)beats=beats+1;if(packet)packets=packets+1;
            if(lv && lr && |inuse)overlap=overlap+1;
            if(xv && xr && xk!=0 && xk<=MK && xk<=ref_k-submitted_k)begin chunk_count=chunk_count+1;submitted_k=submitted_k+xk;end
            if(dut.fv && dut.fr)fences=fences+1;
            if(dut.cmdv && !dut.ctxr && !dut.u_psum_panel.active_r)$fatal(1,"command before PSUM context");
            if(xr && dut.psum_busy)$fatal(1,"next chunk allowed before PSUM drain");
            for(integer g=0;g<4;g=g+1)begin
                if(keep_commit[g])commits=commits+1;
                if(held[g] && (!cv[g] || {ot[g*16+:16],om[g*16+:16],on[g*16+:16],keep[g*4+:4],cd[g*128+:128]}!==held_payload[g]))
                    $fatal(1,"MULTIK final output changed while stalled");
                held[g]=cv[g] && !ready[g];
                held_payload[g]={ot[g*16+:16],om[g*16+:16],on[g*16+:16],keep[g*4+:4],cd[g*128+:128]};
                if(held[g])stalls=stalls+1;
                if(cv[g] && ready[g])begin: CHECK_WORD
                    integer row,col,mask,golden,actual,idx;
                    row=om[g*16+:16];col=on[g*16+:16];mask=0;
                    if(!ref_active || submitted_k!=ref_k || expected_status!=0)$fatal(1,"intermediate/rejected chunk leaked final output");
                    if(ot[g*16+:16]!==ref_tag[15:0] || row>=ref_m || col>=ref_n || col%4!=0 || (row/4)%4!=g)
                        $fatal(1,"MULTIK output identity/coordinate mismatch");
                    for(integer l=0;l<4;l=l+1) if(col+l<ref_n)mask=mask|(1<<l);
                    if(keep[g*4+:4]!==mask[3:0])$fatal(1,"MULTIK final mask mismatch");
                    words=words+1;
                    for(integer l=0;l<4;l=l+1)begin
                        if(mask&(1<<l))begin
                            golden=0;
                            for(integer k=0;k<ref_k;k=k+1) golden=golden+sample(0,ref_epoch,row,k)*sample(1,ref_epoch,col+l,k);
                            actual=$signed(cd[g*128+l*32+:32]);idx=row*MN+col+l;
                            if(actual!==golden || seen[idx])$fatal(1,"MULTIK numeric tag=%0d row=%0d col=%0d got=%0d expected=%0d duplicate=%0d",ref_tag,row,col+l,actual,golden,seen[idx]);
                            seen[idx]=1;elements=elements+1;
                        end else if(cd[g*128+l*32+:32]!==32'd0)$fatal(1,"invalid lane not zero");
                    end
                end
            end
            if(dh && (!dv || {dt,ds,kd}!==dp))$fatal(1,"parent response unstable");
            dh=dv && !dr;dp={dt,ds,kd};if(dh)done_holds=done_holds+1;
            if(dv)begin
                if(!ref_active || dt!==ref_tag[15:0] || ds!==expected_status[2:0])$fatal(1,"MULTIK parent response mismatch got=%0d want=%0d",ds,expected_status);
                if(dut.psum_busy || |cv || dut.backend_busy)$fatal(1,"parent done before full PSUM/backend drain");
                if(expected_status==0 && (elements!=ref_m*ref_n || words!=ref_m*((ref_n+3)/4) || kd!=ref_k))$fatal(1,"MULTIK early/incomplete success");
                if(dr) begin
                    if(ds==0)successes=successes+1;else rejections=rejections+1;
                    $display("MULTIK_JOB tag=%0d m=%0d n=%0d k=%0d status=%0d elements=%0d final_words=%0d",dt,ref_m,ref_n,ref_k,ds,elements,words);
                    ref_active=0;
                end
            end
        end
    end
    task automatic start_job(input integer m,n,k,epoch,tag,exp_status);
        begin
            @(negedge clk);ref_m=m;ref_n=n;ref_k=k;ref_epoch=epoch;ref_tag=tag;expected_status=exp_status;
            elements=0;words=0;submitted_k=0;ref_active=1;
            for(integer i=0;i<MN*MN;i=i+1)seen[i]=0;
            job_base_beats=beats;job_base_packets=packets;job_base_commits=commits;
            jm=m;jn=n;jk=k;jtag=tag;jv=1;
            do @(posedge clk);while(!jr);
            @(negedge clk);jv=0;
        end
    endtask
    task automatic send_chunk(input integer k,bank);
        begin
            @(negedge clk);xk=k;xab=bank;xbb=bank;xcb=bank;xv=1;
            do @(posedge clk);while(!xr);
            @(negedge clk);xv=0;
        end
    endtask
    task automatic discard(input integer operand,bank);
        begin
            @(negedge clk);disv=1;disop=operand;disbank=bank;
            do @(posedge clk);while(!disr);
            if(dise)$fatal(1,"MULTIK discard error");
            @(negedge clk);disv=0;
        end
    endtask
    task automatic load_panel(input integer operand,bank,epoch,kbase);
        begin
            if(retained[operand*2+bank])discard(operand,bank);
            @(negedge clk);lbv=1;lbo=operand;lbb=bank;
            do @(posedge clk);while(!lbr);
            if(lbe)$fatal(1,"MULTIK load begin error");
            @(negedge clk);lbv=0;lo=operand;lb=bank;
            for(integer block=0;block<MN/16;block=block+1)for(integer k=0;k<MK;k=k+1)begin
                lv=1;la=block*MK+k;
                for(integer l=0;l<16;l=l+1)ld[l*8+:8]=sample(operand,epoch,block*16+l,kbase+k);
                do @(posedge clk);while(!lr);
                @(negedge clk);
            end
            lv=0;lfv=1;lfo=operand;lfb=bank;
            do @(posedge clk);while(!lfr);
            if(lfer)$fatal(1,"MULTIK load finish error");
            @(negedge clk);lfv=0;
        end
    endtask
    task automatic load_pair(input integer bank,epoch,kbase);
        begin load_panel(0,bank,epoch,kbase);load_panel(1,bank,epoch,kbase);end
    endtask
    task automatic retire_job;
        begin
            wait(dv);repeat(23)@(negedge clk);
            if(jr)$fatal(1,"new parent allowed during stalled done");
            dr=1;@(posedge clk);@(negedge clk);dr=0;
            if(busy)$fatal(1,"busy after parent retirement");
        end
    endtask
    task automatic matrix(input integer m,n,k0,k1,k2,epoch,tag,longstall);
        integer nc,total,kbase,cur;
        begin
            nc=(k2>0 ? 3 : (k1>0 ? 2 : 1));total=k0+k1+k2;
            load_pair(0,epoch,0);start_job(m,n,total,epoch,tag,0);kbase=0;
            for(integer c=0;c<nc;c=c+1)begin
                cur=(c==0 ? k0 : (c==1 ? k1 : k2));
                if(c==nc-1 && longstall)stall_until=cycles+950;
                send_chunk(cur,c%2);kbase=kbase+cur;
                // 与当前计算同时装载另一bank；不复制每个M/N小输出块的A/B。
                if(c+1<nc)load_pair((c+1)%2,epoch,kbase);
            end
            retire_job();
            if(beats-job_base_beats!=((m+15)/16)*((n+15)/16)*total || packets-job_base_packets!=((m+15)/16)*((n+15)/16)*nc)
                $fatal(1,"MULTIK core beat/packet conservation");
            if(commits-job_base_commits!=((m+3)/4)*((n+3)/4)*4*nc)$fatal(1,"MULTIK PSUM commit conservation");
        end
    endtask
    initial begin
        // Unisim DSP模型有100ns全局GSR，原语/行为测试必须同样跨过它。
        #160;repeat(6)@(negedge clk);resetn=1;
        if(RESET_ABORT)begin
            load_pair(0,9,0);start_job(33,35,1,9,16'h7000,0);stall_until=cycles+100000;
            send_chunk(1,0);wait(|cv);repeat(7)@(negedge clk);
            if(dv)$fatal(1,"done while final outputs blocked");
            resetn=0;repeat(6)@(negedge clk);stall_until=0;resetn=1;abort_checks=abort_checks+1;
            repeat(30)@(negedge clk);if(|cv || dv || busy)$fatal(1,"aborted parent leaked data/status");
        end
        matrix(33,35,64,64,17,1,16'h7100,0);
        matrix(17,19,32,32,1,2,16'h7101,1);
        matrix(64,64,1,1,3,3,16'h7102,1);
        matrix(1,1,1,0,0,4,16'h7103,0);
        // 父参数/分块参数非法必须返回一次错误，不能把0编码成超长K或静默截断。
        start_job(0,16,3,0,16'h7200,1);retire_job();
        start_job(16,16,3,0,16'h7201,2);send_chunk(0,0);retire_job();
        start_job(16,16,3,0,16'h7202,2);send_chunk(4,0);retire_job();
        start_job(16,16,100,0,16'h7203,2);send_chunk(65,0);retire_job();
        // 后端对非法BRAM base报错后，仍须走PSUM空栅栏，而不是挂住上下文。
        start_job(16,16,1,0,16'h7204,3);xa=32'hffffffff;send_chunk(1,0);retire_job();xa=0;
        matrix(5,7,2,3,0,5,16'h7104,0);
        repeat(30)@(negedge clk);
        if(successes!=5 || rejections!=5 || overlap==0 || done_holds==0 || stalls==0 || (RESET_ABORT && abort_checks!=1))
            $fatal(1,"MULTIK coverage missing");
        $display("MULTIK_PASS successes=%0d rejections=%0d chunks=%0d fences=%0d beats=%0d packets=%0d commits=%0d overlapping_loads=%0d stalls=%0d done_holds=%0d reset_abort=%0d",successes,rejections,chunk_count,fences,beats,packets,commits,overlap,stalls,done_holds,abort_checks);
        $finish;
    end
    initial begin #2000000;$fatal(1,"MULTIK TIMEOUT");end
endmodule
