// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 状态机参考模型逐拍核对所有握手和公开状态；包含非法事务和并行 bank 操作。
module buffer_manager_checker #(parameter AB=2,CB=1,BW=1)(output reg done=0);
    reg clk=0,resetn=0;always #5 clk=~clk;
    reg lbv=0,lbo=0,lfv=0,lfo=0,lfe=0,aqv=0,rlv=0,rle=0,ctv=0,crv=0;
    reg [BW-1:0] lbb=0,lfb=0,qa=0,qb=0,qc=0,ctb=0,crb=0;
    reg [7:0] tag=0;
    reg dv=0,dop=0;reg [BW-1:0] db=0;wire dr,de;
    wire lbr,lbe,lfr,lfer,aqr,aqe,rlr,ctr,cte,crr,cre,lease,pe;
    wire [7:0] ctag;
    wire [AB-1:0] af,al,ar,au,bf,bl,br,bu;
    wire [CB-1:0] cf,cu,cr,cd;
    npu_v13_buffer_manager #(.AB_BANKS(AB),.C_BANKS(CB),.BANK_W(BW)) dut(
        .clk(clk),.resetn(resetn),.load_begin_valid_i(lbv),.load_begin_ready_o(lbr),
        .load_begin_operand_i(lbo),.load_begin_bank_i(lbb),.load_begin_error_o(lbe),
        .load_finish_valid_i(lfv),.load_finish_ready_o(lfr),.load_finish_operand_i(lfo),
        .load_finish_bank_i(lfb),.load_finish_error_i(lfe),.load_finish_error_o(lfer),
        .input_discard_valid_i(dv),.input_discard_ready_o(dr),.input_discard_operand_i(dop),.input_discard_bank_i(db),.input_discard_error_o(de),
        .req_a_bank_i(qa),.req_b_bank_i(qb),.req_c_bank_i(qc),.req_tag_i(tag),
        .buffer_acquire_valid_i(aqv),.buffer_acquire_ready_o(aqr),.buffer_acquire_error_o(aqe),
        .buffer_release_valid_i(rlv),.buffer_release_ready_o(rlr),.buffer_release_error_i(rle),
        .c_take_valid_i(ctv),.c_take_ready_o(ctr),.c_take_bank_i(ctb),.c_take_error_o(cte),.c_take_tag_o(ctag),
        .c_return_valid_i(crv),.c_return_ready_o(crr),.c_return_bank_i(crb),.c_return_error_o(cre),
        .a_free_o(af),.a_loading_o(al),.a_ready_o(ar),.a_in_use_o(au),
        .b_free_o(bf),.b_loading_o(bl),.b_ready_o(br),.b_in_use_o(bu),
        .c_free_o(cf),.c_in_use_o(cu),.c_ready_o(cr),.c_draining_o(cd),.lease_active_o(lease),.protocol_error_o(pe));
    integer a[0:AB-1],b[0:AB-1],c[0:CB-1],tags[0:CB-1];
    bit own=0,err=0;integer oa,ob,oc,ot;
    bit ebr,ebe,efe,ear,eae,errdy,etr,ete,ere,ede,dc;
    integer checks=0,grants=0,releases=0,takes=0,returns=0,overlap=0,seed=817;
    task automatic clear_req;
        begin lbv=0;lfv=0;aqv=0;rlv=0;ctv=0;crv=0;lfe=0;rle=0;dv=0;end
    endtask
    task automatic tick;
        integer i;
        begin
            #1;
            // 异步 reset 在时钟到来前已经清除了 DUT 状态，参考模型同样立即清除。
            if(!resetn)begin own=0;err=0;for(i=0;i<AB;i=i+1)begin a[i]=0;b[i]=0;end for(i=0;i<CB;i=i+1)c[i]=0;end
            ebe=(lbb>=AB); ebr=ebe;if(!ebe) ebr=lbo?(b[lbb]==0):(a[lbb]==0);
            efe=(lfb>=AB);if(!efe) efe=lfo?(b[lfb]!=1):(a[lfb]!=1);
            ede=(db>=AB);if(!ede)ede=dop?(b[db]!=2):(a[db]!=2);
            dc=dv && !ede && (dop?(db==qb):(db==qa));
            eae=(qa>=AB || qb>=AB || qc>=CB || own);ear=eae;
            if(!eae) ear=(a[qa]==2 && b[qb]==2 && c[qc]==0 && !dc);
            errdy=(own && qa==oa && qb==ob && qc==oc && tag==ot);
            ete=(ctb>=CB);etr=ete;if(!ete) etr=(c[ctb]==2);
            ere=(crb>=CB);if(!ere) ere=(c[crb]!=3);
            if(dr!==resetn || de!==ede || lbr!==(resetn&&ebr) || lbe!==ebe || lfr!==resetn || lfer!==efe ||
               aqr!==(resetn&&ear) || aqe!==eae || rlr!==(resetn&&errdy) ||
               ctr!==(resetn&&etr) || cte!==ete || crr!==resetn || cre!==ere)
                $fatal(1,"manager handshake mismatch AB=%0d CB=%0d cycle=%0d",AB,CB,checks);
            if(resetn && ctv && etr && !ete && ctag!==8'(tags[ctb])) $fatal(1,"C ownership tag");
            @(posedge clk);
            if(!resetn) begin
                own=0;err=0;
                for(i=0;i<AB;i=i+1) begin a[i]=0;b[i]=0;end
                for(i=0;i<CB;i=i+1)c[i]=0;
            end else begin
                if(lbv && ebr && !ebe) begin
                    if(own)overlap=overlap+1;
                    if(lbo)b[lbb]=1;else a[lbb]=1;
                end
                if(lfv) begin
                    if(efe)err=1;else if(lfo)b[lfb]=lfe?0:2;else a[lfb]=lfe?0:2;
                end
                if(dv && !ede)begin if(dop)b[db]=0;else a[db]=0;end
                if(aqv && ear && !eae) begin
                    a[qa]=3;b[qb]=3;c[qc]=1;own=1;oa=qa;ob=qb;oc=qc;ot=tag;grants=grants+1;
                end
                if(rlv && !errdy)err=1;
                if(rlv && errdy) begin
                    a[oa]=0;b[ob]=0;c[oc]=rle?0:2;tags[oc]=ot;own=0;releases=releases+1;
                end
                if(ctv && etr && !ete)begin c[ctb]=3;takes=takes+1;end
                if(crv)begin if(ere)err=1;else begin c[crb]=0;returns=returns+1;end end
            end
            #1;
            if(lease!==(resetn&&own) || pe!==err)$fatal(1,"manager lease/diagnostic");
            for(i=0;i<AB;i=i+1)begin
                if({af[i],al[i],ar[i],au[i]}!=={(resetn&&a[i]==0),(resetn&&a[i]==1),(resetn&&a[i]==2),(resetn&&a[i]==3)})$fatal(1,"A state cycle=%0d bank=%0d",checks,i);
                if({bf[i],bl[i],br[i],bu[i]}!=={(resetn&&b[i]==0),(resetn&&b[i]==1),(resetn&&b[i]==2),(resetn&&b[i]==3)})$fatal(1,"B state");
            end
            for(i=0;i<CB;i=i+1)
                if({cf[i],cu[i],cr[i],cd[i]}!=={(resetn&&c[i]==0),(resetn&&c[i]==1),(resetn&&c[i]==2),(resetn&&c[i]==3)})$fatal(1,"C state");
            checks=checks+1;@(negedge clk);
        end
    endtask
    task automatic load_bank(input bit operand,input integer bank);
        begin clear_req();lbo=operand;lbb=bank;lbv=1;tick();
              clear_req();lfo=operand;lfb=bank;lfv=1;tick();clear_req();end
    endtask
    integer i;
    initial begin
        for(i=0;i<AB;i=i+1)begin a[i]=0;b[i]=0;end
        for(i=0;i<CB;i=i+1)c[i]=0;
        @(negedge clk);tick();resetn=1;
        // 缺 B 时不得只拿走 A；装载结束这拍仍按旧状态判断，下一拍才能 acquire。
        load_bank(0,0);aqv=1;qa=0;qb=0;qc=0;tag=17;tick();clear_req();load_bank(1,0);
        aqv=1;tick();clear_req();
        load_bank(0,1);load_bank(1,1); // 计算 bank0 时准备 bank1
        aqv=1;tick();clear_req(); // 重复 acquire 必须原子拒绝
        tag=18;rlv=1;tick();tag=17;tick();clear_req();
        qa=1;qb=1;tag=18;aqv=1;tick(); // 单 C 的结果未取走，下一命令等待
        ctv=1;ctb=0;tick();ctv=0;tick();crv=1;crb=0;tick();crv=0;tick();clear_req();
        rlv=1;rle=1;tick();clear_req(); // 执行失败不发布 C
        // 无效 finish/return 和装载主动中止
        lfv=1;lfb=0;lfo=0;tick();clear_req();lbv=1;lbb=0;lbo=0;tick();
        clear_req();lfv=1;lfb=0;lfe=1;tick();clear_req();
        // READY 取消与 acquire 同 bank 同拍：cancel 成功，acquire 等待，不允许部分占用。
        clear_req();resetn=0;tick();resetn=1;load_bank(0,0);load_bank(1,0);
        qa=0;qb=0;qc=0;aqv=1;dv=1;dop=0;db=0;tick();clear_req();
        load_bank(0,0);aqv=1;tick();clear_req();dv=1;dop=0;db=0;tick(); // IN_USE 丢弃须报错
        clear_req();rlv=1;rle=1;tick();clear_req();
        for(i=0;i<5000;i=i+1)begin
            resetn=(i%211!=0);
            dv=$random(seed);dop=$random(seed);db=$random(seed);
            lbv=$random(seed);lbo=$random(seed);lbb=$random(seed);
            lfv=$random(seed);lfo=$random(seed);lfb=$random(seed);lfe=$random(seed);
            aqv=$random(seed);qa=$random(seed);qb=$random(seed);qc=$random(seed);tag=$random(seed);
            rlv=$random(seed);rle=$random(seed);ctv=$random(seed);ctb=$random(seed);crv=$random(seed);crb=$random(seed);
            // 让随机测试有足够合法 release，而非全是错误 tag。
            if(own && (i%3==0))begin qa=oa;qb=ob;qc=oc;tag=ot;end
            tick();
        end
        clear_req();resetn=0;tick();resetn=1;tick();
        if(grants<2 || releases<2 || takes<1 || returns<1 || overlap<2)$fatal(1,"manager coverage");
        $display("BUFFER_CASE_PASS AB=%0d C=%0d cycles=%0d grants=%0d releases=%0d takes=%0d returns=%0d load_during_lease=%0d",AB,CB,checks,grants,releases,takes,returns,overlap);
        done=1;
    end
endmodule
module tb_npu_v13_buffer_manager;
    wire [1:0] done;
    buffer_manager_checker c0(done[0]);
    buffer_manager_checker #(.AB(3),.CB(2),.BW(2)) c1(done[1]);
    initial begin wait(&done);$display("NPU_V13_BUFFER_MANAGER_TB_PASS configurations=2");$finish;end
    initial begin #200000;$fatal(1,"BUFFER_MANAGER_TB_TIMEOUT");end
endmodule
