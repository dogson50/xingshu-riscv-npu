// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// A04 的“紧凑 panel 输入 -> 通用 runtime 阵列接口”适配桥。
//
// 本模块不执行 MAC，也不缓存最终结果；它只完成接口形状转换：
//   panel_feeder_exp 每拍给出一组紧凑的 A[16]、B[16]（各 128-bit）以及
//   一组 valid/init/last/rows/cols；下游 npu_v22_systolic_runtime_p4 则使用
//   16 个物理 source lane 来描述 4x4 个 tile 的边界输入与控制。
//
// 当前正式 GEMM 路径只执行 runtime MODE_16X16（mode=2'b00）：
//   * A 被拆成 4 个 32-bit 向量，送到 tile 阵列左边界 lane 0/4/8/12；
//   * B 被拆成 4 个 32-bit 向量，送到 tile 阵列上边界 lane 0/1/2/3；
//   * valid/init/last 只送逻辑组锚点 lane 0；runtime 再广播到 16 个 tile；
//   * rows/cols 在本模块转换为 count-1，放在 shape 总线最低 4 位。
// 其他 mode 的配置端口为了兼容通用 runtime 接口仍然透传，但当前上游
// exec_panel_adapter 会拒绝非 mode00 任务，因此本桥不承担 8x8/4x4 多组供数。
//
// 结果侧不重新拼出整幅 c_matrix：16 个 tile 的原生 P4 行流、预约接口和
// 元数据直接透传给四个 result island，避免中央超宽结果汇合。
module npu_v22_runtime_panel_bridge #(parameter integer CAPTURE_SLOTS=4)(
    // 与 packet backend/计算阵列同一时钟域；resetn 清除有效与协议状态。
    input wire clk,resetn,cfg_valid_i,
    // runtime 逻辑阵列模式请求；当前正式数据路径只实际使用 2'b00=16x16。
    input wire [1:0] cfg_mode_i,
    output wire cfg_ready_o,cfg_error_o,
    output wire [1:0] active_mode_o,
    output wire cluster_idle_o,

    // panel feeder 的单组流控制。init_i 对应 packet 首拍，last_i 对应 K 尾拍。
    input wire valid_i,init_i,last_i,
    // 当前 16x16 packet 的实际有效 M/N，合法范围为 1..16。
    input wire [4:0] rows_i,cols_i,
    // 紧凑边界数据：a_i=16个INT8行元素，b_i=16个INT8列元素。
    input wire [127:0] a_i,b_i,

    // 16 个物理 tile 的原始完成事件；用于 packet backend 的返回计账。
    output wire [15:0] valid_o,
    // 每 tile 在启动计算前预留原生结果捕获槽；meta 通常为 {tag,m,n}。
    input wire [15:0] reserve_valid_i,
    output wire [15:0] reserve_ready_o,
    input wire [47:0] reserve_meta_i,
    // 16 路独立 P4 行结果流。每路 128-bit=4个INT32，可分别反压。
    output wire [15:0] row_valid_o,
    input wire [15:0] row_ready_i,
    output wire [2047:0] row_data_o,
    // 每 tile：4-bit有效lane、2-bit行号、48-bit {tag,m,n} 元数据。
    output wire [63:0] row_keep_o,
    output wire [31:0] row_index_o,
    output wire [767:0] row_meta_o,
    output wire [15:0] row_error_o,
    // 桥级错误目前只汇总 runtime 配置错误；逐 tile 捕获错误走 row_error_o。
    output wire error_o
);
    // 通用 runtime 接口共有16个source lane，每lane携带4个INT8=32-bit。
    // asrc/bsrc 因而各为 16*32=512-bit，但只有阵列边界lane承载非零数据。
    wire [511:0] asrc,bsrc;

    // runtime 的16x16逻辑组使用4-bit count-1 shape：1..16编码为0..15。
    // rows_i/cols_i 的零值应已被上游参数检查拒绝，本模块不重复做范围判断。
    wire [3:0] rm1=rows_i-1'b1,cm1=cols_i-1'b1;

    genvar tr,tc;
    generate for(tr=0;tr<4;tr=tr+1)begin:G_R
        for(tc=0;tc<4;tc=tc+1)begin:G_C
            // MODE_16X16 的 A 源位于每个 tile row 的最左侧：lane 0/4/8/12。
            // a_i 每32-bit为该 tile row 对应的4个INT8行元素；其余lane补零。
            assign asrc[(tr*4+tc)*32+:32]=(tc==0)?a_i[tr*32+:32]:32'b0;
            // MODE_16X16 的 B 源位于最上方 tile row：lane 0/1/2/3。
            // b_i 每32-bit为该 tile column 对应的4个INT8列元素；其余lane补零。
            assign bsrc[(tr*4+tc)*32+:32]=(tr==0)?b_i[tc*32+:32]:32'b0;
        end
    end endgenerate

    // 通用 runtime 根据 active_mode 将边界A/B和锚点控制广播到物理tile。
    // 这里的 u_original 名称表示沿用原 runtime 逻辑，不代表旁路或仿真模型。
    npu_v22_systolic_runtime_p4 #(.CAPTURE_SLOTS(CAPTURE_SLOTS)) u_original(
        .clk(clk),.resetn(resetn),.cfg_valid_i(cfg_valid_i),.cfg_mode_i(cfg_mode_i),
        .cfg_ready_o(cfg_ready_o),.cfg_error_o(cfg_error_o),.active_mode_o(active_mode_o),.cluster_idle_o(cluster_idle_o),
        // 16x16模式只有一个逻辑计算组，lane0是该组的控制锚点。
        .s_axis_tvalid_i({15'b0,valid_i}),.s_axis_tuser_i({15'b0,init_i}),.s_axis_tlast_i({15'b0,last_i}),
        // 16x16组的shape字段位于最低4位；其余28位供其他运行模式使用并置零。
        .active_rows_m1_i({28'b0,rm1}),.active_cols_m1_i({28'b0,cm1}),.a_source_i(asrc),.b_source_i(bsrc),
        // 不在桥内消费tile-local shape；row_keep_o已经携带最终逐lane有效信息。
        .c_tile_valid_o(valid_o),.c_active_rows_m1_o(),.c_active_cols_m1_o(),
        // 原生捕获槽及16路P4行流直接连接到下游四个result island。
        .reserve_valid_i(reserve_valid_i),.reserve_ready_o(reserve_ready_o),.reserve_meta_i(reserve_meta_i),
        .row_valid_o(row_valid_o),.row_ready_i(row_ready_i),.row_data_o(row_data_o),.row_keep_o(row_keep_o),
        .row_index_o(row_index_o),.row_meta_o(row_meta_o),.row_error_o(row_error_o));

    // cfg_error_o 是runtime产生的一拍配置错误；数据捕获错误不在这里二次OR，
    // 由 packet backend 分别检查 row_error_o，避免形成跨16个tile的额外错误长线。
    assign error_o=cfg_error_o;
endmodule