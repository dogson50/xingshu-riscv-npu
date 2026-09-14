// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 同一 packed-panel 输入契约，比较原 16x16/SIMD1 与 4 tile 的 8x8/SIMD4。
module panel_compute_exp #(
    parameter integer SIMD4=0,G=SIMD4?8:16,S=SIMD4?4:1,T=(G/4)*(G/4)
)(
    input wire clk,resetn, // 统一计算时钟、复位。
    input wire valid_i,init_i,last_i, // 固定速率 K packet。
    input wire [4:0] rows_i,cols_i, // 逻辑组有效行列数量。
    input wire [G*S*8-1:0] a_i,b_i, // 每行/列 S 路 K 数据。
    output wire [T-1:0] valid_o, // 各物理 tile 最终结果事件。
    output wire [T*4-1:0] shape_o, // 每 tile {rows_m1,cols_m1}。
    output wire [T*512-1:0] matrix_o, // 每 tile 的本地行优先 4x4。
    output wire error_o // 核协议/模式错误。
);
    genvar tr,tc,r,c;
    generate if(!SIMD4) begin:G_ORIGINAL
        wire [511:0] asrc,bsrc;
        wire [31:0] cr,cc;
        wire [8191:0] cm;
        for(tr=0;tr<4;tr=tr+1) begin:G_SRC_R
            for(tc=0;tc<4;tc=tc+1) begin:G_SRC_C
                assign asrc[(tr*4+tc)*32+:32]=(tc==0)?a_i[tr*32+:32]:32'b0;
                assign bsrc[(tr*4+tc)*32+:32]=(tr==0)?b_i[tc*32+:32]:32'b0;
                assign shape_o[(tr*4+tc)*4+:4]={cr[(tr*4+tc)*2+:2],cc[(tr*4+tc)*2+:2]};
                for(r=0;r<4;r=r+1) begin:G_COPY_R
                    for(c=0;c<4;c=c+1) begin:G_COPY_C
                        assign matrix_o[((tr*4+tc)*16+r*4+c)*32+:32]=cm[((tr*4+r)*16+tc*4+c)*32+:32];
                    end
                end
            end
        end
        wire [3:0] rm1=rows_i-1'b1,cm1=cols_i-1'b1;
        npu_v13_systolic_cluster_runtime_stream u_original(
            .clk(clk),.resetn(resetn),.cfg_valid_i(1'b0),.cfg_mode_i(2'b00),
            .cfg_ready_o(),.cfg_error_o(error_o),.active_mode_o(),.cluster_idle_o(),
            .s_axis_tvalid_i({15'b0,valid_i}),.s_axis_tuser_i({15'b0,init_i}),
            .s_axis_tlast_i({15'b0,last_i}),.active_rows_m1_i({28'b0,rm1}),
            .active_cols_m1_i({28'b0,cm1}),.a_source_i(asrc),.b_source_i(bsrc),
            .c_tile_valid_o(valid_o),.c_active_rows_m1_o(cr),.c_active_cols_m1_o(cc),.c_matrix_o(cm));
    end else begin:G_SIMD4
        wire [3:0] errors;
        for(tr=0;tr<2;tr=tr+1) begin:G_R
            for(tc=0;tc<2;tc=tc+1) begin:G_C
                reg vr,ir,lr;
                reg [127:0] ar,br;
                reg [1:0] rr,cr;
                always @(posedge clk) begin
                    if(!resetn) begin vr<=0;ir<=0;lr<=0;end
                    else begin vr<=valid_i && rows_i>tr*4 && cols_i>tc*4;ir<=init_i;lr<=last_i;end
                    ar<=a_i[tr*128+:128];br<=b_i[tc*128+:128];
                    rr<=(rows_i>tr*4+4)?3:(rows_i-tr*4-1);
                    cr<=(cols_i>tc*4+4)?3:(cols_i-tc*4-1);
                end
                simd4_tile_exp u_tile(.clk(clk),.resetn(resetn),.valid_i(vr),.init_i(ir),.last_i(lr),
                    .rows_m1_i(rr),.cols_m1_i(cr),.a_i(ar),.b_i(br),
                    .valid_o(valid_o[tr*2+tc]),.shape_o(shape_o[(tr*2+tc)*4+:4]),
                    .matrix_o(matrix_o[(tr*2+tc)*512+:512]),.error_o(errors[tr*2+tc]));
            end
        end
        assign error_o=|errors;
    end endgenerate
endmodule
