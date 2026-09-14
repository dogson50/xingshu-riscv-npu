// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 不等长/非2幂容量panel映射单测：32x48容量、29x37动态shape、三次遍历。
// 错误坐标/tag/keep不得截断覆盖合法PSUM，错误chunk之后以加0读回全部有效位置验证。
module tb_psum_panel;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,ctxv=0,first=0,final_chunk=0,endv=0,doner=0;
    reg [15:0] m=29,n=37,tag=16'h5a5a;
    wire ctxr,endr,donev,donee,busy;
    reg [3:0] cv=0,ready=0;wire [3:0] cr,ov,commit;
    reg [511:0] cd=0;reg [15:0] keep=0;reg [63:0] row=0,col=0,tags=0;
    wire [511:0] od;wire [15:0] ok;wire [63:0] om,on,ot;
    npu_v13_psum_panel #(.MAX_M(32),.MAX_N(48)) dut(
        .clk(clk),.resetn(resetn),.ctx_valid_i(ctxv),.ctx_ready_o(ctxr),.ctx_m_i(m),.ctx_n_i(n),.ctx_tag_i(tag),
        .ctx_first_i(first),.ctx_final_i(final_chunk),.c_valid_i(cv),.c_ready_o(cr),.c_data_i(cd),.c_keep_i(keep),.c_m_i(row),.c_n_i(col),.c_tag_i(tags),
        .end_valid_i(endv),.end_ready_o(endr),.done_valid_o(donev),.done_ready_i(doner),.done_error_o(donee),
        .out_valid_o(ov),.out_ready_i(ready),.out_data_o(od),.out_keep_o(ok),.out_m_o(om),.out_n_o(on),.out_tag_o(ot),
        .commit_o(commit),.busy_o(busy));
    integer cycles=0,accepted=0,committed=0,outputs=0,errors=0,stalls=0;
    integer pass_outputs=0,seen[0:32*48-1];reg expect_output=0,force_stall=0;
    reg [3:0] held=0;reg [179:0] payload[0:3];
    function automatic integer value(input integer part,r,c);
        if(part==0)value=r*113+c*7-1900;
        else if(part==1)value=700-r*13-c*5;
        else value=0;
    endfunction
    always @(negedge clk)if(resetn)for(integer g=0;g<4;g=g+1)ready[g]=!force_stall && (cycles+g*3)%13<8;
    always @(posedge clk)if(!resetn)held=0;else begin
        cycles=cycles+1;
        for(integer g=0;g<4;g=g+1)begin
            if(cv[g] && cr[g])accepted=accepted+1;
            if(commit[g])committed=committed+1;
            if(held[g] && (!ov[g] || payload[g]!=={ot[g*16+:16],om[g*16+:16],on[g*16+:16],ok[g*4+:4],od[g*128+:128]}))$fatal(1,"PANEL output stall corruption");
            held[g]=ov[g] && !ready[g];payload[g]={ot[g*16+:16],om[g*16+:16],on[g*16+:16],ok[g*4+:4],od[g*128+:128]};
            if(held[g])stalls=stalls+1;
            if(ov[g] && ready[g])begin: CHECK
                integer r,c,mask,idx,expected;
                r=om[g*16+:16];c=on[g*16+:16];mask=0;
                if(!expect_output || r>=29 || c>=37 || c%4!=0 || (r/4)%4!=g || ot[g*16+:16]!=tag)$fatal(1,"PANEL unexpected identity");
                for(integer l=0;l<4;l=l+1)if(c+l<37)mask=mask|(1<<l);
                if(ok[g*4+:4]!==mask[3:0])$fatal(1,"PANEL keep");
                for(integer l=0;l<4;l=l+1)if(mask&(1<<l))begin
                    idx=r*48+c+l;expected=value(0,r,c+l)+value(1,r,c+l);
                    if(od[g*128+l*32+:32]!==expected[31:0] || seen[idx])$fatal(1,"PANEL alias/numeric r=%0d c=%0d",r,c+l);
                    seen[idx]=1;
                end
                outputs=outputs+1;pass_outputs=pass_outputs+1;
            end
        end
    end
    task automatic start_context(input bit f,z);
        begin
            @(negedge clk);first=f;final_chunk=z;ctxv=1;do @(posedge clk);while(!ctxr);
            @(negedge clk);ctxv=0;pass_outputs=0;expect_output=z;
            for(integer i=0;i<32*48;i=i+1)seen[i]=0;
        end
    endtask
    task automatic word(input integer g,r,c,part,mask,t);
        begin
            @(negedge clk);cv=1<<g;row[g*16+:16]=r;col[g*16+:16]=c;tags[g*16+:16]=t;keep[g*4+:4]=mask;
            for(integer l=0;l<4;l=l+1)cd[g*128+l*32+:32]=value(part,r,c+l);
            do @(posedge clk);while(!cr[g]);
            @(negedge clk);cv=0;
        end
    endtask
    task automatic scan(input integer part);
        integer mask;
        begin
            for(integer r=0;r<32;r=r+1)for(integer c=0;c<40;c=c+4)begin
                mask=0;for(integer l=0;l<4;l=l+1)if(r<29 && c+l<37)mask=mask|(1<<l);
                word((r/4)%4,r,c,part,mask,tag);
            end
        end
    endtask
    task automatic close_chunk(input integer expected_error,expected_words);
        begin
            @(negedge clk);endv=1;do @(posedge clk);while(!endr);
            @(negedge clk);endv=0;wait(donev);
            repeat(5)begin @(negedge clk);if(ctxr || !donev || donee!==expected_error[0])$fatal(1,"PANEL fence/status");end
            if(pass_outputs!=expected_words)$fatal(1,"PANEL output count got=%0d expected=%0d",pass_outputs,expected_words);
            if(donee)errors=errors+1;
            doner=1;@(posedge clk);@(negedge clk);doner=0;expect_output=0;
            if(!ctxr || busy)$fatal(1,"PANEL context not released");
        end
    endtask
    initial begin
        #160;repeat(5)@(negedge clk);resetn=1;
        start_context(1,0);scan(0);close_chunk(0,0);
        start_context(0,1);scan(1);close_chunk(0,290);
        // 七个错误beat应接收并报错，但不能修改任何合法位置。
        start_context(0,1);expect_output=0;
        word(0,0,0,0,15,tag+1);word(0,0,1,0,15,tag);word(0,4,0,0,15,tag);
        word(0,32,0,0,0,tag);word(0,0,48,0,0,tag);word(0,0,0,0,0,tag);word(3,29,0,0,1,tag);
        close_chunk(1,0);
        start_context(0,1);scan(2);close_chunk(0,290);
        // 最终输出已在PSUM wb级而下游停止，end不应使done提前拉高。
        start_context(0,1);force_stall=1;word(0,0,0,2,15,tag);
        wait(ov[0]);@(negedge clk);endv=1;@(posedge clk);@(negedge clk);endv=0;
        repeat(30)begin @(negedge clk);if(donev || ctxr)$fatal(1,"PANEL done before final acceptance");end
        resetn=0;repeat(5)@(negedge clk);force_stall=0;resetn=1;
        repeat(8)@(negedge clk);if(|ov || donev || busy)$fatal(1,"PANEL reset leaked work");
        if(accepted!=968 || committed!=961 || outputs!=580 || errors!=1 || stalls==0)$fatal(1,"PANEL coverage/conservation a=%0d c=%0d out=%0d err=%0d",accepted,committed,outputs,errors);
        $display("PANEL_PASS accepted=%0d commits=%0d outputs=%0d error_chunks=%0d stalled_cycles=%0d nonpower_depth=96",accepted,committed,outputs,errors,stalls);$finish;
    end
    initial begin #1000000;$fatal(1,"PANEL TIMEOUT");end
endmodule
