// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 两bank四island的独立数值单测。不同shape/epoch及乱序坐标读取，防止碰巧读到旧RAM。
module tb_feature_read_pipeline;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,bv=0,bb=0,ev=0,ee=0,dr=0,lv=0,lb=0;
    reg [15:0] bm=0,bn=0,bt=0;
    wire br,er,dv,db,de,lr,busy;wire [15:0] dt;wire [1:0] ready,free;
    reg [3:0] iv=0;wire [3:0] ir,commit;reg [127:0] idata=0;reg [15:0] ik=0;reg [63:0] im=0,incol=0,it=0;
    reg rv=0,rb=0,rr=0;reg [15:0] rm=0,rn=0;
    wire rready,ov,ob,oe;wire [31:0] od;wire [3:0] ok;wire [15:0] om,on,ot;
`ifdef POST_NETLIST
    npu_v13_feature_store dut(
`else
    npu_v13_feature_store #(.MAX_M(32),.MAX_N(48)) dut(
`endif
        .clk(clk),.resetn(resetn),.begin_valid_i(bv),.begin_ready_o(br),.begin_bank_i(bb),.begin_m_i(bm),.begin_n_i(bn),.begin_tag_i(bt),
        .in_valid_i(iv),.in_ready_o(ir),.in_data_i(idata),.in_keep_i(ik),.in_m_i(im),.in_n_i(incol),.in_tag_i(it),
        .end_valid_i(ev),.end_ready_o(er),.end_error_i(ee),.done_valid_o(dv),.done_ready_i(dr),.done_bank_o(db),.done_tag_o(dt),.done_error_o(de),
        .bank_ready_o(ready),.bank_free_o(free),.release_valid_i(lv),.release_ready_o(lr),.release_bank_i(lb),
        .rd_valid_i(rv),.rd_ready_o(rready),.rd_bank_i(rb),.rd_m_i(rm),.rd_n_i(rn),.rd_valid_o(ov),.rd_ready_i(rr),
        .rd_data_o(od),.rd_keep_o(ok),.rd_bank_o(ob),.rd_error_o(oe),.rd_m_o(om),.rd_n_o(on),.rd_tag_o(ot),.write_commit_o(commit),.busy_o(busy));
    integer cycles=0,writes=0,commits=0,requests=0,responses=0,canceled=0,overlap=0,stalls=0,successes=0,failures=0;
    integer rdp=0,wrp=0;reg hold_out=0,force_ready=0,held=0;reg [85:0] held_data;
    integer gm[0:1],gn[0:1],gt[0:1],epoch[0:1];reg live[0:1];
    reg [85:0] expected[0:8191];
    function automatic [7:0] value(input integer bank,ep,row,col);
        value=bank*73+ep*37+row*11+col*7;
    endfunction
    always @(negedge clk)if(resetn)rr=!hold_out && (force_ready || cycles%13<9);
    always @(posedge clk)if(!resetn)held=0;else begin
        cycles=cycles+1;
        if(held && (!ov || held_data!=={ob,oe,ot,om,on,ok,od}))$fatal(1,"FEATURE stalled response changed");
        held=ov && !rr;held_data={ob,oe,ot,om,on,ok,od};if(held)stalls=stalls+1;
        for(integer g=0;g<4;g=g+1)begin
            if(iv[g] && ir[g])writes=writes+1;
            if(commit[g])begin commits=commits+1;if(ready[bb])$fatal(1,"FEATURE ready before writes committed");end
        end
        if(rv && rready)begin: ENQUEUE
            reg bad;reg [3:0] mask;reg [31:0] data;reg [15:0] tag;
            bad=!live[rb] || rm>=gm[rb] || rn>=gn[rb] || rm>=32 || rn>=48 || rn%4!=0;
            mask=0;data=0;tag=live[rb] ? gt[rb] : 0;
            for(integer l=0;l<4;l=l+1)if(!bad && rn+l<gn[rb])begin mask[l]=1;data[l*8+:8]=value(rb,epoch[rb],rm,rn+l);end
            expected[wrp]={rb,bad,tag,rm,rn,mask,data};wrp=wrp+1;requests=requests+1;
            if(|commit)overlap=overlap+1;
        end
        if(ov && rr)begin
            if(rdp==wrp || {ob,oe,ot,om,on,ok,od}!==expected[rdp])$fatal(1,"FEATURE read mismatch req=%0d got=%h expected=%h",rdp,{ob,oe,ot,om,on,ok,od},expected[rdp]);
            rdp=rdp+1;responses=responses+1;
        end
    end
    task automatic start_fill(input integer bank,m,n,tag,ep);
        begin
            @(negedge clk);bb=bank;bm=m;bn=n;bt=tag;bv=1;do @(posedge clk);while(!br);
            @(negedge clk);bv=0;gm[bank]=m;gn[bank]=n;gt[bank]=tag;epoch[bank]=ep;live[bank]=0;
        end
    endtask
    task automatic finish_fill(input bit upstream_error,expect_error);
        begin
            @(negedge clk);ev=1;ee=upstream_error;do @(posedge clk);while(!er);
            // wait唤醒仍可能位于NBA之后连续assign尚未全部传播的delta；在半周期边界检查公开状态。
            @(negedge clk);ev=0;ee=0;wait(dv);@(negedge clk);
            if(db!==bb || dt!==bt || de!==expect_error)$fatal(1,"FEATURE completion identity/status");
            if(!expect_error)begin live[bb]=1;successes=successes+1;if(!ready[bb])$fatal(1,"FEATURE completion before ready");end
            else begin failures=failures+1;if(ready[bb] || !free[bb])$fatal(1,"FEATURE failed bank published");end
            repeat(9)begin @(negedge clk);if(!dv || br)$fatal(1,"FEATURE done hold");end
            dr=1;@(posedge clk);@(negedge clk);dr=0;
        end
    endtask
    task automatic write_panel(input integer bank,m,n,ep,input bit drop_last);
        integer row,mask;
        reg [3:0] pending;
        begin
            for(integer block_row=0;block_row<(m+15)/16;block_row=block_row+1)
            for(integer offset=0;offset<4;offset=offset+1)
            for(integer col=0;col<n;col=col+4)begin
                @(negedge clk);iv=0;
                for(integer g=0;g<4;g=g+1)begin
                    row=block_row*16+g*4+offset;mask=0;
                    if(row<m && !(drop_last && row==m-1 && col+4>=n))begin
                        iv[g]=1;im[g*16+:16]=row;incol[g*16+:16]=col;it[g*16+:16]=gt[bank];
                        for(integer l=0;l<4;l=l+1)begin if(col+l<n)mask=mask|(1<<l);idata[g*32+l*8+:8]=value(bank,ep,row,col+l);end
                        ik[g*4+:4]=mask;
                    end
                end
                pending=iv;
                while(|pending)begin @(posedge clk);pending=pending & ~ir;@(negedge clk);iv=pending;end
            end
            @(negedge clk);iv=0;
        end
    endtask
    task automatic request(input integer bank,row,col);
        begin @(negedge clk);rb=bank;rm=row;rn=col;rv=1;do @(posedge clk);while(!rready);@(negedge clk);rv=0;end
    endtask
    task automatic read_panel(input integer bank);
        integer row,col,words;
        begin
            words=(gn[bank]+3)/4;
            // 逆行、逆列及重复读，不依赖写入顺序，也验证bank能保留被多次消费。
            for(integer pass=0;pass<2;pass=pass+1)
            for(integer r=gm[bank]-1;r>=0;r=r-1)
            for(integer c=words-1;c>=0;c=c-1)request(bank,r,c*4);
            wait(rdp==wrp);@(negedge clk);
        end
    endtask
    task automatic release_bank(input integer bank);
        begin
            @(negedge clk);lb=bank;lv=1;do @(posedge clk);while(!lr);
            @(negedge clk);lv=0;live[bank]=0;if(!free[bank])$fatal(1,"FEATURE not freed");
        end
    endtask

    // 独立协议模型只采样公开握手；不读取DUT层次，因此RTL和实际BRAM功能网表共用。
    reg [4:0] model_v=0,model_b=0;
    reg [4:0] fence0=0,fence1=0,reset_phases=0;
    reg [7:0] selectors=0;
    integer model_checks=0,ii1_pairs=0,last_rsp_cycle=-100,full_resets=0,raw_fences=0;
    always @(posedge clk)begin: PROTOCOL
        reg pending_bank;
        if(!resetn)begin model_v<=0;model_b<=0;last_rsp_cycle=-100;end
        else begin
            if(ov!==model_v[4])$fatal(1,"READ_PIPE valid latency/freeze model=%b ov=%b",model_v,ov);
            if(rready!==(!model_v[4] || rr))$fatal(1,"READ_PIPE global advance");
            if((|model_v) && !busy)$fatal(1,"READ_PIPE busy dropped with live read");
            pending_bank=rv && rb==lb;
            for(integer p=0;p<5;p=p+1)if(model_v[p] && model_b[p]==lb)pending_bank=1;
            if(lr!==(ready[lb] && !pending_bank))$fatal(1,"READ_PIPE release fence model=%b bank=%b",model_v,lb);
            if(rready)begin model_v<={model_v[3:0],rv};model_b<={model_b[3:0],rb};end
            if(rv && rready && live[rb] && rm<gm[rb] && rn<gn[rb] && rn%4==0)selectors[{rb,rm[3:2]}]=1;
            if(ov && rr)begin
                if(cycles-last_rsp_cycle==1)ii1_pairs=ii1_pairs+1;
                last_rsp_cycle=cycles;
            end
            model_checks=model_checks+1;
        end
    end
    task automatic fence_single(input integer bank);
        begin
            wait(rdp==wrp);@(negedge clk);hold_out=1;force_ready=0;lb=bank;lv=1;rb=bank;rm=0;rn=0;rv=1;
            #0.001;if(lr)$fatal(1,"READ_PIPE simultaneous raw read released bank");raw_fences=raw_fences+1;
            do @(posedge clk);while(!rready);@(negedge clk);rv=0;
            for(integer stage=0;stage<5;stage=stage+1)begin
                #0.001;
                if(model_v!==(5'b00001<<stage) || lr || !ready[bank])$fatal(1,"READ_PIPE single-stage fence stage=%0d model=%b",stage,model_v);
                if(bank==0)fence0[stage]=1;else fence1[stage]=1;
                // 没有读的另一个READY bank不应被全局错误阻塞，但此处不实际释放。
                lv=0;lb=1-bank;#0.001;if(!lr)$fatal(1,"READ_PIPE unrelated READY bank fenced");
                lb=bank;lv=1;#0.001;if(lr)$fatal(1,"READ_PIPE same bank fence dropped");
                if(stage<4)@(negedge clk);
            end
            repeat(7)begin @(negedge clk);if(lr || !ov || model_v!=16)$fatal(1,"READ_PIPE held final stage");end
            lv=0;hold_out=0;force_ready=1;wait(rdp==wrp);@(negedge clk);#0.001;
            if(!lr || model_v!=0)$fatal(1,"READ_PIPE drained bank remains fenced");
        end
    endtask
    task automatic stream_read(input integer count,input bit invalids,input bit ii1);
        integer bank,row,col;time first_t,last_t;
        begin
            @(negedge clk);hold_out=0;force_ready=ii1;
            for(integer x=0;x<count;x=x+1)begin
                bank=(x/4)%2;row=(x%4)*4+(x/8)%3;col=(x%3==0) ? (bank==0 ? 36:16):((x/8)%4)*4;
                if(invalids)case(x%11)0:row=65535;1:col=1;2:col=64;endcase
                rv=1;rb=bank;rm=row;rn=col;
                do @(posedge clk);while(!rready);
                if(x==0)first_t=$time;if(x==count-1)last_t=$time;
                @(negedge clk);
            end
            rv=0;if(ii1 && last_t-first_t!=5*(count-1))$fatal(1,"READ_PIPE input II1 count=%0d span=%0t",count,last_t-first_t);
            wait(rdp==wrp);@(negedge clk);
        end
    endtask
    task automatic cancel_reset;
        begin
            canceled=canceled+wrp-rdp;rdp=wrp;resetn=0;live[0]=0;live[1]=0;lv=0;rv=0;iv=0;
            repeat(4)@(negedge clk);resetn=1;hold_out=0;force_ready=1;
            repeat(8)@(negedge clk);
            if(ready || free!=3 || busy || ov || model_v!=0)$fatal(1,"READ_PIPE reset leak");
        end
    endtask
    initial begin
        for(integer b=0;b<2;b=b+1)begin live[b]=0;gm[b]=0;gn[b]=0;gt[b]=0;epoch[b]=0;end
        #150;repeat(5)@(negedge clk);resetn=1;
        request(0,0,0);wait(rdp==wrp);
        start_fill(0,29,37,101,1);write_panel(0,29,37,1,0);finish_fill(0,0);
        start_fill(1,17,19,202,2);write_panel(1,17,19,2,0);finish_fill(0,0);
        fence_single(0);fence_single(1);
        stream_read(256,0,1);stream_read(384,1,0);
        read_panel(0);read_panel(1);release_bank(0);release_bank(1);
        // 分别在请求、校验、RAM、本地寄存及输出五个位置复位，不允许旧valid/旧租约泄漏。
        for(integer phase=0;phase<5;phase=phase+1)begin
            start_fill(phase%2,1,1,500+phase,20+phase);write_panel(phase%2,1,1,20+phase,0);finish_fill(0,0);
            @(negedge clk);hold_out=1;force_ready=0;request(phase%2,0,0);
            repeat(phase)@(negedge clk);#0.001;
            if(model_v!==(5'b1<<phase) || wrp-rdp!=1)$fatal(1,"READ_PIPE reset phase placement=%0d model=%b pending=%0d",phase,model_v,wrp-rdp);
            reset_phases[phase]=1;cancel_reset();request(phase%2,0,0);wait(rdp==wrp);
        end
        // 全五级占用且最终响应被阻塞时整体取消；取消量必须恰好等于五个公开握手。
        start_fill(0,29,37,606,31);write_panel(0,29,37,31,0);finish_fill(0,0);
        @(negedge clk);hold_out=1;force_ready=0;
        // 此读流水是全局冻结而非逐级弹性。必须无气泡连发五拍，不能用会插空拍的request任务。
        @(negedge clk);
        for(integer x=0;x<5;x=x+1)begin
            rv=1;rb=0;rm=(x%4)*4;rn=0;do @(posedge clk);while(!rready);@(negedge clk);
        end
        rv=0;
        #0.001;if(model_v!=31 || wrp-rdp!=5 || rready)$fatal(1,"READ_PIPE full pipeline not occupied");
        full_resets=full_resets+1;cancel_reset();request(0,0,0);wait(rdp==wrp);@(negedge clk);
        if(requests!=responses+canceled || canceled!=10 || writes!=commits || selectors!=255 || fence0!=31 || fence1!=31 ||
           reset_phases!=31 || full_resets!=1 || raw_fences!=2 || ii1_pairs<255 || stalls==0 || successes!=8 || failures!=0)
            $fatal(1,"READ_PIPE coverage/conservation req=%0d rsp=%0d cancel=%0d w=%0d c=%0d sel=%h f0=%h f1=%h reset=%h II1=%0d success=%0d",
                   requests,responses,canceled,writes,commits,selectors,fence0,fence1,reset_phases,ii1_pairs,successes);
        $display("FEATURE_READ_PIPE_PASS stages=5 requests=%0d responses=%0d canceled=%0d writes=%0d commits=%0d selectors=%h fence0=%h fence1=%h reset_phases=%h full_resets=%0d raw_fences=%0d II1_pairs=%0d stalls=%0d checks=%0d scope=simulation_not_formal_or_SDF",
                 requests,responses,canceled,writes,commits,selectors,fence0,fence1,reset_phases,full_resets,raw_fences,ii1_pairs,stalls,model_checks);$finish;
    end
    initial begin #2000000;$fatal(1,"READ_PIPE TIMEOUT");end
endmodule
