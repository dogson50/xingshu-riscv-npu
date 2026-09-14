// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_gemm_tile_scheduler
//
// 一、模块职责
// -----------
// 接收一条动态 GEMM 命令 C[M,N] = A[M,K] * B[K,N]，只枚举输出矩阵 C 的
// M/N 空间，并将其转换为一串紧凑的 tile batch 描述符。每个 tile batch
// 表示“下一次可以并行交给计算集群处理的若干输出块”，而不是送入脉动阵列的
// 一拍 A/B 数据。
//
// 本模块只回答以下问题：
//   1. 当前 tile batch 从 C 的哪个 (m_base,n_base) 开始；
//   2. 当前采用哪种计算模式和 group 排列方式；
//   3. 何时到达一条 GEMM 命令的第一个/最后一个 tile batch。
//
// 本模块明确不负责：
//   * 把 tile batch 展开成 16 个物理 lane 的坐标和 active shape；
//   * 根据矩阵基地址、stride 产生 A/B/C 存储地址；
//   * 从 SRAM/DDR 读取 A/B 数据；
//   * 为 runtime cluster 产生每个 packet 的 K 拍 tuser/tlast；
//   * 等待计算结果或把物理 tile 结果写回逻辑 C 坐标。
//
// 因此 tile_batch_ready_i 应来自后续描述符 FIFO/expander/feeder，不能直接连接
// 到当前没有 tready 的 runtime cluster。完整联动仍需要 feeder 和 result collector。
//
// 二、mode 和 layout
// ------------------
// 一个 group 对应 runtime cluster 中一个独立的逻辑矩阵计算组。layout 描述一拍
// tile batch 内多个 group 在逻辑 C 空间中的排列；它不是 cluster 的配置端口。
//
//   mode       group 大小  layout: group 行数 x group 列数   M/N 步长
//   2'b00      16x16       0: 1x1                         16 x 16
//   2'b01       8x8        0: 1x4, 1: 2x2, 2: 4x1        8x32/16x16/32x8
//   2'b10       4x4        0: 1x16, 1: 2x8, 2: 4x4,      4x64/8x32/16x16/
//                            3: 8x2, 4: 16x1              32x8/64x4
//
// 例如 mode=2'b10、layout=0 时，一个 tile batch 在逻辑上覆盖 4 行 x 64 列，最多
// 包含 16 个并行的 4x4 group。后续 expander 再将这些逻辑 group 映射到物理
// lane 0..15；result collector 负责将物理输出还原到相应逻辑坐标。
//
// 三、握手和完成语义
// ------------------
// 命令在 cmd_valid_i && cmd_ready_o 时被接收。
// tile batch 在 tile_batch_valid_o && tile_batch_ready_i 时被下游接收。反压期间
// 所有 tile_batch_* 输出保持不变。tile_batch_ready_i 恒为 1 时，描述符输出
// II=1；上一条命令的最后一个 tile batch 被接收时，可以同拍接收下一条命令。
//
// tile_batch_cmd_first_o/tile_batch_cmd_last_o 表示整条 GEMM 的首/尾 tile batch，
// 不能直接作为 cluster 的 tuser/tlast。cluster 的 tuser/tlast 应由 feeder 对每个
// tile batch 重新产生：第 0 个 K beat 拉高 tuser，第 K-1 个 beat 拉高 tlast。
//
// schedule_done_o 只表示“最后一个 tile batch 描述符已被下游接收”，不是
// “计算结果已返回”；scheduler_busy_o 也不代表计算集群仍在运行。
//////////////////////////////////////////////////////////////////////////////////

module npu_v13_gemm_tile_scheduler #(
    parameter integer DIM_W = 16,
    parameter integer TAG_W = 8
) (
    // 时钟与低有效异步复位。为了缩小 reset 网络，复位只覆盖可见控制状态；
    // tile_batch_valid_o=0 时描述符无效，因此描述符寄存器不要求复位。
    input  wire                         clk, // 描述符调度时钟；命令和 batch 的 ready/valid 事务在上升沿握手。
    input  wire                         resetn, // 低有效异步清除 valid/error/done 状态；描述符数据寄存器不清零，复位期间不得提交命令。

    // GEMM 命令 ready/valid 接口。
    // 发送方必须在 cmd_valid_i=1 且 cmd_ready_o=0 时保持所有 cmd_* 字段稳定。
    input  wire                         cmd_valid_i, // 整条 GEMM 几何命令有效；cmd_ready_o=0 时保持 valid 和所有 cmd_* 字段。
    output wire                         cmd_ready_o, // 无待发 batch，或旧命令最后一个 batch 本拍已被接收时可接新命令；未用 resetn 门控。
    // A 为 MxK，B 为 KxN，C 为 MxN；三个维度都必须非零。
    input  wire [DIM_W-1:0]             cmd_m_i, // 完整输出矩阵行数 M，即 A 的行数；实际数量、非 count-1，要求非零。
    input  wire [DIM_W-1:0]             cmd_n_i, // 完整输出矩阵列数 N，即 B 的列数；实际数量，要求非零。
    input  wire [DIM_W-1:0]             cmd_k_i, // A 列数/B 行数 K；动态非零实际归约长度，本模块转发而不枚举每拍 K 数据。
    // 计算集群模式：00=1x16x16，01=4x8x8，10=16x4x4，11 非法。
    input  wire [1:0]                   cmd_mode_i, // 集群分组模式：00=1组16x16，01=4组8x8，10=16组4x4，11 非法。
    // mode 内部的逻辑 group 排列，合法范围分别为 0、0..2、0..4。
    input  wire [2:0]                   cmd_layout_i, // group 行x列布局：00 模式仅0；01 的0/1/2为1x4/2x2/4x1；10 的0..4为1x16/2x8/4x4/8x2/16x1。
    // 软件/上层分配的命令标识；本模块不解释其数值。
    input  wire [TAG_W-1:0]             cmd_tag_i, // 命令关联标识，原样传入各 batch 和 schedule_done；不参与几何计算。
    // 非法命令被握手接收后拉高一拍；非法命令不会产生 tile batch。
    output reg                          cmd_error_o, // 非法命令握手接收后输出一拍错误；该命令不产生 batch，不等同于下游运算错误。

    // 紧凑 tile batch 描述符 ready/valid 接口。
    // tile_batch_ready_i 只表示下游能否接收描述符，不是 cluster 的数据 ready。
    output reg                          tile_batch_valid_o, // 当前紧凑 batch 描述符有效；ready=0 时保持全部 batch 字段，握手后推进坐标。
    input  wire                         tile_batch_ready_i, // 下游可接收本批次描述符；允许反压，但不是 cluster 的逐拍数据接收许可。
    // 原始 GEMM 维度。每个 tile batch 重复携带，便于下游计算尾块和地址。
    output reg  [DIM_W-1:0]             tile_batch_m_o, // 原命令完整 M，每个 batch 重复携带；供后端推导有效尾块，不是本 batch 的局部行数。
    output reg  [DIM_W-1:0]             tile_batch_n_o, // 原命令完整 N，每个 batch 重复携带；不是某物理 tile 的本地列数。
    output reg  [DIM_W-1:0]             tile_batch_k_o, // 原命令完整 K；后端据此为各有效 group 产生 K 个有效 beat。
    // 当前 tile batch 在逻辑输出矩阵 C 中的左上角坐标，均从 0 开始。
    output reg  [DIM_W-1:0]             tile_batch_m_base_o, // 本批次在逻辑 C 矩阵中的零起始行坐标；是元素坐标而非存储器地址。
    output reg  [DIM_W-1:0]             tile_batch_n_base_o, // 本批次在逻辑 C 矩阵中的零起始列坐标；N 方向优先推进，行末再推进 M。
    // cluster_mode 对应计算集群模式；layout 是 batch 内逻辑 group 排列。
    output reg  [1:0]                   tile_batch_cluster_mode_o, // 本 batch 的逻辑计算分组模式；下游据此展开物理 lane，但不能直接当作 cfg_valid。
    output reg  [2:0]                   tile_batch_layout_o, // 本 batch 内逻辑 group 排列编码；含义同 cmd_layout_i，决定各 group 在 C 中的坐标。
    // 整条 GEMM 命令的首/尾 batch 标志，不是 K packet 的 tuser/tlast。
    output reg                          tile_batch_cmd_first_o, // 整条命令的首个 batch 标志；仅在 batch_valid 时解释，不是送进 PE 的首 K 拍标记。
    output reg                          tile_batch_cmd_last_o, // 整条命令的最后一个 batch 标志；该描述符握手后调度结束，但矩阵结果可能仍在计算。
    // 与输入命令 tag 一致，供下游 metadata FIFO/collector 关联结果。
    output reg  [TAG_W-1:0]             tile_batch_tag_o, // 当前描述符所属的原命令 tag；下游应随批次 metadata 保存，用于结果/完成关联。

    // scheduler_busy_o：scheduler 内有尚未被接收的有效 tile batch。
    // schedule_done_o：最后一个描述符完成握手时产生的一拍脉冲。
    // schedule_done_tag_o：对应命令 tag；不表示计算结果已经完成。
    output wire                         scheduler_busy_o, // 存在尚未被接收的有效 batch，即 tile_batch_valid_o；不反映阵列是否仍在运行。
    output reg                          schedule_done_o, // 最后一个 batch 握手后寄存输出一拍脉冲；仅表示描述符交接完成，不能据此释放输入/输出 bank。
    output reg  [TAG_W-1:0]             schedule_done_tag_o // 与 schedule_done_o 同拍的已调度完命令 tag；即使同拍接收新命令也对应旧命令。
);
    // mode 编码必须与 npu_v13_systolic_cluster_runtime_stream 保持一致。
    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;

    // 当前 tile batch 的握手事件，以及整条命令最后一个 batch 的握手事件。
    wire tile_batch_fire_w = tile_batch_valid_o && tile_batch_ready_i;
    wire last_tile_batch_fire_w =
        tile_batch_fire_w && tile_batch_cmd_last_o;

    // 空闲时可接收命令；最后一个 tile batch 被接收时也可同拍装载下一条命令，
    // 从而让相邻 single-batch 命令在描述符接口上没有额外空拍。
    assign cmd_ready_o = !tile_batch_valid_o || last_tile_batch_fire_w;
    wire cmd_fire_w = cmd_valid_i && cmd_ready_o;
    assign scheduler_busy_o = tile_batch_valid_o;

    // 组合检查命令合法性。这里只检查维度和 mode-local layout；地址范围、
    // 存储容量以及量化格式应由更上层的命令处理模块检查。
    function automatic command_valid_f;
        input [DIM_W-1:0] m_dim;
        input [DIM_W-1:0] n_dim;
        input [DIM_W-1:0] k_dim;
        input [1:0] mode;
        input [2:0] layout;
        begin
            command_valid_f = 1'b0;
            if ((m_dim != {DIM_W{1'b0}}) &&
                (n_dim != {DIM_W{1'b0}}) &&
                (k_dim != {DIM_W{1'b0}})) begin
                case (mode)
                    MODE_16X16:  command_valid_f = (layout == 3'd0);
                    MODE_4X8X8:  command_valid_f = (layout <= 3'd2);
                    MODE_16X4X4: command_valid_f = (layout <= 3'd4);
                    default:     command_valid_f = 1'b0;
                endcase
            end
        end
    endfunction

    // 当前输入命令每完成一个 tile batch 后，逻辑 C 基址在 M/N 方向推进的距离。
    // 所有步长都是 2 的幂，最大为 64，因此 7 bit 足够。
    reg [6:0] cmd_step_m_w;
    reg [6:0] cmd_step_n_w;

    always @* begin
        cmd_step_m_w = 7'd16;
        cmd_step_n_w = 7'd16;
        case (cmd_mode_i)
            MODE_16X16: begin
                cmd_step_m_w = 7'd16;
                cmd_step_n_w = 7'd16;
            end
            MODE_4X8X8: begin
                case (cmd_layout_i)
                    3'd0: begin cmd_step_m_w = 7'd8;  cmd_step_n_w = 7'd32; end
                    3'd1: begin cmd_step_m_w = 7'd16; cmd_step_n_w = 7'd16; end
                    default: begin cmd_step_m_w = 7'd32; cmd_step_n_w = 7'd8; end
                endcase
            end
            default: begin
                case (cmd_layout_i)
                    3'd0: begin cmd_step_m_w = 7'd4;  cmd_step_n_w = 7'd64; end
                    3'd1: begin cmd_step_m_w = 7'd8;  cmd_step_n_w = 7'd32; end
                    3'd2: begin cmd_step_m_w = 7'd16; cmd_step_n_w = 7'd16; end
                    3'd3: begin cmd_step_m_w = 7'd32; cmd_step_n_w = 7'd8; end
                    default: begin cmd_step_m_w = 7'd64; cmd_step_n_w = 7'd4; end
                endcase
            end
        endcase

    end

    // 计算“当前位置之后还剩多少个 tile batch”：floor((dimension-1)/step)。
    // 合法 step 全是 2 的幂，所以这里只需要固定右移，不会综合出除法器。
    // 例如 dimension=37、step=16，返回 2，表示 base=0 之后还剩 base=16/32。
    function automatic [DIM_W-1:0] waves_after_f;
        input [DIM_W-1:0] dimension;
        input [6:0] step;
        reg [DIM_W-1:0] dimension_m1;
        begin
            dimension_m1 = dimension - {{(DIM_W-1){1'b0}}, 1'b1};
            case (step)
                7'd4:    waves_after_f = dimension_m1 >> 2;
                7'd8:    waves_after_f = dimension_m1 >> 3;
                7'd16:   waves_after_f = dimension_m1 >> 4;
                7'd32:   waves_after_f = dimension_m1 >> 5;
                default: waves_after_f = dimension_m1 >> 6;
            endcase
        end
    endfunction

    wire [DIM_W-1:0] cmd_m_after_w =
        waves_after_f(cmd_m_i, cmd_step_m_w);
    wire [DIM_W-1:0] cmd_n_after_w =
        waves_after_f(cmd_n_i, cmd_step_n_w);
    wire cmd_m_last_w = (cmd_m_after_w == {DIM_W{1'b0}});
    wire cmd_n_last_w = (cmd_n_after_w == {DIM_W{1'b0}});
    wire cmd_last_w = cmd_m_last_w && cmd_n_last_w;

    // 接收命令时锁存步长，避免运行期间 mode/layout 解码进入基址加法关键路径。
    reg [6:0] tile_batch_step_m_r;
    reg [6:0] tile_batch_step_n_r;

    // M/N 方向在当前坐标之后剩余的 tile batch 数。N 是内层循环，因此每次换到
    // 下一行 M 时，需要用 tile_batch_n_after_reload_r 恢复 N 的初始剩余数量。
    reg [DIM_W-1:0] tile_batch_m_after_r;
    reg [DIM_W-1:0] tile_batch_n_after_r;
    reg [DIM_W-1:0] tile_batch_n_after_reload_r;

    // 当前 tile batch 是否位于 M/N 方向的最后一个位置。显式寄存终点标志可避免
    // “基址加法 -> 越界比较 -> 换行选择 -> 再次加法 -> 最终比较”的长组合链。
    reg tile_batch_m_last_r;
    reg tile_batch_n_last_r;

    wire next_m_last_w = tile_batch_n_last_r ?
        (tile_batch_m_after_r == {{(DIM_W-1){1'b0}}, 1'b1}) :
        tile_batch_m_last_r;
    wire next_n_last_w = tile_batch_n_last_r ?
        (tile_batch_n_after_reload_r == {DIM_W{1'b0}}) :
        (tile_batch_n_after_r == {{(DIM_W-1){1'b0}}, 1'b1});
    wire next_tile_batch_last_w = next_m_last_w && next_n_last_w;

    // 控制寄存器必须复位，保证复位后接口无伪 valid/error/done。
    // 描述符数据在 tile_batch_valid_o=0 时没有协议意义，放在下面的无 reset always
    // 中，可减少宽 reset 网络、复位 mux 和扇出。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            tile_batch_valid_o <= 1'b0;
            cmd_error_o <= 1'b0;
            schedule_done_o <= 1'b0;
        end else begin
            cmd_error_o <= 1'b0;
            schedule_done_o <= 1'b0;

            if (last_tile_batch_fire_w)
                schedule_done_o <= 1'b1;

            if (cmd_fire_w) begin
                if (command_valid_f(cmd_m_i, cmd_n_i, cmd_k_i,
                                    cmd_mode_i, cmd_layout_i)) begin
                    tile_batch_valid_o <= 1'b1;
                end else begin
                    tile_batch_valid_o <= 1'b0;
                    cmd_error_o <= 1'b1;
                end
            end else if (last_tile_batch_fire_w) begin
                tile_batch_valid_o <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        // schedule_done_tag_o 必须在旧命令最后一个 batch 被接收时取旧 tag。
        // 即使同拍接收新命令，非阻塞赋值也保证这里保存的是旧 tag。
        if (last_tile_batch_fire_w)
            schedule_done_tag_o <= tile_batch_tag_o;

        // 新合法命令从 (0,0) 开始，锁存整条命令共享的维度、mode、layout 和 tag。
        if (cmd_fire_w &&
            command_valid_f(cmd_m_i, cmd_n_i, cmd_k_i,
                            cmd_mode_i, cmd_layout_i)) begin
            tile_batch_m_o <= cmd_m_i;
            tile_batch_n_o <= cmd_n_i;
            tile_batch_k_o <= cmd_k_i;
            tile_batch_m_base_o <= {DIM_W{1'b0}};
            tile_batch_n_base_o <= {DIM_W{1'b0}};
            tile_batch_cluster_mode_o <= cmd_mode_i;
            tile_batch_layout_o <= cmd_layout_i;
            tile_batch_cmd_first_o <= 1'b1;
            tile_batch_cmd_last_o <= cmd_last_w;
            tile_batch_tag_o <= cmd_tag_i;
            tile_batch_step_m_r <= cmd_step_m_w;
            tile_batch_step_n_r <= cmd_step_n_w;
            tile_batch_m_after_r <= cmd_m_after_w;
            tile_batch_n_after_r <= cmd_n_after_w;
            tile_batch_n_after_reload_r <= cmd_n_after_w;
            tile_batch_m_last_r <= cmd_m_last_w;
            tile_batch_n_last_r <= cmd_n_last_w;
        end else if (tile_batch_fire_w && !tile_batch_cmd_last_o) begin
            // N 为内层循环。到达当前 N 行末时，N 基址回到 0，M 推进一行；
            // 否则只推进 N。所有状态只在 tile batch 真正被下游接收时更新，因此
            // tile_batch_ready_i=0 期间整个描述符自然保持稳定。
            if (tile_batch_n_last_r) begin
                tile_batch_m_base_o <=
                    tile_batch_m_base_o + tile_batch_step_m_r;
                tile_batch_n_base_o <= {DIM_W{1'b0}};
                tile_batch_m_after_r <= tile_batch_m_after_r -
                                  {{(DIM_W-1){1'b0}}, 1'b1};
                tile_batch_n_after_r <= tile_batch_n_after_reload_r;
            end else begin
                tile_batch_n_base_o <=
                    tile_batch_n_base_o + tile_batch_step_n_r;
                tile_batch_n_after_r <= tile_batch_n_after_r -
                                  {{(DIM_W-1){1'b0}}, 1'b1};
            end
            tile_batch_cmd_first_o <= 1'b0;
            tile_batch_cmd_last_o <= next_tile_batch_last_w;
            tile_batch_m_last_r <= next_m_last_w;
            tile_batch_n_last_r <= next_n_last_w;
        end
    end
endmodule
