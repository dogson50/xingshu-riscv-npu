// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 一个局部P4最终结果流的后处理；不读取PSUM、不解释命令或矩阵坐标。
// 每lane数值契约（不是某框架隐含的double-rounding约定）：
//   b = signed(INT32结果) + signed(INT32 bias)，用33bit精确相加；
//   p = b * unsigned(31bit multiplier)；scale = multiplier / 2**shift；
//   q = sign(p)*round_nearest_ties_away(abs(p)/2**shift) + signed(zero_point)；
//   out = clamp(q, relu ? zero_point : -128, 127)，输出有符号INT8。
// INT32跨K回绕由上游PSUM完成；这里只接收final，不允许每个chunk重复bias/量化。
// 10级流水：bias / DSP输入 / 四部分积 / DSP输出 / 合并预加 / 完整乘积 / 幅值 / 移位 / 舍入 / 饱和。
// p18：算术/参数/meta每拍自由推进；输入先预约本地输出槽，结果不会因反压停在算术链。
// 下游反压只作用于窄输出队列；未退休预约含10级在途token，防止迟到结果溢出。
// 无反压II=1；相对原10级增加1拍结果入队延迟。空泡期间数据不可解释且仍翻转，功耗需另测。
module npu_v13_requant_p4 #(
    parameter integer META_W=48,
    parameter integer OUTPUT_SLOTS=16
)(
    input wire clk, // 同计算域时钟；不提供CDC。
    input wire resetn, // 同步取消valid；数据寄存器不复位，valid=0时不可解释数据。
    input wire in_valid_i, // 最终INT32 P4结果有效；等待ready时全部输入字段必须稳定。
    output wire in_ready_o, // 仅由本地未退休预约数决定，不组合依赖下游ready。
    input wire [127:0] in_data_i, // 四个signed INT32，lane0位于[31:0]。
    input wire [3:0] in_keep_i, // 有效lane；无效lane输出置0，全0也按一个beat传递。
    input wire [127:0] in_bias_i, // 每lane一个signed INT32 bias；上层可广播同通道参数。
    input wire [123:0] in_multiplier_i, // 每lane31bit非负整数，范围0..2^31-1；不损失Q31精度。
    input wire [23:0] in_shift_i, // 每lane6bit右移量0..63；支持scale大于1及极小scale。
    input wire [31:0] in_zero_point_i, // 每lane8bit有符号输出zero-point，范围-128..127。
    input wire [3:0] in_relu_i, // 每lane可选ReLU，量化域下限为zero-point而非硬编码0。
    input wire [META_W-1:0] in_meta_i, // opaque身份/坐标，不参与算术。
    output wire out_valid_o, // 量化后的P4结果有效，支持任意时长反压。
    input wire out_ready_i, // 下游feature_store或其他接收器的容量允许。
    output wire [31:0] out_data_o, // 四个signed INT8，lane0位于[7:0]。
    output wire [3:0] out_keep_o, // 输入mask原样延迟，不把尾lane扩成有效数据。
    output wire [META_W-1:0] out_meta_o, // 与out_data严格同拍的输入身份。
    output wire idle_o // 未退休预约为0：同时覆盖算术在途token与已完成输出队列。
);
    localparam integer STAGES=10;
    reg [STAGES-1:0] valid_r;
    reg [3:0] keep_r[0:STAGES-1],relu_r[0:STAGES-1];
    reg [META_W-1:0] meta_r[0:STAGES-1];
    localparam integer QW=META_W+36;
    localparam integer QAW=(OUTPUT_SLOTS<=2 ? 1 : $clog2(OUTPUT_SLOTS));
    localparam integer QCW=$clog2(OUTPUT_SLOTS+1);
    reg [QCW-1:0] reserved_r,queued_r;
    reg [QAW-1:0] write_ptr_r,read_ptr_r;
    (* ram_style="distributed" *) reg [QW-1:0] result_mem[0:OUTPUT_SLOTS-1];
    wire [31:0] result_data;
    wire accept_w=in_valid_i && in_ready_o;
    wire retire_w=out_valid_o && out_ready_i;
    wire enqueue_w=resetn && valid_r[STAGES-1];
    assign in_ready_o=resetn && reserved_r<OUTPUT_SLOTS;
    assign out_valid_o=resetn && queued_r!=0;
    assign {out_meta_o,out_keep_o,out_data_o}=result_mem[read_ptr_r];
    assign idle_o=reserved_r==0;
    function automatic [QAW-1:0] next_ptr(input [QAW-1:0] p);
        begin next_ptr=(p==OUTPUT_SLOTS-1) ? 0 : p+1'b1;end
    endfunction
    always @(posedge clk)begin
        if(!resetn)begin
            valid_r<=0;reserved_r<=0;queued_r<=0;write_ptr_r<=0;read_ptr_r<=0;
        end else begin
            valid_r<={valid_r[STAGES-2:0],accept_w};
            case({accept_w,retire_w})
                2'b10:reserved_r<=reserved_r+1'b1;
                2'b01:reserved_r<=reserved_r-1'b1;
                default:begin end
            endcase
            case({enqueue_w,retire_w})
                2'b10:queued_r<=queued_r+1'b1;
                2'b01:queued_r<=queued_r-1'b1;
                default:begin end
            endcase
            if(enqueue_w)write_ptr_r<=next_ptr(write_ptr_r);
            if(retire_w)read_ptr_r<=next_ptr(read_ptr_r);
        end
        if(enqueue_w)result_mem[write_ptr_r]<={meta_r[STAGES-1],keep_r[STAGES-1],result_data};
    end
    integer s;
    // payload无reset/valid/ready使能；只由独立token保护，所有字段严格等长推进。
    always @(posedge clk)begin
        keep_r[0]<=in_keep_i;relu_r[0]<=in_relu_i;meta_r[0]<=in_meta_i;
        for(s=1;s<STAGES;s=s+1)begin
            keep_r[s]<=keep_r[s-1];relu_r[s]<=relu_r[s-1];meta_r[s]<=meta_r[s-1];
        end
    end
    genvar l;
    generate for(l=0;l<4;l=l+1)begin:G_LANE
        reg signed [32:0] bias_sum_r;
        reg [30:0] multiplier_r;
        reg [5:0] shift_r[0:6];reg signed [7:0] zero_r[0:8];
        // A为signed33，B为unsigned31；在bit17分割，低半部显式补0，不能误作负数。
        // A=Alo+(Ahi<<17)，B=Blo+(Bhi<<17)，四个部分积均适配单个DSP乘法端口。
        reg signed [17:0] alo_r,blo_r;reg signed [15:0] ahi_r;reg signed [14:0] bhi_r;
        (* use_dsp="yes" *) reg signed [35:0] p00_r;
        (* use_dsp="yes" *) reg signed [32:0] p01_r;
        (* use_dsp="yes" *) reg signed [33:0] p10_r;
        (* use_dsp="yes" *) reg signed [30:0] p11_r;
        // 独立乘积输出级提供DSP内部M/P寄存机会；具体映射须读取综合报告确认。
        reg signed [35:0] p00d_r;reg signed [32:0] p01d_r;
        reg signed [33:0] p10d_r;reg signed [30:0] p11d_r;
        reg signed [34:0] cross_r;reg signed [64:0] aligned_r,product_r;
        reg [64:0] magnitude_r;reg [65:0] shifted_r;
        reg sign_r[6:8];reg huge_r;reg signed [10:0] affine_r;reg [7:0] result_r;
        wire signed [31:0] x=in_data_i[l*32+:32],bias=in_bias_i[l*32+:32];
        // 先符号扩展到目标宽度再移位/相加，避免Verilog表达式定宽丢失高位或负号。
        wire signed [64:0] p00_ext={{29{p00d_r[35]}},p00d_r};
        wire signed [64:0] p11_ext={{34{p11d_r[30]}},p11d_r};
        wire signed [64:0] cross_ext={{30{cross_r[34]}},cross_r};
        wire [9:0] rounded_small={1'b0,shifted_r[9:1]}+{9'b0,shifted_r[0]};
        wire signed [10:0] signed_small=sign_r[7] ? -$signed({1'b0,rounded_small}) : $signed({1'b0,rounded_small});
        wire signed [10:0] zp_ext={{3{zero_r[8][7]}},zero_r[8]};
        assign result_data[l*8+:8]=result_r;
        integer z;
        always @(posedge clk)begin
            begin
                bias_sum_r<=$signed({x[31],x})+$signed({bias[31],bias});
                multiplier_r<=in_multiplier_i[l*31+:31];shift_r[0]<=in_shift_i[l*6+:6];
                zero_r[0]<=in_zero_point_i[l*8+:8];
            end
            for(z=1;z<9;z=z+1)zero_r[z]<=zero_r[z-1];
            for(z=1;z<7;z=z+1)shift_r[z]<=shift_r[z-1];
            begin
                alo_r<=$signed({1'b0,bias_sum_r[16:0]});ahi_r<=bias_sum_r[32:17];
                blo_r<=$signed({1'b0,multiplier_r[16:0]});bhi_r<=$signed({1'b0,multiplier_r[30:17]});
            end
            begin
                p00_r<=alo_r*blo_r;p01_r<=alo_r*bhi_r;p10_r<=ahi_r*blo_r;p11_r<=ahi_r*bhi_r;
            end
            begin p00d_r<=p00_r;p01d_r<=p01_r;p10d_r<=p10_r;p11d_r<=p11_r;end
            begin
                cross_r<=$signed({{2{p01d_r[32]}},p01d_r})+$signed({p10d_r[33],p10d_r});
                aligned_r<=p00_ext+(p11_ext<<<34);
            end
            product_r<=aligned_r+(cross_ext<<<17);
            begin magnitude_r<=product_r[64] ? -product_r : product_r;sign_r[6]<=product_r[64];end
            begin shifted_r<={magnitude_r,1'b0}>>shift_r[6];sign_r[7]<=sign_r[6];end
            begin
                huge_r<=|shifted_r[65:10];sign_r[8]<=sign_r[7];
                affine_r<=signed_small+$signed({{3{zero_r[7][7]}},zero_r[7]});
            end
            begin
                if(!keep_r[8][l])result_r<=0;
                else if(huge_r)result_r<=sign_r[8] ? (relu_r[8][l] ? zero_r[8] : 8'h80) : 8'h7f;
                else if(relu_r[8][l] && affine_r<zp_ext)result_r<=zero_r[8];
                else if(affine_r>11'sd127)result_r<=8'h7f;
                else if(affine_r < -11'sd128)result_r<=8'h80;
                else result_r<=affine_r[7:0];
            end
        end
    end endgenerate
    // synthesis translate_off
    initial if(META_W<1 || OUTPUT_SLOTS<STAGES+2)$fatal(1,"REQUANT invalid metadata/output capacity");
    integer token_count,k;
    always @(posedge clk)if(resetn)begin
        token_count=0;for(k=0;k<STAGES;k=k+1)token_count=token_count+valid_r[k];
        if(reserved_r!==queued_r+token_count)$fatal(1,"REQUANT reservation conservation");
        if(reserved_r>OUTPUT_SLOTS || queued_r>OUTPUT_SLOTS)$fatal(1,"REQUANT capacity overflow");
        if(enqueue_w && queued_r==OUTPUT_SLOTS && !retire_w)$fatal(1,"REQUANT unreserved enqueue");
        if(retire_w && reserved_r==0)$fatal(1,"REQUANT unreserved retire");
    end
    // synthesis translate_on
endmodule
