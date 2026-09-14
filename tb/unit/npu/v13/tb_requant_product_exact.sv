// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 在已有端到端量化黄金检查之外，额外逐拍核对完整65bit乘积，防止INT8饱和掩盖分割乘法错误。
// 本测试只用于RTL内部算术诊断，不能冒充DSP综合网表或时序验证。
module tb_requant_product_exact;
    tb_requant_p4 test();
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1)begin:G_EXACT
        reg signed [64:0] expected[0:31];
        integer wp=0,rp=0,total=0;
        reg signed [32:0] sum;
        reg signed [64:0] a,b;
        always @(posedge test.clk)begin
            if(!test.resetn)begin wp=0;rp=0;end
            else begin
                if(test.iv && test.ir)begin
                    if(wp-rp>=32)$fatal(1,"EXACT overflow");
                    sum=$signed({test.data[lane*32+31],test.data[lane*32+:32]})+
                        $signed({test.bias[lane*32+31],test.bias[lane*32+:32]});
                    a=sum;b=$signed({1'b0,test.mult[lane*31+:31]});
                    expected[wp%32]=a*b;wp=wp+1;
                end
                if(test.dut.valid_r[5] && test.dut.advance_w)begin
                    if(rp==wp || test.dut.G_LANE[lane].product_r!==expected[rp%32])
                        $fatal(1,"EXACT lane=%0d idx=%0d actual=%h expected=%h",lane,rp,test.dut.G_LANE[lane].product_r,expected[rp%32]);
                    rp=rp+1;total=total+1;
                end
            end
        end
        final begin
            if(total<5120)$error("EXACT insufficient coverage lane=%0d count=%0d",lane,total);
            else $display("REQUANT_EXACT_PASS lane=%0d products=%0d",lane,total);
        end
    end endgenerate
endmodule