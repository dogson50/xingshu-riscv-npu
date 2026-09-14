// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_systolic_pe_stream
//
// 功能：连续流 4x4 脉动阵列中的单个 output-stationary PE。
//
// 每次 valid_i=1 的有效波前 beat 到达时，本 PE 执行一次：
//   init_i=1：acc <= signed(a_i) * signed(b_i)
//   init_i=0：acc <= acc + signed(a_i) * signed(b_i)
//
// acc 位于 DSP48E1 的 P 寄存器/反馈路径中。A 使用 fabric 寄存器向右传播；
// B 可从普通端口输入，也可通过 DSP48E1 的 BCIN/BCOUT 专用链向下传播。
// valid_i=0 时数据仍继续前进，但该拍由控制空泡标识，不更新累加值。
// last_i 到达后，result_valid_o 在 post-MAC 值稳定的周期拉高一个拍，顶层再
// 用固定延迟链把不同 PE 的结果对齐。
//
// result_o 直接复用累加器输出，不在每个 PE 旁边再放 ACC_W 位结果快照；
// 连续 packet 的结果安全性由 result_valid token 和顶层对齐链共同保证，
// 而不是依赖暂停整个阵列。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_systolic_pe_stream #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W  = 32,
    // tile 首行设为 0，后续三行设为 1，映射为 DSP 的 B_INPUT=CASCADE。
    parameter integer USE_B_CASCADE = 0
) (
    // 时钟与复位控制。resetn 在本模块内按同步方式检查，并同时送入
    // DSP MAC 封装，保证控制流水和累加器处于同一复位状态。
    input  wire                         clk, // PE 时钟；操作数传播、DSP 运算和有效标记均按上升沿推进。
    input  wire                         resetn, // 低有效同步复位控制 token 与 DSP；A 转发寄存器不复位，须结合 valid 判断数据。
    // valid_i 表示本拍 A/B 是否参与 MAC；init_i 仅在新 GEMM 首 beat 置 1；
    // last_i 表示本 packet 的最后一个有效 beat。
    input  wire                         valid_i, // 当前 A/B beat 参与 MAC 的有效标记；内部延迟一拍后使能累加提交，0 为气泡而非冻结流水。
    input  wire                         init_i, // 当前有效 beat 是新 packet 的首拍，令对应乘积覆盖旧累加值；仅在 valid_i=1 时有协议意义。
    input  wire                         last_i, // 当前有效 beat 是 packet 尾拍；经内部流水生成 result_valid_o，K=1 时与 init_i 同拍。
    // 有符号操作数，必须与上述控制在同一个时钟沿对齐。
    input  wire signed [DATA_W-1:0]     a_i, // 本拍有符号 A 操作数；同时进入 DSP 输入级并经一拍转发给右侧 PE。
    input  wire signed [DATA_W-1:0]     b_i, // 非级联模式的本拍有符号 B 操作数，须与 valid/init/last 对齐；级联模式忽略。
    // B 专用级联输入/输出为 DSP48E1 原生 18-bit 宽度。DIRECT 模式忽略输入；
    // CASCADE 模式忽略普通 b_i，并从 b_cascade_i 获取已经符号扩展的 B。
    input  wire signed [17:0]           b_cascade_i, // 级联模式使用的 18 位有符号 B，接上方 PE 的级联输出；其到达时刻须与当前 A/控制对齐。
    output wire signed [17:0]           b_cascade_o, // DSP 内部 BREG 寄存后的 18 位 B；DIRECT/CASCADE 均输出，用于下方 PE 的一拍垂直传播。
    // 一拍寄存后的 A 操作数转发到右侧 PE；即使 valid_i=0 也继续更新。
    output wire signed [DATA_W-1:0]     a_o, // a_i 延迟一拍后的水平转发值；即使 valid=0 或复位期间也继续更新，本身不附带 valid。
    // DSP 当前累加值，主要用于观察；顶层使用 result_o/result_valid_o 输出结果。
    output wire signed [ACC_W-1:0]      acc_o, // DSP 当前累加值，可观察中间部分和；不是独立锁存的最终结果。
    // result_valid_o=1 时，result_o 是包含 TLAST beat 乘积的最终局部结果。
    output wire                         result_valid_o, // 本拍 result_o 已包含尾 beat 乘积，表示该 packet 最终结果有效；无下游 ready。
    output wire signed [ACC_W-1:0]      result_o // 与 acc_o 接同一累加器；仅在 result_valid_o=1 时采样为最终结果，之后可被下一 packet 改写。
);

    // A 本地转发寄存器形成相邻 PE 间的一拍水平传播延迟。B 的垂直一拍
    // 传播由 DSP 内已经存在的 BREG/BCASCREG 完成，不再重复使用 fabric FF。
    reg signed [DATA_W-1:0] a_pipe_r;
    // valid_pipe_r 是一拍延迟的 valid token，用作 DSP PREG 的 CEP；
    // last_pipe_r 与之对齐，用来产生完成标记。
    reg                     valid_pipe_r;
    reg                     last_pipe_r;
    // 与 acc_w 的 post-MAC 值对齐的单周期结果脉冲。
    reg                     result_valid_r;
    wire signed [ACC_W-1:0] acc_w;

    // 直接连接寄存器/DSP 输出，阵列连线之间不插入隐含组合逻辑。
    assign a_o = a_pipe_r;
    assign acc_o = acc_w;
    assign result_o = acc_w;
    assign result_valid_o = result_valid_r;

    generate
        if (USE_B_CASCADE == 0) begin : g_b_direct
            npu_v13_dsp48e1_macc #(
                .DATA_W(DATA_W), .ACC_W(ACC_W),
                .B_INPUT_MODE("DIRECT")
            ) u_macc (
                .clk(clk), .reset_i(!resetn),
                .enable_i(valid_pipe_r), .init_i(init_i),
                .a_i(a_i), .b_i(b_i),
                .b_cascade_i(18'b0), .b_cascade_o(b_cascade_o),
                .acc_o(acc_w)
            );
        end else begin : g_b_cascade
            npu_v13_dsp48e1_macc #(
                .DATA_W(DATA_W), .ACC_W(ACC_W),
                .B_INPUT_MODE("CASCADE")
            ) u_macc (
                .clk(clk), .reset_i(!resetn),
                .enable_i(valid_pipe_r), .init_i(init_i),
                .a_i(a_i), .b_i({DATA_W{1'b0}}),
                .b_cascade_i(b_cascade_i), .b_cascade_o(b_cascade_o),
                .acc_o(acc_w)
            );
        end
    endgenerate

    // A 只是空间传播数据；valid=0 时不会被 DSP 提交，因此不需要进入
    // reset 网络。B 传播寄存器已经位于 DSP 内部。
    always @(posedge clk) begin
        a_pipe_r <= a_i;
    end

    // 本过程只负责控制 token；MAC 的输入/P 寄存器由封装管理。非阻塞赋值
    // 保证 result_valid_r 使用与 post-MAC 结果对应的旧 token。
    always @(posedge clk) begin
        if (!resetn) begin
            valid_pipe_r <= 1'b0;
            last_pipe_r <= 1'b0;
            result_valid_r <= 1'b0;
        end else begin
            valid_pipe_r <= valid_i;
            last_pipe_r <= last_i;
            result_valid_r <= valid_pipe_r && last_pipe_r;
        end
    end
endmodule
