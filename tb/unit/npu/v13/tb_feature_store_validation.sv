// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 两bank四island的独立数值单测。不同shape/epoch及乱序坐标读取，防止碰巧读到旧RAM。
module tb_feature_store_validation;
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
    integer rdp=0,wrp=0;reg hold_out=0,held=0;reg [85:0] held_data;
    integer gm[0:1],gn[0:1],gt[0:1],epoch[0:1];reg live[0:1];
    reg [85:0] expected[0:8191];
    function automatic [7:0] value(input integer bank,ep,row,col);
        value=bank*73+ep*37+row*11+col*7;
    endfunction
    always @(negedge clk)if(resetn)rr=!hold_out && (cycles%13<9);
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
    initial begin
        for(integer b=0;b<2;b=b+1)begin live[b]=0;gm[b]=0;gn[b]=0;gt[b]=0;epoch[b]=0;end
        #150;repeat(5)@(negedge clk);resetn=1;
        request(0,0,0);wait(rdp==wrp);
        start_fill(0,29,37,101,1);write_panel(0,29,37,1,0);finish_fill(0,0);
        fork
            begin start_fill(1,17,19,202,2);write_panel(1,17,19,2,0);finish_fill(0,0);end
            read_panel(0);
        join
        if(ready!=2'b11)$fatal(1,"FEATURE independent ready banks");
        @(negedge clk);bb=0;bv=1;repeat(10)begin @(negedge clk);if(br)$fatal(1,"FEATURE overwrote unreleased bank");end bv=0;
        read_panel(1);request(1,17,0);request(1,0,1);request(1,0,20);request(1,65535,0);wait(rdp==wrp);
        // 持有bank0的读响应时release必须等待，避免下一写覆盖在途读的数据。
        @(negedge clk);hold_out=1;request(0,0,0);wait(ov);
        @(negedge clk);lb=0;lv=1;repeat(20)begin @(negedge clk);if(lr)$fatal(1,"FEATURE released pending read");end
        hold_out=0;do @(posedge clk);while(!lr);@(negedge clk);lv=0;live[0]=0;wait(rdp==wrp);
        // 缺失word、错误身份及上游失败：不能把部分内容公布成READY。
        start_fill(0,5,7,303,3);write_panel(0,5,7,3,1);finish_fill(0,1);
        start_fill(0,5,7,304,4);write_panel(0,5,7,4,0);
        @(negedge clk);iv=1;im[15:0]=0;incol[15:0]=0;it[15:0]=999;ik[3:0]=15;do @(posedge clk);while(!ir[0]);@(negedge clk);iv=0;
        finish_fill(0,1);
        start_fill(0,5,7,305,5);write_panel(0,5,7,5,0);finish_fill(1,1);
        start_fill(0,0,7,306,6);finish_fill(0,1);
        start_fill(0,5,7,307,7);write_panel(0,5,7,7,0);finish_fill(0,0);read_panel(0);read_panel(1);
        // 定向逐项注入坏坐标/身份/mask：即使有效word数已经齐全也必须报错且丢弃坏写。
        // 每轮的正常10word仍全部提交，错误beat不得触发BRAM写使能。
        release_bank(0);
        for(integer fault=0;fault<8;fault=fault+1)begin: BAD_CASE
            integer before_commit;
            before_commit=commits;
            start_fill(0,5,7,400+fault,20+fault);write_panel(0,5,7,20+fault,0);
            @(negedge clk);iv=1;im=0;incol=0;it=0;it[15:0]=400+fault;ik=0;ik[3:0]=15;
            case(fault)
                0:it[15:0]=999;              // 错误tag
                1:im[15:0]=6;                // 超动态行界限
                2:incol[15:0]=8;             // 超动态列界限
                3:im[15:0]=4;                // 合法坐标但属于另一island
                4:incol[15:0]=1;             // P4列未对齐
                5:ik[3:0]=3;                 // 非尾块却缺失lane
                6:begin im[15:0]=65535;incol[15:0]=65532;end // 静态地址溢出，不可截断回绕
                7:ik[3:0]=0;                 // 全空keep不是合法物理行
            endcase
            do @(posedge clk);while(!ir[0]);@(negedge clk);iv=0;
            finish_fill(0,1);
            if(commits-before_commit!=10)$fatal(1,"FEATURE bad write was committed fault=%0d delta=%0d",fault,commits-before_commit);
        end
        start_fill(0,5,7,499,99);write_panel(0,5,7,99,0);finish_fill(0,0);read_panel(0);read_panel(1);
        // 读阻塞时reset取消所有租约/响应；新bank必须重新填满，旧内容不对外可见。
        @(negedge clk);hold_out=1;request(1,0,0);wait(ov);repeat(5)@(negedge clk);
        canceled=canceled+wrp-rdp;rdp=wrp;resetn=0;live[0]=0;live[1]=0;
        repeat(5)@(negedge clk);resetn=1;hold_out=0;repeat(5)@(negedge clk);
        if(ready || free!=3 || busy || ov)$fatal(1,"FEATURE reset leak");
        request(1,0,0);wait(rdp==wrp);
        start_fill(1,32,48,408,8);write_panel(1,32,48,8,0);finish_fill(0,0);read_panel(1);release_bank(1);
        // 原用例1次坏tag，加本轮8类坏写，共9个已接收但禁止提交的beat。
        if(requests!=responses+canceled || canceled!=1 || overlap==0 || stalls==0 || successes!=5 || failures!=12 || commits!=writes-9)
            $fatal(1,"FEATURE coverage/conservation wr=%0d commit=%0d req=%0d rsp=%0d cancel=%0d overlap=%0d",writes,commits,requests,responses,canceled,overlap);
        $display("FEATURE_VALIDATION_PASS writes=%0d commits=%0d requests=%0d responses=%0d canceled=%0d overlap=%0d stalls=%0d successes=%0d failures=%0d",writes,commits,requests,responses,canceled,overlap,stalls,successes,failures);$finish;
    end
    initial begin #2000000;$fatal(1,"FEATURE TIMEOUT");end
endmodule
