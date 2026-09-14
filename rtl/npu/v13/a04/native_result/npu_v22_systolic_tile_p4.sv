// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

// 4x4 output-stationary 计算 tile：保留原计算波前与完成令牌时序，
// 但取消 16 个 INT32 结果的强制同拍汇合，改为 PE 就地捕获、P4 分行输出。
module npu_v22_systolic_tile_p4 #(
    parameter integer DATA_W = 8,
    parameter integer ACC_W = 32,
    parameter integer CAPTURE_SLOTS = 4
) (
    // 阵列时钟。所有数据、控制和结果对齐寄存器都在上升沿更新。
    input  wire                         clk, // 4x4 tile 统一计算时钟，所有输入在上升沿采样。
    // 低有效复位；顶层传播/协议状态异步清零，PE/DSP 同时收到复位。
    input  wire                         resetn, // 低有效复位；tile 有效/协议状态异步清零，PE/DSP 同步复位，数据对齐流水不保证清零。
    // 当前 packet 的有效行/列数量减一编码：00/01/10/11 对应 1/2/3/4。
    // 这些字段只在 packet 首 beat 被采样，随后随 TLAST 的 mask tag 对齐。
    input  wire [1:0]                   active_rows_i, // 本地有效行数减一，2 位编码 0..3 表示 1..4 行；只在 packet 首有效拍采样，不是实际行数。
    input  wire [1:0]                   active_cols_i, // 本地有效列数减一，2 位编码 0..3 表示 1..4 列；只在 packet 首有效拍采样。
    // 固定速率输入接口。没有 tready，故每个 tvalid=1 的上升沿都会被采样；
    // tvalid=0 只向阵列注入空泡，不能冻结已有 packet。
    input  wire                         s_axis_tvalid, // 当前 A/B 向量有效；无 tready，每个高电平周期接收一拍，低电平只注入气泡。
    input  wire [8*DATA_W-1:0]          s_axis_tdata, // 低 4*DATA_W 位为 A[0..3]，高 4*DATA_W 位为 B[0..3]；每个向量低编号元素在低位，各元素按有符号数解释。
    // 有效 beat 的 packet 尾标记；只有 tvalid=1 时才被解释为 TLAST。
    input  wire                         s_axis_tlast, // 当前有效 beat 是 K 归约的最后一拍；仅在 tvalid=1 时生效，K=1 时可与 tuser 同为 1。
    // 有效 beat 的 packet 首标记；tuser=1 的该拍同时启动新 GEMM 初始化。
    // 连续流版不再从内部状态推断包头，协议要求每个 packet 首拍显式置位。
    input  wire                         s_axis_tuser, // 当前有效 beat 是新 packet 首拍；显式初始化累加并采样 shape，不能省略或依赖空泡推断首拍。
    // 保留原有窄完成令牌，供预约记账与 shape 入队；结果载荷由本地 P4 握手输出。
    output wire                         c_valid_o, // 完成令牌无反压；不能将它误当作 P4 数据握手。
    // 与 c_valid_o 同拍的本地有效 shape，仍为 count-1 编码。
    output wire [1:0]                   c_active_rows_m1_o, // 结果有效行数减一，0..3 对应 1..4；与 c_valid_o 同拍。
    output wire [1:0]                   c_active_cols_m1_o, // 结果有效列数减一，0..3 对应 1..4；仅在 c_valid_o=1 时有意义。
    // 每个已预约 tile 固定输出四行，每行四个 INT32；反压时保持载荷与元数据。
    input wire reserve_valid_i,
    output wire reserve_ready_o,
    input wire [47:0] reserve_meta_i,
    output wire row_valid_o,
    input wire row_ready_i,
    output wire [127:0] row_data_o,
    output wire [3:0] row_keep_o,
    output wire [1:0] row_index_o,
    output wire [47:0] row_meta_o,
    output wire row_error_o
);
    // 4x4 阵列中，输入波前从 PE(0,0) 走到 PE(3,3) 共相差 3+3=6 拍。
    localparam integer MAX_WAVE_DELAY = 6;
    // 只保留原完成令牌的公共附加级；宽结果对齐链已经移除。
    localparam integer OUTPUT_PIPE_STAGES = 1;
    // 从输入 TLAST 到窄 c_valid_o/shape 完成令牌可观察共 9 拍。这里的
    // “输出”不是 row_data_o：真正 P4 数据还要经过本地完成登记与弹性输出级。
    // shape 走同样长度的单一无复位移位链，不展开成 16-bit mask。
    localparam integer SHAPE_OUTPUT_DELAY = MAX_WAVE_DELAY + 3;
   
    // 在 packet 首 beat 锁存 4-bit 原始 shape，保证 K>1 时 TLAST 使用包头
    // 时的 M/N 配置。此处不提前展开 16-bit mask，避免宽元数据占用流水资源。
    reg [3:0] packet_shape_r;

    // 边界输入 skew：第 r 行 A 延迟 r 拍，第 c 列 B 延迟 c 拍，使同一 k
    // 的 A[row][k] 与 B[k][col] 在 PE(row,col) 同周期相遇。数组第二维最多
    // 只需保存 3 拍；第 0 行和第 0 列直接进入阵列，不使用这些寄存器。
    reg signed [DATA_W-1:0] a_skew_data_r [0:3][0:2];
    reg signed [DATA_W-1:0] b_skew_data_r [0:3][0:2];

    // valid/init/last 必须与数据波前采用相同的 row+col 延迟传播。
    // 六位覆盖从 PE(0,0) 到 PE(3,3) 的最大控制延迟。
    reg [5:0] valid_delay_r;
    reg [5:0] init_delay_r;
    reg [5:0] last_delay_r;

    // 将当前 packet 的 4-bit shape 绑定到 TLAST 事件并直接延迟到公共结果
    // 时刻。只有 c_valid_o=1 时 sideband 才有意义，所以数据链无需 reset。
    (* shreg_extract = "yes" *) reg [3:0] shape_delay_r
        [0:SHAPE_OUTPUT_DELAY-1];

    // 固定速率契约：没有 TREADY，因此每个 TVALID=1 的时钟沿就是一次输入
    // 传输。TVALID=0 时仍然推进内部流水，只是向 valid 波前中注入一个空泡。

    // 连续流协议直接把 TUSER 定义为包头脉冲，不再依赖 packet_started_r
    // 推断首拍。包头同时作为 init token，命令所有 PE 覆盖旧累加值。
    wire head_fire_w = s_axis_tvalid && s_axis_tuser;
  
    // TLAST 只有在 TVALID=1 时才生效，避免无效周期的边带电平制造伪结果。
    wire beat_last_w = s_axis_tvalid && s_axis_tlast;
    wire [3:0] input_shape_w = {active_rows_i, active_cols_i};
    // K=1 时首拍与尾拍重合，packet_shape_r 尚未在该沿更新，必须直接使用
    // input_shape_w；K>1 时则使用首 beat 保存下来的 packet_shape_r。
    wire [3:0] closing_shape_w =
        head_fire_w ? input_shape_w : packet_shape_r;

    // 拆分输入总线。a_rows_w 的第 r 个 DATA_W 切片送往第 r 行左边界；
    // b_cols_w 的第 c 个切片送往第 c 列上边界。
    wire [4*DATA_W-1:0] a_rows_w = s_axis_tdata[4*DATA_W-1:0];
    wire [4*DATA_W-1:0] b_cols_w = s_axis_tdata[8*DATA_W-1:4*DATA_W];

    // a_link_w 使用 fabric 寄存链向右连接相邻 PE；b_cascade_link_w 使用
    // DSP48E1 的 18-bit BCOUT/BCIN 专用链向下连接相邻 PE。
    wire signed [DATA_W-1:0] a_link_w [0:3][0:3];
    wire signed [17:0] b_cascade_link_w [0:3][0:3];
    // 每个 PE 在自己的 last 波前到达时给出 post-MAC 结果及单拍有效标记。
    wire [15:0] raw_pe_valid;
    wire [511:0] raw_pe_data;
    wire signed [ACC_W-1:0] pe_result_w [0:3][0:3];
    wire pe_result_valid_w [0:3][0:3];
    // 结果载荷不再对齐：16 个 PE 按 row+col 自然波前错峰写入各自本地 bank。
    // 这里只保留原来的窄整-tile完成令牌，作为“该预约槽16个元素均已写完”的栅栏。
    reg matrix_result_valid_r;

    assign c_valid_o = matrix_result_valid_r;
    assign c_active_rows_m1_o =
        shape_delay_r[SHAPE_OUTPUT_DELAY-1][3:2];
    assign c_active_cols_m1_o =
        shape_delay_r[SHAPE_OUTPUT_DELAY-1][1:0];

    // PE(3,3) 位于最远波前点，其 result_valid 可作为整 tile 数据全部落槽的基准。
    // 再寄存 1 拍是为了保持原实现的 c_valid_o/shape 周期契约；它只延迟窄
    // 控制令牌，不再伴随任何 512-bit 结果对齐链。
    always @(posedge clk) begin
        if (!resetn)
            matrix_result_valid_r <= 1'b0;
        else
            matrix_result_valid_r <= pe_result_valid_w[3][3];
    end

    // 输入 skew、控制波前和 shape tag 均为无停顿流水。只有可观察的控制
    // token 接入 reset；A/B skew 数据由 valid 保护，不需要复位。
    integer row_i;
    integer col_i;
    integer delay_i;
    // 对 A/B 边界只做空间传播，不参与协议可观察状态，因此不复位数据链。
    always @(posedge clk) begin
        // 对 A 的第 1/2/3 行分别施加 1/2/3 拍边界延迟。
        for (row_i = 1; row_i < 4; row_i = row_i + 1) begin
            a_skew_data_r[row_i][0] <= a_rows_w[row_i*DATA_W +: DATA_W];
            for (delay_i = 1; delay_i < row_i; delay_i = delay_i + 1)
                a_skew_data_r[row_i][delay_i] <= a_skew_data_r[row_i][delay_i-1];
        end
        // 对 B 的第 1/2/3 列分别施加 1/2/3 拍边界延迟。
        for (col_i = 1; col_i < 4; col_i = col_i + 1) begin
            b_skew_data_r[col_i][0] <= b_cols_w[col_i*DATA_W +: DATA_W];
            for (delay_i = 1; delay_i < col_i; delay_i = delay_i + 1)
                b_skew_data_r[col_i][delay_i] <= b_skew_data_r[col_i][delay_i-1];
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            valid_delay_r <= 0;
            init_delay_r <= 0;
            last_delay_r <= 0;
        end else begin
            // 控制信号每拍右移；bit[d-1] 对应延迟 d 拍后的波前。
            valid_delay_r <= {valid_delay_r[4:0], s_axis_tvalid};
            init_delay_r <= {init_delay_r[4:0], head_fire_w};
            last_delay_r <= {last_delay_r[4:0], beat_last_w};

        end
    end

    // shape 数据每拍无条件推进。无复位是有意的时序/资源优化；只有
    // c_valid_o=1 时输出 shape 才可观察。连续 TLAST 可逐拍产生不同的窄完成
    // 令牌；这表示计算核完成 II 可为 1，不表示单个 P4 口能一拍排出整矩阵。
    integer shape_delay_i;
    always @(posedge clk) begin
        shape_delay_r[0] <= closing_shape_w;
        for (shape_delay_i = 1; shape_delay_i < SHAPE_OUTPUT_DELAY;
             shape_delay_i = shape_delay_i + 1)
            shape_delay_r[shape_delay_i] <= shape_delay_r[shape_delay_i-1];
    end

    // 在显式 TUSER 包头拍保存跨 beat 的 shape 元数据。K=1 时 TUSER/TLAST
    // 同拍，closing_shape_w 直接选择 input_shape_w，不受非阻塞赋值延迟影响。
    always @(posedge clk) begin
        if (head_fire_w)
            packet_shape_r <= input_shape_w;
    end

    // -------------------------------------------------------------------------
    // 4x4 PE mesh
    // -------------------------------------------------------------------------
    // 每个 generate 实例负责一个 PE 的：
    //   1. A/B 边界输入或相邻 PE 链路选择；
    //   2. valid/init/last 的 row+col 拍波前对齐；
    //   3. 本地乘累加；
    //   4. TLAST 后将本 PE 的 INT32 结果按自身有效事件写入本地预约槽。
    genvar row_g;
    genvar col_g;
    generate
        for (row_g = 0; row_g < 4; row_g = row_g + 1) begin : g_rows
            for (col_g = 0; col_g < 4; col_g = col_g + 1) begin : g_cols
                localparam integer PE_INDEX = row_g*4 + col_g;
                // 数据和控制到达该 PE 的时间相对 PE(0,0) 晚 row+col 拍。
                localparam integer WAVE_DELAY = row_g + col_g;
                wire signed [DATA_W-1:0] pe_a_w;
                wire signed [DATA_W-1:0] pe_b_w;
                wire signed [17:0] pe_b_cascade_w;
                wire pe_valid_w;
                wire pe_init_w;
                wire pe_last_w;

                // A 从左向右传播。只有最左列使用模块边界输入；其中 row 0
                // 无需 skew，其余行从各自 row 拍延迟链的末端取数。
                if (col_g == 0) begin : g_a_boundary
                    if (row_g == 0) begin : g_a_direct
                        assign pe_a_w = a_rows_w[row_g*DATA_W +: DATA_W];
                    end else begin : g_a_skewed
                        assign pe_a_w = a_skew_data_r[row_g][row_g-1];
                    end
                end else begin : g_a_forwarded
                    assign pe_a_w = a_link_w[row_g][col_g-1];
                end
                // B 从上向下传播。只有最上行使用模块边界输入；其中 col 0
                // 无需 skew，其余列从各自 col 拍延迟链的末端取数。
                if (row_g == 0) begin : g_b_boundary
                    assign pe_b_cascade_w = 18'b0;
                    if (col_g == 0) begin : g_b_direct
                        assign pe_b_w = b_cols_w[col_g*DATA_W +: DATA_W];
                    end else begin : g_b_skewed
                        assign pe_b_w = b_skew_data_r[col_g][col_g-1];
                    end
                end else begin : g_b_cascaded
                    // BREG=1/BCASCREG=1 使 BCOUT 每经过一个 DSP 恰好延迟一拍，
                    // 与原 fabric b_pipe_r 的波前周期完全一致。
                    assign pe_b_w = {DATA_W{1'b0}};
                    assign pe_b_cascade_w =
                        b_cascade_link_w[row_g-1][col_g];
                end
                // PE(0,0) 直接使用当前接口控制；其余 PE 从公共控制延迟链
                // 选择 WAVE_DELAY 对应 tap，确保控制与经过 skew/mesh 的数据同拍。
                if (WAVE_DELAY == 0) begin : g_control_direct
                    assign pe_valid_w = s_axis_tvalid;
                    assign pe_init_w = head_fire_w;
                    assign pe_last_w = beat_last_w;
                end else begin : g_control_delayed
                    assign pe_valid_w = valid_delay_r[WAVE_DELAY-1];
                    assign pe_init_w = init_delay_r[WAVE_DELAY-1];
                    assign pe_last_w = last_delay_r[WAVE_DELAY-1];
                end

                // PE 内部以 output-stationary 方式保存当前 packet 的累加值：
                // init_i 覆盖旧累加器，valid_i 执行一次 MAC，last_i 同拍导出
                // 包含当前乘积的 post-MAC 结果。a_o/b_o 每拍继续把操作数传播。
                npu_v13_systolic_pe_stream #(
                    .DATA_W(DATA_W), .ACC_W(ACC_W),
                    .USE_B_CASCADE(row_g != 0)
                ) u_pe (
                    .clk(clk),
                    .resetn(resetn),
                    .valid_i(pe_valid_w),
                    .init_i(pe_init_w), .last_i(pe_last_w),
                    .a_i(pe_a_w), .b_i(pe_b_w),
                    .b_cascade_i(pe_b_cascade_w),
                    .b_cascade_o(b_cascade_link_w[row_g][col_g]),
                    .a_o(a_link_w[row_g][col_g]),
                    .acc_o(), .result_valid_o(pe_result_valid_w[row_g][col_g]),
                    .result_o(pe_result_w[row_g][col_g])
                );

                // PE 结果产生后直接写本 PE 的预约槽，不再为凑齐全矩阵而延迟载荷。
                assign raw_pe_valid[PE_INDEX]=pe_result_valid_w[row_g][col_g];
                assign raw_pe_data[PE_INDEX*32+:32]=pe_result_w[row_g][col_g];
            end
        end
    endgenerate
    // 保守完成栅栏：等待保持周期不变的 c_valid_o/shape 后才允许读取四行。
    // PE 结果虽然更早已分别落入本地 bank，但这里不做 early-row release，
    // 从而不引入“某行是否已完整”的额外跨 PE 控制网络。
    npu_v23_native_collector #(.P(4),.FAST_CAPTURE(1),.SLOTS(CAPTURE_SLOTS),.ADDR_W(2),.TAG_W(48)) u_native_store(
        .clk(clk),.resetn(resetn),.reserve_valid_i(reserve_valid_i),.reserve_ready_o(reserve_ready_o),
        .reserve_base_i(2'b0),.reserve_tag_i(reserve_meta_i),.pe_valid_i(raw_pe_valid),
        .result_valid_i(c_valid_o),.result_data_i(raw_pe_data),
        .result_shape_i({c_active_rows_m1_o,c_active_cols_m1_o}),
        .wr_valid_o(row_valid_o),.wr_ready_i(row_ready_i),.wr_addr_o(row_index_o),
        .wr_data_o(row_data_o),.wr_keep_o(row_keep_o),.wr_tag_o(row_meta_o),
        .retire_o(),.used_o(),.protocol_error_o(row_error_o));
    initial if(ACC_W!=32)$fatal(1,"p22 native P4 requires preserved INT32 precision");
endmodule
