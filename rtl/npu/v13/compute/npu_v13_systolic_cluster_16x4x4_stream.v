// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_systolic_cluster_16x4x4_stream
//
// 固定的 16 核连续流集群：4 行 × 4 列个 4×4 tile。
//
// 这个版本刻意不再使用 GROUP_TILE_ROWS/GROUP_TILE_COLS 等通用参数，直接把
// “一个输入 lane 对应一个 4×4 tile”写在端口和 generate 结构中，便于阅读、
// 仿真和后续数据搬运器实现。物理阵列仍然是 16 个独立的
// npu_v13_systolic_tile_4x4_stream，逻辑上的 16×16 矩阵只是输出端的固定
// row-major 拼接：
//
//   lane  0   1   2   3       tile row 0
//   lane  4   5   6   7       tile row 1
//   lane  8   9  10  11       tile row 2
//   lane 12  13  14  15       tile row 3
//
// lane = tile_row*4 + tile_col。
// 每个 lane 独立接收一个 A[4] 列向量和一个 B[4] 行向量，并产生自己在全局
// 16×16 矩阵中对应的 4×4 子块：
//
//   C[4*tile_row + r][4*tile_col + c]
//       = tile_C[r][c]，r,c=0..3。
//
// 连续流协议
// ------------
// 本模块没有 ready/backpressure，也没有 clear/flush。每个 lane 在 tvalid=1
// 的时钟沿接收一个 beat；tuser 是 packet 首 beat 的单周期 init 标记，tlast
// 是 packet 尾 beat 的单周期结果标记。TVALID=0 只向该 tile 注入空泡，不能
// 冻结已有数据。下游必须在 c_valid_o[lane]=1 的周期采样该 lane 对应的
// 4×4 结果，否则下一次结果会覆盖总线上的值。
//
// 形状编码
// ----------
// active_rows_m1_i[lane*2 +: 2] 和 active_cols_m1_i[lane*2 +: 2] 与单个
// 4×4 子核完全相同，采用 count-1 编码：
//   2'b00 -> 1，2'b01 -> 2，2'b10 -> 3，2'b11 -> 4。
// 因而每个 lane 只需 2 bit，且每个 tile 可以独立处理尾块形状。这里没有
// “0 表示空 shape”的额外状态；若上层需要跳过某个 lane，直接令该 lane
// 的 tvalid=0 即可。结果端用同样紧凑的 2-bit/lane sideband 返回与每个
// c_valid_o[lane] 同拍的 shape；矩阵中超出该 shape 的元素是 don't-care。
//
// 输入打包
// ----------
// A 和 B 均按 lane 从低位到高位排列，lane 内再按行/列从低位到高位排列：
//   a_rows_i[lane*4*DATA_W + r*DATA_W +: DATA_W] = A[r][k]
//   b_cols_i[lane*4*DATA_W + c*DATA_W +: DATA_W] = B[k][c]
// 每个 lane 的有效 beat 完全独立，因此可以让 16 个 4×4 tile 同时工作。
//
// 时序结构
// ----------
// 集群边界为每个 lane 保留一级局部 A/B/shape 寄存器，再把控制寄存器送入
// 子核。这样广播器/搬运器到每个 tile 的路径是清晰的 reg-to-reg 路径，
// 同时保持每拍一个 beat 的 initiation interval。子核内部的 row+col 波前、
// TLAST 对齐和结果延迟保持不变；从输入 TLAST 到对应 c_valid_o 的协议
// 延迟为固定 10 拍（DATA_W=8、ACC_W=32 的已验证配置）。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_systolic_cluster_16x4x4_stream #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W  = 32
) (
    input  wire                         clk, // 统一计算时钟；输入、控制和输出均以上升沿为基准。
    input  wire                         resetn, // 低有效复位；清除协议/有效状态，并复位 PE/DSP；不要求所有数据寄存器归零。

    // 16 个 tile 各自一条固定速率控制通道；没有 tready。
    //
    // 例如 s_axis_tvalid[6] 对应 tile(1,2)。当它在某个上升沿为 1 时，
    // lane 6 的这一拍数据会被接收；同一 lane 的 tuser/tlast 也在该拍解释。
    // 不同 lane 可以独立地插入空泡，但某个 lane 不能依靠 ready 暂停已有
    // packet，因为阵列内部的波前仍会继续向前推进。
    input  wire [15:0]                  s_axis_tvalid, // 每位对应一个物理 tile 的输入有效；lane=tile_row*4+tile_col，无 ready，0 只注入空泡。
    input  wire [15:0]                  s_axis_tuser, // 每 lane 的 packet 首有效拍标记；为 1 时初始化该 tile 累加，仅在对应 valid=1 时解释。
    input  wire [15:0]                  s_axis_tlast, // 每 lane 的 packet 尾有效拍标记；K=1 时可与 tuser 同拍为 1，仅在对应 valid=1 时解释。

    // 每 lane 的 active_rows/cols，采用子核同样的 2-bit count-1 编码。
    // 第 lane 个字段的起始 bit 是 lane*2。例如 lane=6 的行数编码位于
    // active_rows_m1_i[13:12]，列数编码位于 active_cols_m1_i[13:12]。
    input  wire [16*2-1:0]              active_rows_m1_i, // 各 tile 的有效行数减一；[lane*2 +: 2] 的 0..3 表示 1..4 行，在该 lane 首有效拍采样。
    input  wire [16*2-1:0]              active_cols_m1_i, // 各 tile 的有效列数减一；[lane*2 +: 2] 的 0..3 表示 1..4 列，在该 lane 首有效拍采样。

    // 每 lane 一个 A[4] 列向量和 B[4] 行向量。
    // 每个向量内部也是低编号元素在低位：lane=6 的 A[2] 位于
    // a_rows_i[(6*4+2)*DATA_W +: DATA_W]，B[3] 的切片规则相同。
    input  wire [16*4*DATA_W-1:0]       a_rows_i, // 16 路 A[4] 有符号向量；lane 内第 r 个元素位于 [(lane*4+r)*DATA_W +: DATA_W]。
    input  wire [16*4*DATA_W-1:0]       b_cols_i, // 16 路 B[4] 有符号向量；lane 内第 c 个元素位于 [(lane*4+c)*DATA_W +: DATA_W]，与该 lane 控制同拍。

    // 每个 tile 独立的结果有效脉冲。
    output wire [15:0]                  c_valid_o, // 每位标识对应物理 tile 的最终 4x4 结果本拍有效；无反压，下游须逐拍接收。
    // 每个 tile 与结果同拍的 2-bit count-1 本地 shape。
    output wire [16*2-1:0]              c_active_rows_m1_o, // 每 tile 结果的本地有效行数减一，每字段 2 位；仅在对应 c_valid_o=1 时有意义。
    output wire [16*2-1:0]              c_active_cols_m1_o, // 每 tile 结果的本地有效列数减一，每字段 2 位；仅在对应 c_valid_o=1 时有意义。
    // 全局 16×16 row-major 结果，元素索引为 row*16+col。
    output wire [16*16*ACC_W-1:0]       c_matrix_o // 固定全局 16x16 行优先拼接，元素 [(row*16+col)*ACC_W +: ACC_W]；按 tile valid/shape 取有符号结果，越界元素不保证为零。
);
    // 这些常量把接口宽度和索引关系集中写出，避免在 generate 体内重复
    // 出现难以阅读的乘法表达式。修改 DATA_W/ACC_W 时，端口和所有局部
    // 连接会自动保持一致；tile 数量和宏矩阵尺寸则固定为 16 个、16×16。
    localparam integer TILE_COUNT     = 16;
    localparam integer TILE_DATA_W    = 4*DATA_W;
    localparam integer TILE_MATRIX_W  = 16*ACC_W;
    localparam integer MACRO_COLS     = 16;

    // tile_matrix_w 仍按物理 lane 顺序保存每个子核的局部矩阵；最后的
    // 固定连线 generate 把它们放到全局 row-major c_matrix_o。
    //
    // tile_matrix_w 的布局是：
    //   [lane*16*ACC_W + local_index*ACC_W +: ACC_W]
    // 其中 local_index=local_row*4+local_col。它只是内部中间总线，
    // 不作为模块端口暴露，因此不会要求上层理解“按 lane 拼接”的布局。
    wire [TILE_COUNT*TILE_MATRIX_W-1:0] tile_matrix_w;

    genvar tile_row_g;
    genvar tile_col_g;
    genvar local_row_g;
    genvar local_col_g;
    generate
        for (tile_row_g = 0; tile_row_g < 4;
             tile_row_g = tile_row_g + 1) begin : g_tile_rows
            for (tile_col_g = 0; tile_col_g < 4;
                 tile_col_g = tile_col_g + 1) begin : g_tile_cols
                // 以下所有 localparam 都在 elaboration 时求值，综合后只会
                // 变成常量位选/布线，不会形成运行时乘法器或 crossbar。
                localparam integer LANE = tile_row_g*4 + tile_col_g;

                // 从宽总线截出当前 lane 的一整组 A/B 数据。这里的 +:
                // 是固定宽度 part-select，LANE 是 generate 常量；综合后
                // 等价于一组静态导线，不会推导出可变地址存储器。
                wire [TILE_DATA_W-1:0] lane_a_w =
                    a_rows_i[LANE*TILE_DATA_W +: TILE_DATA_W];
                wire [TILE_DATA_W-1:0] lane_b_w =
                    b_cols_i[LANE*TILE_DATA_W +: TILE_DATA_W];
                wire [1:0] lane_rows_m1_w =
                    active_rows_m1_i[LANE*2 +: 2];
                wire [1:0] lane_cols_m1_w =
                    active_cols_m1_i[LANE*2 +: 2];

                // 每个 tile 一份边界寄存器。A/B/shape 数据不需要 reset，
                // 因为只有 tvalid 波前为 1 时子核才会解释这些值；这样可
                // 避免 16×(512 bit) 的复位选择器和高扇出复位网络。
                //
                // 一个输入 beat 的时间关系如下：
                //   T0：上层把 lane_*_w 和控制信号放在接口上；
                //   T1：本级寄存器锁存，lane_valid_r 记录 T0 的 valid；
                //   T2：子核看到 lane_valid_r=1，开始该 beat 的波前计算。
                // 因此本集群边界增加 1 拍延迟，但不会改变 initiation interval。
                (* keep = "true" *) reg [TILE_DATA_W-1:0] lane_a_r;
                (* keep = "true" *) reg [TILE_DATA_W-1:0] lane_b_r;
                (* keep = "true" *) reg [1:0] lane_rows_m1_r;
                (* keep = "true" *) reg [1:0] lane_cols_m1_r;
                (* keep = "true" *) reg lane_valid_r;
                (* keep = "true" *) reg lane_user_r;
                (* keep = "true" *) reg lane_last_r;

                always @(posedge clk) begin
                    lane_a_r       <= lane_a_w;
                    lane_b_r       <= lane_b_w;
                    lane_rows_m1_r <= lane_rows_m1_w;
                    lane_cols_m1_r <= lane_cols_m1_w;
                end

                always @(posedge clk or negedge resetn) begin
                    if (!resetn) begin
                        lane_valid_r <= 1'b0;
                    end else begin
                        lane_valid_r <= s_axis_tvalid[LANE];
                    end
                end

                // tuser/tlast 与该 lane 的 valid 同步进入子核。协议上它们
                // 只在 valid=1 时有意义，因此数据寄存器无需复位。K=1 packet
                // 时 tuser 和 tlast 可以在同一拍同时为 1；连续 K=1 packet
                // 时波形可能连续保持高电平，但每个周期仍代表一个独立事件。
                always @(posedge clk) begin
                    lane_user_r <= s_axis_tuser[LANE];
                    lane_last_r <= s_axis_tlast[LANE];
                end

                // 一个 u_tile 就是完整的 4×4 output-stationary 脉动阵列：
                //   lane_a_r -> 左边界的 A[0..3]
                //   lane_b_r -> 上边界的 B[0..3]
                // 子核内部负责 row+col 波前延迟、MAC 累加，以及 TLAST 结果
                // 和紧凑 shape sideband 对齐；本模块不重复实现这些逻辑。
                npu_v13_systolic_tile_4x4_stream #(
                    .DATA_W(DATA_W),
                    .ACC_W(ACC_W)
                ) u_tile (
                    .clk            (clk),
                    .resetn         (resetn),
                    .active_rows_i  (lane_rows_m1_r),
                    .active_cols_i  (lane_cols_m1_r),
                    .s_axis_tvalid  (lane_valid_r),
                    .s_axis_tdata   ({lane_b_r, lane_a_r}),
                    .s_axis_tlast   (lane_last_r),
                    .s_axis_tuser   (lane_user_r),
                    .c_valid_o      (c_valid_o[LANE]),
                    .c_active_rows_m1_o
                                    (c_active_rows_m1_o[LANE*2 +: 2]),
                    .c_active_cols_m1_o
                                    (c_active_cols_m1_o[LANE*2 +: 2]),
                    .c_matrix_o     (tile_matrix_w[LANE*TILE_MATRIX_W +:
                                                    TILE_MATRIX_W])
                );

                // 局部 4×4 矩阵写入全局 16×16 row-major 总线。例如 lane=6
                // 是 tile(1,2)，其局部 (r,c) 对应全局 (4+r,8+c)。
                //
                // 先由 tile 坐标和局部坐标计算全局坐标：
                //   global_row = tile_row*4 + local_row
                //   global_col = tile_col*4 + local_col
                // 再由 row-major 规则得到一个元素编号：
                //   global_index = global_row*16 + global_col
                // 最终每个 ACC_W 位切片只有一个固定驱动源，因此整个输出
                // 重排不会生成动态 mux，也不增加额外时钟延迟。
                for (local_row_g = 0; local_row_g < 4;
                     local_row_g = local_row_g + 1) begin : g_local_rows
                    for (local_col_g = 0; local_col_g < 4;
                         local_col_g = local_col_g + 1) begin : g_local_cols
                        localparam integer LOCAL_INDEX =
                            local_row_g*4 + local_col_g;
                        localparam integer GLOBAL_ROW =
                            tile_row_g*4 + local_row_g;
                        localparam integer GLOBAL_COL =
                            tile_col_g*4 + local_col_g;
                        localparam integer GLOBAL_INDEX =
                            GLOBAL_ROW*MACRO_COLS + GLOBAL_COL;

                        assign c_matrix_o[GLOBAL_INDEX*ACC_W +: ACC_W] =
                            tile_matrix_w[(LANE*16 + LOCAL_INDEX)*ACC_W +:
                                          ACC_W];
                    end
                end
            end
        end
    endgenerate
endmodule
