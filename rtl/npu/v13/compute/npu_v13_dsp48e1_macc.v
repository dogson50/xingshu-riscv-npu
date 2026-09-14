// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_dsp48e1_macc
//
// 功能：V13 两种 tile 共用的有符号 INT8 乘加封装。
//
// 对每个有效 beat 执行：
//   init_i=1：P <= signed(a_i) * signed(b_i)
//   init_i=0：P <= P + signed(a_i) * signed(b_i)
//
// a_i/b_i 会符号扩展到 DSP48E1 的 A/B 输入宽度。B_INPUT_MODE="DIRECT"
// 时使用普通 B 端口，B_INPUT_MODE="CASCADE" 时使用相邻 DSP 的 BCIN。
// 综合分支显式实例化 DSP48E1，并打开 AREG=1、BREG=1、BCASCREG=1、
// OPMODEREG=1、PREG=1：
//   * AREG/BREG 在 DSP 内保存乘法操作数；
//   * OPMODEREG 在 DSP 内保存 init/accumulate 选择，避免控制信号在 DSP
//     ALU 前形成较长的外部组合路径；
//   * PREG 保存累加结果，并由 enable_i 控制是否提交本次 MAC。
//
// enable_i 不是原始接口 valid，而是 PE 中已经延迟过的 valid token；它只
// 控制 PREG 的更新。A/B/OPMODE 仍然每拍进入各自输入寄存器，这一点对脉动
// 阵列的空泡传播和连续 packet 时序非常重要。
//
// 仿真分支不依赖 Xilinx Unisim 库，使用等价的寄存器行为模型，便于 Icarus/
// Verilator 直接运行 RTL testbench；只有定义 SYNTHESIS 时才使用 DSP 原语。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_dsp48e1_macc #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W = 32,
    // 只允许 "DIRECT" 或 "CASCADE"，直接传给 DSP48E1.B_INPUT。
    parameter B_INPUT_MODE = "DIRECT"
) (
    // 时钟与 DSP 内部同步复位。
    input  wire                         clk, // 时钟；DSP 输入寄存与累加提交均在上升沿进行。
    input  wire                         reset_i, // 高有效同步复位；清除 DSP/仿真模型的运算流水寄存器与累加器。
    // 已与 DSP 输入流水对齐的有效提交使能；为 0 时 PREG 保持。
    input  wire                         enable_i, // PREG 提交使能，须与前一拍已锁存的 A/B/init 对齐；0 时保持累加值，不停止输入寄存。
    // 1 表示新 GEMM 首 beat，覆盖旧 P；0 表示对当前 P 做累加。
    input  wire                         init_i, // 随当前 A/B 锁存的首拍标记；对应提交时 1=用本次乘积覆盖 P，0=乘积加旧 P。
    // 有符号乘法操作数。
    input  wire signed [DATA_W-1:0]     a_i, // 当前有符号 A 操作数；每拍进入 DSP A 输入寄存级。
    input  wire signed [DATA_W-1:0]     b_i, // DIRECT 模式的当前有符号 B 操作数；CASCADE 模式不使用此端口。
    // DSP 专用 B 级联链。DIRECT 实例忽略 b_cascade_i；两种实例都会从
    // b_cascade_o 导出其内部 BREG 值，供物理下方的 DSP 使用。
    input  wire signed [17:0]           b_cascade_i, // CASCADE 模式使用的有符号 18 位 B 输入，通常接上方 PE 的 b_cascade_o；DIRECT 时忽略。
    output wire signed [17:0]           b_cascade_o, // 选中 B 输入经过内部 BREG 延迟一拍后的值；沿 DSP 专用级联链传给下方 PE。
    // 当前 DSP PREG/行为模型累加值。
    output wire signed [ACC_W-1:0]      acc_o // 当前 PREG 的低 ACC_W 位有符号累加值；不做饱和处理，也不附带结果有效标志。
);

`ifdef SYNTHESIS
    // DSP48E1 的 A/B 端口分别为 25/18 bit；这里做符号扩展，不改变 INT8
    // 数值含义。P 取低 ACC_W 位，V13 的 INT8 累加范围落在该宽度内。
    wire signed [24:0] a_25_w = {{(25-DATA_W){a_i[DATA_W-1]}}, a_i};
    wire signed [17:0] b_18_w = {{(18-DATA_W){b_i[DATA_W-1]}}, b_i};
    wire [47:0] p_48_w;

    // OPMODE=0110101 选择乘积写入 P（C 端固定为 0）；
    // OPMODE=0100101 选择旧 P 与乘积相加。OPMODEREG=1 使该选择在 DSP 内
    // 部打一拍，从而不把 init 选择放在 DSP ALU 前的外部关键路径上。
    DSP48E1 #(
        .ACASCREG(1), .AREG(1),
        .BCASCREG(1), .BREG(1),
        .B_INPUT(B_INPUT_MODE),
        .ADREG(0), .ALUMODEREG(0),
        .CARRYINREG(0), .CARRYINSELREG(0),
        .CREG(0), .DREG(0), .INMODEREG(0),
        .MREG(0), .OPMODEREG(1), .PREG(1),
        .USE_DPORT("FALSE"), .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48")
    ) u_dsp48e1 (
        .ACOUT(), .BCOUT(b_cascade_o), .CARRYCASCOUT(), .CARRYOUT(),
        .MULTSIGNOUT(), .OVERFLOW(), .P(p_48_w),
        .PATTERNBDETECT(), .PATTERNDETECT(), .PCOUT(), .UNDERFLOW(),
        .A({5'b0, a_25_w}), .ACIN(30'b0), .ALUMODE(4'b0000),
        .B(b_18_w), .BCIN(b_cascade_i), .C(48'b0),
        .CARRYCASCIN(1'b0), .CARRYIN(1'b0), .CARRYINSEL(3'b000),
        .CEA1(1'b0), .CEA2(1'b1), .CEAD(1'b0), .CEALUMODE(1'b0),
        .CEB1(1'b0), .CEB2(1'b1), .CEC(1'b0), .CECARRYIN(1'b0),
        .CECTRL(1'b1), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0),
        .CEP(enable_i), .CLK(clk), .D(25'b0), .INMODE(5'b00000),
        .MULTSIGNIN(1'b0),
        .OPMODE(init_i ? 7'b0110101 : 7'b0100101),
        .PCIN(48'b0),
        .RSTA(reset_i), .RSTALLCARRYIN(reset_i), .RSTALUMODE(reset_i),
        .RSTB(reset_i), .RSTC(reset_i), .RSTCTRL(reset_i), .RSTD(reset_i),
        .RSTINMODE(reset_i), .RSTM(reset_i), .RSTP(reset_i)
    );

    assign acc_o = p_48_w[ACC_W-1:0];
`else
    // 可移植的周期级行为模型。a_r/b_r/init_r 模拟 DSP 输入寄存器，acc_r
    // 模拟 PREG；enable_i=0 时保持旧累加值。这样 Icarus/Verilator 不需要
    // 加载 Vivado Unisim 仿真库，也能覆盖首 beat、空泡和 ACCUM。
    reg signed [DATA_W-1:0] a_r;
    reg signed [17:0]        b_r;
    reg                      init_r;
    reg signed [ACC_W-1:0]  acc_r;
    wire signed [17:0] direct_b_w =
        {{(18-DATA_W){b_i[DATA_W-1]}}, b_i};
    wire signed [17:0] selected_b_w =
        (B_INPUT_MODE == "CASCADE") ? b_cascade_i : direct_b_w;
    wire signed [DATA_W+18-1:0] product_w = a_r * b_r;

    always @(posedge clk) begin
        if (reset_i) begin
            a_r <= 0;
            b_r <= 0;
            init_r <= 1'b0;
            acc_r <= 0;
        end else begin
            a_r <= a_i;
            b_r <= selected_b_w;
            init_r <= init_i;
            if (enable_i) begin
                if (init_r)
                    acc_r <= product_w;
                else
                    acc_r <= acc_r + product_w;
            end
        end
    end

    assign acc_o = acc_r;
    assign b_cascade_o = b_r;
`endif

endmodule
