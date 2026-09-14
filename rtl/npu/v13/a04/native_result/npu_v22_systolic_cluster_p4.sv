// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

// p22 native P4 cluster. Input/mode timing retained.
module npu_v22_systolic_cluster_p4 #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W = 32,
    parameter integer CAPTURE_SLOTS = 4
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
    // 每 tile 独立 P4 行流，低 lane 使用低位切片。
    input wire [15:0] reserve_valid_i,
    output wire [15:0] reserve_ready_o,
    input wire [47:0] reserve_meta_i,
    output wire [15:0] row_valid_o,
    input wire [15:0] row_ready_i,
    output wire [2047:0] row_data_o,
    output wire [63:0] row_keep_o,
    output wire [31:0] row_index_o,
    output wire [767:0] row_meta_o,
    output wire [15:0] row_error_o
);
    // 这些常量把接口宽度和索引关系集中写出，避免在 generate 体内重复
    // 出现难以阅读的乘法表达式。修改 DATA_W/ACC_W 时，端口和所有局部
    // 连接会自动保持一致；tile 数量和宏矩阵尺寸则固定为 16 个、16×16。
    localparam integer TILE_COUNT     = 16;
    localparam integer TILE_DATA_W    = 4*DATA_W;

    // 16 条本地 P4 行流直接接各结果组，不生成全局矩阵载荷总线。

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
                npu_v22_systolic_tile_p4 #(
                    .DATA_W(DATA_W),
                    .ACC_W(ACC_W),.CAPTURE_SLOTS(CAPTURE_SLOTS)
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
                    .reserve_valid_i(reserve_valid_i[LANE]),.reserve_ready_o(reserve_ready_o[LANE]),
                    .reserve_meta_i(reserve_meta_i),.row_valid_o(row_valid_o[LANE]),.row_ready_i(row_ready_i[LANE]),
                    .row_data_o(row_data_o[LANE*128+:128]),.row_keep_o(row_keep_o[LANE*4+:4]),
                    .row_index_o(row_index_o[LANE*2+:2]),.row_meta_o(row_meta_o[LANE*48+:48]),
                    .row_error_o(row_error_o[LANE])
                );


            end
        end
    endgenerate
endmodule
