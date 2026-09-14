// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_systolic_cluster_runtime_stream
//
// 功能概述
// --------
// 以 16 个始终独立的 4x4 连续流核作为固定物理后端，在核前放置
// 可运行时配置的分层广播器。模式切换不改变端口宽度和 generate 结构，
// 仅改变每个核前的局部 3:1 源选择，支持：
//
//   MODE_16X16  (2'b00) : 1 个 16x16 逻辑组；
//   MODE_4X8X8  (2'b01) : 4 个独立 8x8 逻辑组；
//   MODE_16X4X4 (2'b10) : 16 个独立 4x4 逻辑组。
//
// 固定源通道布局
// ------------
// A/B 都固定提供 16 个 4*DATA_W 源通道，源通道按物理 tile
// row-major 编号 lane=tile_row*4+tile_col。不同模式只需驱动下列通道：
//
//   16x16:
//     A 使用 lane 0/4/8/12，每个 tile 行向右广播；
//     B 使用 lane 0/1/2/3， 每个 tile 列向下广播；
//     packet 控制使用组锚点 lane 0；shape 使用紧凑 group 0 字段。
//
//   4x8x8:
//     组锚点为 lane 0/2/8/10。每个 2x2 tile 象限内，A 从该组
//     左边界向右广播，B 从该组上边界向下广播；shape 使用紧凑
//     group 0..3 字段。
//
//   16x4x4:
//     A/B/control 使用当前 tile 自己的 lane；shape 的 group 0..15
//     与 tile 0..15 一一对应。固定后端继续使用每 tile 2-bit
//     count-1 编码。
//
// 因而 DATA_W=8 时的有效 A+B 读带宽分别是 256/512/1024 bit/拍，
// 但三种模式都能同时喂满 16*16=256 个 MAC。未使用源通道不需要
// 从 SRAM 读出，上层数据搬运器可据此关闭对应 bank/read-enable。
//
// 配置协议
// --------
// cfg_valid_i && cfg_ready_o 在上升沿提交新模式。cfg_ready_o 仅在：
//   * 没有未结束 packet；
//   * 数据/结果流水已全部排空；
//   * 当前周期没有新输入 valid
// 时才为 1。上层必须在配置握手的下一拍或之后开始发数据。
// 模式 2'b11 非法：握手后保持原模式，cfg_error_o 脉冲一拍。
//
// 任务恢复契约
// ----------
// 连续流层级不提供 clear/flush 端口，也不支持中途取消 packet。上层必须把
// 已启动的 packet 完整发送到 TLAST；新 packet 的 TUSER/init 会覆盖各 PE
// 的旧累加值，因此正常任务之间无需清零。协议损坏时只能复位整个 NPU，
// resetn 释放后需重新提交所需运行模式。
//
// 时序结构
// --------
// 入口先用一级无 reset 数据寄存器锁存全部源通道，再经局部 3:1
// 选择器到固定 npu_v13_systolic_cluster_16x4x4_stream 的每核边界寄存器。这使
// 广播/选择器成为真实可测的 reg-to-reg 路径，而不是被 OOC 边界
// false-path 掩盖。从外部 TLAST 接收周期到 c_tile_valid_o 的仿真协议
// 延迟固定为 10 拍，initiation interval 仍为 1。
//////////////////////////////////////////////////////////////////////////////////

module npu_v13_systolic_cluster_runtime_stream #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W = 32
) (
    input  wire                         clk, // 计算与模式配置的共同时钟；所有输入在上升沿采样。
    input  wire                         resetn, // 低有效复位；清空协议/在途有效状态并将模式恢复为 00；不保证全部数据寄存器归零。

    input  wire                         cfg_valid_i, // 模式请求有效；与 cfg_ready_o 同拍为 1 才提交，等待期间保持 cfg_mode_i 稳定。
    input  wire [1:0]                   cfg_mode_i, // 目标模式：00=1组16x16，01=4组8x8，10=16组4x4；11 非法，拒绝并保持原模式。
    output wire                         cfg_ready_o, // 当前允许提交配置：集群空闲且所有输入 valid 为 0；配置握手后的下一周期或更晚才可送新数据。
    output reg                          cfg_error_o, // 非法模式请求握手后寄存输出一拍错误脉冲；不是持续错误状态。
    output wire [1:0]                   active_mode_o, // 当前已生效的逻辑阵列模式，复位为 00；用于上游确认配置，不代表计算完成。
    output wire                         cluster_idle_o, // packet_open、排空计数、输入寄存 valid 和输出 tile valid 均为零；只表示跟踪状态空闲，不是协议合法性检查。

    // 每个 source lane 一组 packet 控制。广播模式下只有组锚点 lane
    // 的 valid/user/last 被使用，A/B 边界 lane 只提供数据；shape
    // 独立使用下方按逻辑 group 紧凑排列的总线。
    input  wire [15:0]                  s_axis_tvalid_i, // source lane 有效位；00 仅 lane0，01 仅 lane0/2/8/10，10 使用全部 lane；无数据 ready。
    input  wire [15:0]                  s_axis_tuser_i, // 各逻辑组锚点 lane 的首有效拍标记，启动新累加；非锚点控制位不参与该模式计算。
    input  wire [15:0]                  s_axis_tlast_i, // 各逻辑组锚点 lane 的尾有效拍标记；K=1 时与 tuser 同拍，valid=0 时不表示结束。
    // shape 属于逻辑计算组，而不是 A/B source lane。行、列各使用一条
    // 32-bit 紧凑总线，并随 mode 采用不同的 count-1 字段宽度：
    //   MODE_16X16 ：group 0 使用 [3:0]；
    //   MODE_4X8X8 ：group g 使用 [g*3 +: 3]，g=0..3；
    //   MODE_16X4X4：group g 使用 [g*2 +: 2]，g=0..15。
    // 每个有效 group 至少有 1 行/列，所以全零字段表示实际 1 行/列；
    // group 是否有效仍由对应锚点的 s_axis_tvalid_i 决定。
    input  wire [16*2-1:0]              active_rows_m1_i, // 逻辑组有效行数减一的紧凑 32 位总线；按模式取 1个4位/4个3位/16个2位字段，组首有效拍采样。
    input  wire [16*2-1:0]              active_cols_m1_i, // 逻辑组有效列数减一；字段布局同 rows，不是固定每 source lane 一份 2 位 shape；0 表示实际 1 列。
    input  wire [16*4*DATA_W-1:0]       a_source_i, // 16 路 A[4] 有符号源向量，低编号元素在低位；00 模式使用 lane0/4/8/12，其余模式按组边界广播。
    input  wire [16*4*DATA_W-1:0]       b_source_i, // 16 路 B[4] 有符号源向量，低编号元素在低位；00 模式使用 lane0/1/2/3，与对应组的有效控制同拍。

    // 始终按 16 个物理 4x4 tile 输出 valid 和同拍的本地 shape。输出矩阵
    // 始终为全局 16x16 row-major，tile(row,col) 占据全局对应 4x4 区域；
    // 每个有效 tile 中超出返回 shape 的元素是 don't-care。
    output wire [15:0]                  c_tile_valid_o, // 16 个物理 tile 的本拍最终结果有效位，索引 tile_row*4+tile_col；不按逻辑组重新排列，无输出反压。
    output wire [16*2-1:0]              c_active_rows_m1_o, // 每物理 tile 的本地有效行数减一，[tile*2 +: 2]；只在该 tile 的结果 valid=1 时使用。
    output wire [16*2-1:0]              c_active_cols_m1_o, // 每物理 tile 的本地有效列数减一，[tile*2 +: 2]；与对应结果 valid 和矩阵数据同拍。
    output wire [16*16*ACC_W-1:0]       c_matrix_o // 始终按全局 16x16 行优先拼接的 ACC_W 位有符号结果；仅采样 valid tile 的有效 shape 区域，其他元素无保证。
);
    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;
    localparam integer RESULT_LATENCY = 10;

    reg [1:0] active_mode_r;
    // 每核一份本地 mode 寄存器，避免单个 mode 网直接驱动整个
    // 1024-bit 选择平面。keep 允许布局器把副本放在对应 tile 附近。
    (* keep = "true" *) reg [1:0] tile_mode_r [0:15];

    // 输入数据/shape 不需 reset；只有同拍 source_valid_r 有效时才会被
    // 后端消费，去掉宽 reset mux 能节省资源并改善扇出。
    reg [16*4*DATA_W-1:0] a_source_r;
    reg [16*4*DATA_W-1:0] b_source_r;
    reg [16*2-1:0] active_rows_m1_r;
    reg [16*2-1:0] active_cols_m1_r;
    reg [15:0] source_valid_r;
    reg [15:0] source_user_r;
    reg [15:0] source_last_r;

    // packet_open_r 只在当前模式的组锚点位上使用。drain_count_r
    // 每次输入活动都重载，用于等待最后一拍数据穿过 10 拍流水。
    reg [15:0] packet_open_r;
    reg [3:0] drain_count_r;
    reg [15:0] active_group_mask_w;
    wire [15:0] active_group_valid_w =
        s_axis_tvalid_i & active_group_mask_w;
    wire any_input_activity_w = |active_group_valid_w;

    wire [15:0] core_valid_w;
    wire [15:0] core_user_w;
    wire [15:0] core_last_w;
    wire [16*2-1:0] core_active_rows_m1_w;
    wire [16*2-1:0] core_active_cols_m1_w;
    wire [16*4*DATA_W-1:0] core_a_rows_w;
    wire [16*4*DATA_W-1:0] core_b_cols_w;

    assign active_mode_o = active_mode_r;
    assign cluster_idle_o =
        (packet_open_r == 16'b0) &&
        (drain_count_r == 4'd0) &&
        (source_valid_r == 16'b0) &&
        (c_tile_valid_o == 16'b0);
    // 配置提交周期不允许与新数据同拍，避免新/旧 mode 语义模糊。
    assign cfg_ready_o = cluster_idle_o && (s_axis_tvalid_i == 16'b0);

    always @* begin
        case (active_mode_r)
            MODE_16X16:  active_group_mask_w = 16'h0001;
            MODE_4X8X8:  active_group_mask_w = 16'h0505; // lane 0/2/8/10
            MODE_16X4X4: active_group_mask_w = 16'hffff;
            default:     active_group_mask_w = 16'h0001;
        endcase
    end

    integer mode_copy_i;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            active_mode_r <= MODE_16X16;
            cfg_error_o <= 1'b0;
            for (mode_copy_i = 0; mode_copy_i < 16;
                 mode_copy_i = mode_copy_i + 1)
                tile_mode_r[mode_copy_i] <= MODE_16X16;
        end else begin
            cfg_error_o <= 1'b0;
            // 本地 mode 副本每拍无条件跟随主 mode。这样寄存器没有
            // “cluster_idle/cfg_ready→CE”的深组合路径。提交后副本下一拍
            // 同步；新数据同时先进入 source 寄存器，到达局部选择器
            // 时 mode 已稳定，因而吞吐和结果延迟都不变。
            for (mode_copy_i = 0; mode_copy_i < 16;
                 mode_copy_i = mode_copy_i + 1)
                tile_mode_r[mode_copy_i] <= active_mode_r;
            if (cfg_valid_i && cfg_ready_o) begin
                if (cfg_mode_i != 2'b11) begin
                    active_mode_r <= cfg_mode_i;
                end else begin
                    cfg_error_o <= 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        a_source_r <= a_source_i;
        b_source_r <= b_source_i;
        active_rows_m1_r <= active_rows_m1_i;
        active_cols_m1_r <= active_cols_m1_i;
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn)
            source_valid_r <= 16'b0;
        else
            source_valid_r <= s_axis_tvalid_i;
    end

    // user/last 只有在同拍 source_valid_r=1 时才会被后端解释，无需复位。
    always @(posedge clk) begin
        source_user_r <= s_axis_tuser_i;
        source_last_r <= s_axis_tlast_i;
    end

    integer packet_lane_i;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            packet_open_r <= 16'b0;
            drain_count_r <= 4'd0;
        end else begin
            if (any_input_activity_w)
                drain_count_r <= RESULT_LATENCY[3:0];
            else if (drain_count_r != 4'd0)
                drain_count_r <= drain_count_r - 4'd1;

            for (packet_lane_i = 0; packet_lane_i < 16;
                 packet_lane_i = packet_lane_i + 1) begin
                if (active_group_valid_w[packet_lane_i]) begin
                    if (s_axis_tuser_i[packet_lane_i])
                        packet_open_r[packet_lane_i] <= 1'b1;
                    if (s_axis_tlast_i[packet_lane_i])
                        packet_open_r[packet_lane_i] <= 1'b0;
                end
            end
        end
    end

    genvar tile_row_g;
    genvar tile_col_g;
    generate
        for (tile_row_g = 0; tile_row_g < 4;
             tile_row_g = tile_row_g + 1) begin : g_runtime_rows
            for (tile_col_g = 0; tile_col_g < 4;
                 tile_col_g = tile_col_g + 1) begin : g_runtime_cols
                localparam integer TILE_INDEX = tile_row_g*4 + tile_col_g;

                // 三种模式对当前 tile 的 A/B 源 lane。全部是 elaboration 常量，
                // 运行时只保留三路 4*DATA_W 局部 mux。
                localparam integer FULL_A_SOURCE = tile_row_g*4;
                localparam integer QUAD_A_SOURCE =
                    tile_row_g*4 + (tile_col_g/2)*2;
                localparam integer SELF_A_SOURCE = TILE_INDEX;
                localparam integer FULL_B_SOURCE = tile_col_g;
                localparam integer QUAD_B_SOURCE =
                    (tile_row_g/2)*8 + tile_col_g;
                localparam integer SELF_B_SOURCE = TILE_INDEX;

                localparam integer FULL_CONTROL_SOURCE = 0;
                localparam integer QUAD_CONTROL_SOURCE =
                    (tile_row_g/2)*8 + (tile_col_g/2)*2;
                localparam integer SELF_CONTROL_SOURCE = TILE_INDEX;
                // 紧凑 shape 总线按逻辑 group 连续编号；4x8x8 的 group
                // 顺序依次对应锚点 lane 0/2/8/10，4x4 的 group 与 tile 同号。
                localparam integer QUAD_GROUP_INDEX =
                    (tile_row_g/2)*2 + (tile_col_g/2);

                wire [1:0] local_mode_w = tile_mode_r[TILE_INDEX];
                wire [4*DATA_W-1:0] selected_a_w =
                    (local_mode_w == MODE_16X16) ?
                        a_source_r[FULL_A_SOURCE*4*DATA_W +: 4*DATA_W] :
                    (local_mode_w == MODE_4X8X8) ?
                        a_source_r[QUAD_A_SOURCE*4*DATA_W +: 4*DATA_W] :
                        a_source_r[SELF_A_SOURCE*4*DATA_W +: 4*DATA_W];
                wire [4*DATA_W-1:0] selected_b_w =
                    (local_mode_w == MODE_16X16) ?
                        b_source_r[FULL_B_SOURCE*4*DATA_W +: 4*DATA_W] :
                    (local_mode_w == MODE_4X8X8) ?
                        b_source_r[QUAD_B_SOURCE*4*DATA_W +: 4*DATA_W] :
                        b_source_r[SELF_B_SOURCE*4*DATA_W +: 4*DATA_W];

                wire selected_valid_w =
                    (local_mode_w == MODE_16X16) ?
                        source_valid_r[FULL_CONTROL_SOURCE] :
                    (local_mode_w == MODE_4X8X8) ?
                        source_valid_r[QUAD_CONTROL_SOURCE] :
                        source_valid_r[SELF_CONTROL_SOURCE];
                wire selected_user_w =
                    (local_mode_w == MODE_16X16) ?
                        source_user_r[FULL_CONTROL_SOURCE] :
                    (local_mode_w == MODE_4X8X8) ?
                        source_user_r[QUAD_CONTROL_SOURCE] :
                        source_user_r[SELF_CONTROL_SOURCE];
                wire selected_last_w =
                    (local_mode_w == MODE_16X16) ?
                        source_last_r[FULL_CONTROL_SOURCE] :
                    (local_mode_w == MODE_4X8X8) ?
                        source_last_r[QUAD_CONTROL_SOURCE] :
                        source_last_r[SELF_CONTROL_SOURCE];
                wire [3:0] selected_group_rows_m1_w =
                    (local_mode_w == MODE_16X16) ?
                        active_rows_m1_r[0 +: 4] :
                    (local_mode_w == MODE_4X8X8) ?
                        {1'b0, active_rows_m1_r[QUAD_GROUP_INDEX*3 +: 3]} :
                        {2'b0, active_rows_m1_r[TILE_INDEX*2 +: 2]};
                wire [3:0] selected_group_cols_m1_w =
                    (local_mode_w == MODE_16X16) ?
                        active_cols_m1_r[0 +: 4] :
                    (local_mode_w == MODE_4X8X8) ?
                        {1'b0, active_cols_m1_r[QUAD_GROUP_INDEX*3 +: 3]} :
                        {2'b0, active_cols_m1_r[TILE_INDEX*2 +: 2]};

                // 把逻辑组 count-1 M/N 拆成当前 4x4 tile 的局部 count-1 编码。
                wire [3:0] row_base_w =
                    (local_mode_w == MODE_16X16) ? tile_row_g*4 :
                    (local_mode_w == MODE_4X8X8) ? (tile_row_g%2)*4 :
                    4'd0;
                wire [3:0] col_base_w =
                    (local_mode_w == MODE_16X16) ? tile_col_g*4 :
                    (local_mode_w == MODE_4X8X8) ? (tile_col_g%2)*4 :
                    4'd0;
                wire row_enable_w = selected_group_rows_m1_w >= row_base_w;
                wire col_enable_w = selected_group_cols_m1_w >= col_base_w;
                wire [1:0] local_rows_m1_w =
                    (selected_group_rows_m1_w >= row_base_w + 4'd3) ? 2'd3 :
                    selected_group_rows_m1_w[1:0];
                wire [1:0] local_cols_m1_w =
                    (selected_group_cols_m1_w >= col_base_w + 4'd3) ? 2'd3 :
                    selected_group_cols_m1_w[1:0];

                assign core_valid_w[TILE_INDEX] = selected_valid_w &&
                    row_enable_w && col_enable_w;
                assign core_user_w[TILE_INDEX] = selected_user_w;
                assign core_last_w[TILE_INDEX] = selected_last_w;
                assign core_active_rows_m1_w[TILE_INDEX*2 +: 2] =
                    local_rows_m1_w;
                assign core_active_cols_m1_w[TILE_INDEX*2 +: 2] =
                    local_cols_m1_w;
                assign core_a_rows_w[TILE_INDEX*4*DATA_W +: 4*DATA_W] =
                    selected_a_w;
                assign core_b_cols_w[TILE_INDEX*4*DATA_W +: 4*DATA_W] =
                    selected_b_w;
            end
        end
    endgenerate

    // 固定使用 16x4x4 物理后端。运行时的逻辑组合已经在上面完成，
    // 因此这里每个 4x4 tile 拥有自己的 input/control/shape 通道。
    // 专用模块把 lane→tile 的映射直接展开，便于实现和观察，也避免
    // 在最终使用版本中携带通用分组参数。
    npu_v13_systolic_cluster_16x4x4_stream #(
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_cluster_16lane (
        .clk(clk),
        .resetn(resetn),
        .s_axis_tvalid(core_valid_w),
        .s_axis_tuser(core_user_w),
        .s_axis_tlast(core_last_w),
        .a_rows_i(core_a_rows_w),
        .b_cols_i(core_b_cols_w),
        .active_rows_m1_i(core_active_rows_m1_w),
        .active_cols_m1_i(core_active_cols_m1_w),
        .c_valid_o(c_tile_valid_o),
        .c_active_rows_m1_o(c_active_rows_m1_o),
        .c_active_cols_m1_o(c_active_cols_m1_o),
        .c_matrix_o(c_matrix_o)
    );
endmodule
