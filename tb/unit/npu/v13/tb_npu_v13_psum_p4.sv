// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 独立软件顺序模型在输入握手时累加；不用DUT RAM内容作为期望值。
// 同时核对输入->commit、final->输出两条队列，防止把写完成误当输出完成。
module tb_npu_v13_psum_p4;
    parameter integer DEPTH=17;
    localparam integer AW=$clog2(DEPTH),MW=32,Q=32768;
    reg clk=0;always #2.5 clk=~clk;
    reg resetn=0,iv=0,first=0,final_chunk=0;
    reg [AW-1:0] addr=0;
    reg [127:0] data=0;
    reg [3:0] keep=0;
    reg [MW-1:0] meta=0;
    wire ir,ov,commit,cbad,cfinal,idle,error;
    reg ordy=0;
    wire [127:0] od;
    wire [3:0] ok,ck;
    wire [AW-1:0] oa,ca;
    wire [MW-1:0] om,cm;
    // 功能网表已经固化参数，不能再用RTL参数覆盖；黄金模型/外部断言完全相同。
`ifdef PSUM_NETLIST
    npu_v13_psum_p4 dut(
`else
    npu_v13_psum_p4 #(.DEPTH(DEPTH),.ADDR_W(AW),.META_W(MW)) dut(
`endif
        .clk(clk),.resetn(resetn),.in_valid_i(iv),.in_ready_o(ir),.in_addr_i(addr),
        .in_data_i(data),.in_keep_i(keep),.in_first_i(first),.in_final_i(final_chunk),.in_meta_i(meta),
        .out_valid_o(ov),.out_ready_i(ordy),.out_data_o(od),.out_keep_o(ok),.out_addr_o(oa),.out_meta_o(om),
        .commit_valid_o(commit),.commit_error_o(cbad),.commit_final_o(cfinal),.commit_keep_o(ck),
        .commit_addr_o(ca),.commit_meta_o(cm),.idle_o(idle),.error_o(error));
    reg [127:0] golden[0:DEPTH-1],oq_data[0:Q-1];
    reg [3:0] initialized[0:DEPTH-1],cq_keep[0:Q-1],oq_keep[0:Q-1];
    reg [AW-1:0] cq_addr[0:Q-1],oq_addr[0:Q-1];
    reg [31:0] cq_meta[0:Q-1],oq_meta[0:Q-1];
    reg cq_bad[0:Q-1],cq_final[0:Q-1];
    integer cq_cycle[0:Q-1],oq_cycle[0:Q-1];
    integer accepted=0,committed=0,produced=0,consumed=0,cycle=0;
    integer stalled_cycles=0,expected_errors=0,zero_keeps=0,r1_hits=0,wb_hits=0;
    integer a,l,token=0,i,j,ready_mode=0;
    reg [31:0] rng=32'h7123ba98,rrng=32'h3512ac89;
    reg was_stalled=0;
    reg [127+4+AW+MW:0] stalled_payload;
    reg [127:0] word_value;
    function automatic [31:0] next_rand(input [31:0] x);
        reg [31:0] y;begin y=x^(x<<13);y=y^(y>>17);next_rand=y^(y<<5);end
    endfunction
    // ready_mode=2可制造无限反压，直到测试主动解除；1为有界随机反压。
    always @(negedge clk) begin
        rrng=next_rand(rrng);
        ordy=resetn && (ready_mode==0 || (ready_mode==1 && rrng[2:0]!=0 && rrng[2:0]!=1));
    end

    always @(posedge clk) begin
        cycle=cycle+1;
        if(!resetn) begin
            accepted=0;committed=0;produced=0;consumed=0;expected_errors=0;was_stalled=0;
            for(a=0;a<DEPTH;a=a+1) begin golden[a]=0;initialized[a]=0;end
        end else begin
            if(was_stalled && (!ov || {od,ok,oa,om}!==stalled_payload))
                $fatal(1,"PSUM output changed while stalled cycle=%0d",cycle);
            was_stalled=ov && !ordy;
            if(was_stalled) begin stalled_payload={od,ok,oa,om};stalled_cycles=stalled_cycles+1;end
`ifndef PSUM_NETLIST
            if(dut.advance && dut.r0_valid && !dut.r0_first && dut.r0_keep[0]) begin
                if(dut.G_LANE[0].hit_r1) r1_hits=r1_hits+1;
                else if(dut.G_LANE[0].hit_wb) wb_hits=wb_hits+1;
            end
`endif
            if(iv && ir) begin
                if(accepted>=Q || produced>=Q) $fatal(1,"TB queue too small");
                cq_addr[accepted]=addr;cq_keep[accepted]=keep;cq_meta[accepted]=meta;
                cq_bad[accepted]=(addr>=DEPTH);cq_final[accepted]=final_chunk;cq_cycle[accepted]=cycle;
                accepted=accepted+1;
                if(keep==0) zero_keeps=zero_keeps+1;
                if(addr>=DEPTH) expected_errors=expected_errors+1;
                else begin
                    word_value=0;
                    for(l=0;l<4;l=l+1) if(keep[l]) begin
                        if(!first && !initialized[addr][l]) $fatal(1,"TB read before first addr=%0d lane=%0d",addr,l);
                        golden[addr][l*32+:32]=(first ? 32'b0 : golden[addr][l*32+:32])+data[l*32+:32];
                        initialized[addr][l]=1;word_value[l*32+:32]=golden[addr][l*32+:32];
                    end
                    if(final_chunk && keep!=0) begin
                        oq_data[produced]=word_value;oq_keep[produced]=keep;oq_addr[produced]=addr;
                        oq_meta[produced]=meta;oq_cycle[produced]=cycle;produced=produced+1;
                    end
                end
            end
            if(commit) begin
                if(committed>=accepted) $fatal(1,"unexpected commit");
                if({ca,ck,cm,cbad,cfinal}!=={cq_addr[committed],cq_keep[committed],cq_meta[committed],cq_bad[committed],cq_final[committed]})
                    $fatal(1,"commit mismatch index=%0d got_meta=%0d expected=%0d",committed,cm,cq_meta[committed]);
                if(cycle<cq_cycle[committed]+2) $fatal(1,"commit before BRAM write stage");
                committed=committed+1;
            end
            if(ov && ordy) begin
                if(consumed>=produced) $fatal(1,"unexpected final output");
                if({od,ok,oa,om}!=={oq_data[consumed],oq_keep[consumed],oq_addr[consumed],oq_meta[consumed]})
                    $fatal(1,"final mismatch index=%0d addr=%0d got=%h expected=%h",consumed,oa,od,oq_data[consumed]);
                if(cycle<oq_cycle[consumed]+3) $fatal(1,"output before write visibility");
                consumed=consumed+1;
            end
            if(idle && !iv && (accepted!=committed || produced!=consumed)) $fatal(1,"idle before all work retired");
        end
    end
    task automatic send(input integer xaddr,input [127:0] xdata,input [3:0] xkeep,input bit xf,input bit xl);
        begin
            @(negedge clk);iv=1;addr=xaddr;data=xdata;keep=xkeep;first=xf;final_chunk=xl;meta=token;token=token+1;
            do @(posedge clk); while(!ir);
            #1; // 只让TB观察NBA后的状态；不是给DUT增加额外时钟或改其握手。
        end
    endtask
    task automatic drain;
        integer timeout_cycles;
        begin
            @(negedge clk);iv=0;timeout_cycles=0;
            while(!idle && timeout_cycles<100000) begin @(posedge clk);#1;timeout_cycles=timeout_cycles+1;end
            if(!idle || accepted!=committed || produced!=consumed) $fatal(1,"PSUM drain timeout/missing transaction");
        end
    endtask
    integer span_start,span_end;
    initial begin
        // Unisim glbl启动GSR持续100ns；RTL和综合网表都等它结束后再发首事务。
        repeat(32) @(negedge clk);resetn=1;ready_mode=2;
        // 让三个级都占满，然后协调复位取消：已commit但未输出的final也不能漏到新任务。
        send(0,{4{32'h12345678}},15,1,1);
        send(1,{4{32'h76543210}},15,1,1);
        send(0,{4{32'h00000001}},15,0,1);
        @(negedge clk);iv=0;
        repeat(8) @(negedge clk);
        if(idle || !ov || accepted!=3 || committed!=1 || consumed!=0) $fatal(1,"reset-abort setup did not fill pipeline");
        resetn=0;
        repeat(3) @(negedge clk);
        if(ov || commit || ir) $fatal(1,"handshake visible during reset");
        resetn=1;ready_mode=0;

        // 三个Kchunk；每个位置first覆盖、middle累加、final输出，tail由keep决定。
        for(j=0;j<3;j=j+1) for(i=0;i<DEPTH;i=i+1)
            send(i,{32'h80000000+i,32'h7fffffff-i,32'hffffffff-j,32'h00010000+i+j},15,j==0,j==2);
        drain();
        // 连续128次同址、每拍一个请求；final全开还同时验证最终结果带宽。
        send(0,{4{32'h7fffffff}},15,1,1);span_start=cycle;
        for(i=1;i<128;i=i+1) send(0,{4{32'h00000001}},15,0,1);
        span_end=cycle;
        if(span_end-span_start!=127) $fatal(1,"PSUM did not sustain II=1 span=%0d",span_end-span_start);
        drain();
        // 地址0/1/0间隔恰好落在BRAM同沿读写窗口，必须命中wb旁路。
        for(i=0;i<60;i=i+1) send(i%2,{4{32'hffffffff}},15,0,1);
        // 最年轻同址请求只更新部分lane，其他lane必须从更老的旁路或RAM取值。
        for(i=0;i<64;i=i+1) send(0,{32'h7fffffff,32'h80000000,32'hffffffff,32'h00000001},i%3==0?4'b0101:(i%3==1?4'b1010:4'b1111),0,1);
        drain();ready_mode=1;
        for(i=0;i<1500;i=i+1) begin
            rng=next_rand(rng);
            send((i%5==0)?0:((rng>>4)%DEPTH),{rng,~rng,rng+32'd31,rng^32'h80102040},rng[3:0],rng[8:5]==0,rng[10:9]!=0);
            if(rng[13:11]==0) begin @(negedge clk);iv=0;repeat(2) @(negedge clk);end
        end
        // 非2幂深度必须拒绝“地址位宽能表达但RAM没有”的地址，并继续接收后续有效命令。
        if(DEPTH<(1<<AW)) begin
            send(DEPTH,{4{32'hbad00001}},15,0,1);
            send((1<<AW)-1,{4{32'hbad00002}},15,1,1);
        end
        // 加0读出全部地址，保证部分keep与非法地址都没有暗中破坏RAM。
        for(i=0;i<DEPTH;i=i+1) send(i,0,15,0,1);
        send(0,{4{32'hbad00003}},0,1,1);
        drain();
        if(error!==(expected_errors!=0)) $fatal(1,"sticky error mismatch");
        if(stalled_cycles==0 || zero_keeps==0) $fatal(1,"missing stall/empty coverage");
`ifndef PSUM_NETLIST
        if(r1_hits==0 || wb_hits==0) $fatal(1,"missing hazard coverage");
`endif
        $display("PSUM_PASS depth=%0d accepted=%0d commits=%0d final_outputs=%0d stalls=%0d r1_hits=%0d wb_hits=%0d empty=%0d errors=%0d II1_beats=128 II1_span=128 reset_abort=1",DEPTH,accepted,committed,consumed,stalled_cycles,r1_hits,wb_hits,zero_keeps,expected_errors);
        $finish;
    end
    initial begin #2000000;$fatal(1,"PSUM global timeout");end
endmodule
