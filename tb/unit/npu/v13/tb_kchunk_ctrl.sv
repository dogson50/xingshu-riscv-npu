// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 独立控制单测：以可反压的后端/PSUM握手模型检查顺序，不执行矩阵乘。
// 65537总K/64容量实际走1025个chunk，验证32bit剩余量没有截为16bit。
module tb_kchunk_ctrl;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,jv=0,xv=0,ctxr=0,cmdr=0,rv=0,er=0,fv=0,fe=0,dr=0;
    reg [15:0] jm=17,jn=19,jt=0,xk=0,rt=0;
    reg [31:0] jk=0;reg [2:0] rs=0;
    wire jr,xr,ctxv,first,last,cmdv,rr,ev,fr,dv,busy,ab,bb,cb;
    wire [15:0] cm,cn,ct,bm,bn,bk,bt,dt;wire [31:0] ap,bp,kdone;wire [2:0] ds;
    npu_v13_kchunk_ctrl #(.MAX_M(64),.MAX_N(64),.MAX_K(64)) dut(
        .clk(clk),.resetn(resetn),.job_valid_i(jv),.job_ready_o(jr),.job_m_i(jm),.job_n_i(jn),.job_tag_i(jt),.job_k_i(jk),
        .chunk_valid_i(xv),.chunk_ready_o(xr),.chunk_k_i(xk),.chunk_a_bank_i(1'b1),.chunk_b_bank_i(1'b0),.chunk_c_bank_i(1'b1),
        .chunk_a_base_i(32'd7),.chunk_b_base_i(32'd11),.ctx_valid_o(ctxv),.ctx_ready_i(ctxr),.ctx_m_o(cm),.ctx_n_o(cn),.ctx_tag_o(ct),
        .ctx_first_o(first),.ctx_final_o(last),.cmd_valid_o(cmdv),.cmd_ready_i(cmdr),.cmd_m_o(bm),.cmd_n_o(bn),.cmd_k_o(bk),.cmd_tag_o(bt),
        .cmd_a_bank_o(ab),.cmd_b_bank_o(bb),.cmd_c_bank_o(cb),.cmd_a_base_o(ap),.cmd_b_base_o(bp),
        .rsp_valid_i(rv),.rsp_ready_o(rr),.rsp_tag_i(rt),.rsp_status_i(rs),.end_valid_o(ev),.end_ready_i(er),
        .fence_valid_i(fv),.fence_ready_o(fr),.fence_error_i(fe),.done_valid_o(dv),.done_ready_i(dr),.done_tag_o(dt),.done_status_o(ds),
        .k_done_o(kdone),.busy_o(busy));
    integer total=0,completed=0,commands=0,responses=0,closes=0,fences=0,jobs=0;
    always @(posedge clk) if(resetn)begin
        if(cmdv && cmdr)commands=commands+1;
        if(rv && rr)responses=responses+1;
        if(ev && er)closes=closes+1;
        if(fv && fr)fences=fences+1;
        if(xr && (cmdv || rr || ev || fr))$fatal(1,"KCHUNK overlapped sequence phases");
    end
    task automatic job(input integer k,tag);
        begin
            @(negedge clk);total=k;completed=0;jk=k;jt=tag;jv=1;
            do @(posedge clk);while(!jr);
            @(negedge clk);jv=0;
        end
    endtask
    task automatic descriptor(input integer k);
        begin
            @(negedge clk);xk=k;xv=1;do @(posedge clk);while(!xr);
            @(negedge clk);xv=0;
        end
    endtask
    task automatic chunk(input integer k,backend_error,tag_error,psum_error);
        begin
            descriptor(k);wait(ctxv);
            if({cm,cn,ct}!=={jm,jn,jt} || first!==(completed==0) || last!==(completed+k==total))$fatal(1,"KCHUNK context");
            repeat((commands%3)+1)begin @(negedge clk);if(cmdv || xr || kdone!=completed)$fatal(1,"KCHUNK context stall");end
            ctxr=1;@(posedge clk);@(negedge clk);ctxr=0;
            wait(cmdv);
            if({bm,bn,bt}!=={jm,jn,jt} || bk!=k || !ab || bb || !cb || ap!=7 || bp!=11)$fatal(1,"KCHUNK command payload");
            repeat((commands%4)+1)begin @(negedge clk);if(!cmdv || kdone!=completed)$fatal(1,"KCHUNK command stall");end
            cmdr=1;@(posedge clk);@(negedge clk);cmdr=0;
            wait(rr);repeat(2)@(negedge clk);rv=1;rt=jt+tag_error;rs=backend_error;
            @(posedge clk);@(negedge clk);rv=0;
            wait(ev);repeat(3)begin @(negedge clk);if(kdone!=completed || xr || dv)$fatal(1,"KCHUNK close stall");end
            er=1;@(posedge clk);@(negedge clk);er=0;
            wait(fr);repeat(4)begin @(negedge clk);if(kdone!=completed || xr || dv)$fatal(1,"KCHUNK fence stall");end
            fv=1;fe=psum_error;@(posedge clk);@(negedge clk);fv=0;fe=0;
            if(backend_error==0 && tag_error==0 && psum_error==0)completed=completed+k;
            if(kdone!=completed)$fatal(1,"KCHUNK progress truncation");
        end
    endtask
    task automatic done(input integer status);
        begin
            wait(dv);repeat(5)begin
                @(negedge clk);if(ds!==status[2:0] || dt!==jt || kdone!=completed || jr || xr)$fatal(1,"KCHUNK response/status");
            end
            dr=1;@(posedge clk);@(negedge clk);dr=0;jobs=jobs+1;
            if(busy || !jr)$fatal(1,"KCHUNK not idle");
        end
    endtask
    initial begin
        repeat(6)@(negedge clk);resetn=1;
        job(65537,1);for(integer i=0;i<1024;i=i+1)chunk(64,0,0,0);chunk(1,0,0,0);done(0);
        job(1,2);chunk(1,0,0,0);done(0);
        job(0,3);done(1);
        job(3,4);descriptor(0);done(2);
        job(3,5);descriptor(4);done(2);
        job(100,6);descriptor(65);done(2);
        job(1,7);chunk(1,4,0,0);done(3);
        job(1,8);chunk(1,0,1,0);done(3);
        job(1,9);chunk(1,0,0,1);done(4);
        // CONTEXT阻塞中复位取消，不得凭旧valid继续发命令。
        job(3,10);descriptor(3);wait(ctxv);@(negedge clk);resetn=0;
        repeat(5)@(negedge clk);resetn=1;repeat(4)@(negedge clk);
        if(ctxv || cmdv || dv || busy || !jr)$fatal(1,"KCHUNK reset cancel");
        job(1,11);chunk(1,0,0,0);done(0);
        if(commands!=responses || responses!=closes || closes!=fences || jobs!=10)$fatal(1,"KCHUNK conservation");
        $display("KCHUNK_PASS total_k_test=65537 commands=%0d responses=%0d fences=%0d jobs=%0d",commands,responses,fences,jobs);$finish;
    end
    initial begin #2000000;$fatal(1,"KCHUNK TIMEOUT");end
endmodule
