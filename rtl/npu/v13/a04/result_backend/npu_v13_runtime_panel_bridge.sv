// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 纯连线桥：将16行A/16列B映射到原runtime核的source lane，结果改为每tile本地行优先。
// 不增加MAC，不替换计算核，不增加延迟，也不伪造模式配置应答。
// 数据面当前只定义mode00；其他模式由上层prepare拒绝，不能用本桥喂其独立分组。
module npu_v13_runtime_panel_bridge(
    input wire clk,resetn, // 与原核相同的时钟和协调复位。
    input wire cfg_valid_i, // 来自正式cluster_mode_ctrl的配置事务。
    input wire [1:0] cfg_mode_i, // runtime三模式编码，原样传递。
    output wire cfg_ready_o,cfg_error_o, // 原核实际应答，不是bridge内部猜测。
    output wire [1:0] active_mode_o, // 原核实际模式。
    output wire cluster_idle_o, // 原核无在途packet。
    input wire valid_i,init_i,last_i, // K流有效/SOP/EOP；合法气泡原样保留。
    input wire [4:0] rows_i,cols_i, // 本packet实际shape，1..16。
    input wire [127:0] a_i,b_i, // 16个INT8，行/列0置于低8bit。
    output wire [15:0] valid_o, // 每个物理tile的无反压完成事件。
    output wire [63:0] shape_o, // 每tile四位{rows_m1,cols_m1}。
    output wire [8191:0] matrix_o, // tile0在低512bit，每tile内部row-major。
    output wire error_o // 原核协议/配置错误汇总，黏滞语义由原核定义。
);
    wire [511:0] asrc,bsrc;
    wire [31:0] cr,cc;
    wire [8191:0] cm;
    wire [3:0] rm1=rows_i-1'b1,cm1=cols_i-1'b1;
    genvar tr,tc,r,c;
    generate for(tr=0;tr<4;tr=tr+1) begin:G_R
        for(tc=0;tc<4;tc=tc+1) begin:G_C
            // mode00：A在source 0/4/8/12，B在source 0/1/2/3，由cluster广播。
            assign asrc[(tr*4+tc)*32+:32]=(tc==0)?a_i[tr*32+:32]:32'b0;
            assign bsrc[(tr*4+tc)*32+:32]=(tr==0)?b_i[tc*32+:32]:32'b0;
            assign shape_o[(tr*4+tc)*4+:4]={cr[(tr*4+tc)*2+:2],cc[(tr*4+tc)*2+:2]};
            for(r=0;r<4;r=r+1) begin:G_COPY_R
                for(c=0;c<4;c=c+1) begin:G_COPY_C
                    assign matrix_o[((tr*4+tc)*16+r*4+c)*32+:32]=cm[((tr*4+r)*16+tc*4+c)*32+:32];
                end
            end
        end
    end endgenerate
    npu_v13_systolic_cluster_runtime_stream u_original(
        .clk(clk),.resetn(resetn),.cfg_valid_i(cfg_valid_i),.cfg_mode_i(cfg_mode_i),
        .cfg_ready_o(cfg_ready_o),.cfg_error_o(cfg_error_o),.active_mode_o(active_mode_o),.cluster_idle_o(cluster_idle_o),
        .s_axis_tvalid_i({15'b0,valid_i}),.s_axis_tuser_i({15'b0,init_i}),.s_axis_tlast_i({15'b0,last_i}),
        .active_rows_m1_i({28'b0,rm1}),.active_cols_m1_i({28'b0,cm1}),.a_source_i(asrc),.b_source_i(bsrc),
        .c_tile_valid_o(valid_o),.c_active_rows_m1_o(cr),.c_active_cols_m1_o(cc),.c_matrix_o(cm));
    assign error_o=cfg_error_o;
endmodule
