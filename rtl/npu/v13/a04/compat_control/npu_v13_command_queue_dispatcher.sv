// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_command_queue_dispatcher
//
// 一、模块职责
// -----------
// 本模块是命令队列子系统的统一外壳，内部实例化：
//   1. npu_v13_command_fifo：保存完整且有序的 GEMM/CONV 命令；
//   2. npu_v13_cluster_mode_ctrl：在命令真正执行前安全切换 cluster mode；
//   3. 一个很小的 dispatcher FSM：管理 head、mode、dispatch、done 生命周期。
//
// 二、为什么必须等待 exec_done
// --------------------------
// exec_cmd ready/valid 只表示下游已经接管命令，不表示最后一拍 A/B 已进入 cluster，
// 更不表示 C 结果已被 collector 写回。因此命令 dispatch 后进入 RUNNING；只有收到
// exec_done 才允许下一条命令申请不同 cluster mode。exec_done 必须来自完整执行器
// 或 result collector，不能直接使用 tile scheduler 的 schedule_done。
//
// 三、命令字段
// -----------
// opcode：00=GEMM，01=CONV，10/11 保留并在本地拒绝。这里仅负责传输 opcode；
// 真正的 CONV window/地址语义由未来独立 conv frontend 解释。
// M/K/N 是统一的 GEMM 等效维度；cluster_mode/layout 与现有 tile scheduler 一致。
// A/B/C base、buffer bank 和 op_cfg 被原样保存/转发。本模块不计算地址，也不拥有
// 双缓冲状态；job_executor 的 exec_cmd_ready 只表示能锁存完整命令。
// 命令接管后，由 executor 等待 buffer manager 原子授予 bank，才启动 scheduler/后端。
// op_cfg 可保存紧凑算子参数，或作为扩展 CONV 描述符索引。
//
// 四、吞吐
// -------
// * 命令入口与执行完全解耦，cluster 忙时仍可继续填充 FIFO；
// * 已经处于目标 cluster mode 时，head 直接走 same-mode fast path，不产生 cfg；
// * 当前命令 exec_done 与下一条同模式命令的 dispatch 最少只隔一个周期；
// * 不同 mode 仍必须等待 runtime cluster 自己的 cfg_ready/排空条件；
// * 本模块不进入 A/B/C 每拍数据通路，不影响计算阵列的 II=1。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_command_queue_dispatcher #(
    parameter integer DIM_W      = 16,
    parameter integer ADDR_W     = 32,
    parameter integer BANK_W     = 1,
    parameter integer OP_CFG_W   = 32,
    parameter integer TAG_W      = 8,
    parameter integer FIFO_DEPTH = 512
) (
    input  wire                             clk, // 单时钟域；各 ready/valid 接口在上升沿握手。
    input  wire                             resetn, // 低有效协调复位；输入须已同步且覆盖上升沿；FIFO/pop同步清零，其他有效状态保留异步清零。

    // 完整命令入队接口。所有字段在 cmd_valid_i=1、cmd_ready_o=0 时必须稳定。
    // 接收命令仅表示已入队，不表示开始执行。复位取消未完成事务，不补发响应；
    // 本复位不单独终止外部执行器/阵列，系统必须协调相关模块复位。
    input  wire                             cmd_valid_i, // 上游声明当前整条命令有效。
    output wire                             cmd_ready_o, // FIFO 可接收；与 valid 同为 1 时整条命令入队。
    // 00=GEMM，01=CONV；这里只传输类别，不在本模块内执行算子展开。
    input  wire [1:0]                       cmd_opcode_i, // 算子类别：00=GEMM，01=CONV；10/11 本地拒绝，支持类别原样转发而不在此展开运算。
    // GEMM 为 A[M,K] * B[K,N] = C[M,N]；CONV 传入等效 GEMM 维度。
    // M/N/K 为实际数量，不是 count-1 编码；零维度等执行合法性由执行器检查并报错。
    input  wire [DIM_W-1:0]                 cmd_m_i, // 输出矩阵行数 M。
    input  wire [DIM_W-1:0]                 cmd_n_i, // 输出矩阵列数 N。
    input  wire [DIM_W-1:0]                 cmd_k_i, // 乘加归约长度 K；不是固定硬件参数。
    input  wire [1:0]                       cmd_cluster_mode_i, // 00=1组16x16，01=4组8x8，10=16组4x4；11非法。
    input  wire [2:0]                       cmd_layout_i, // 布局编码，原样送执行器；本模块不做布局变换。
    // base 是地址描述字段，不是矩阵数据；字节/元素等地址单位由上游与执行器约定。
    input  wire [ADDR_W-1:0]                cmd_a_base_i, // A 的起始地址。
    input  wire [ADDR_W-1:0]                cmd_b_base_i, // B 的起始地址。
    input  wire [ADDR_W-1:0]                cmd_c_base_i, // C 的目标写回地址。
    // bank 为缓冲区编号，不是就绪标志；本模块只保存编号，不切换双缓冲状态。
    input  wire [BANK_W-1:0]                cmd_a_bank_i, // 本命令读取 A 所选的 bank。
    input  wire [BANK_W-1:0]                cmd_b_bank_i, // 本命令读取 B 所选的 bank。
    input  wire [BANK_W-1:0]                cmd_c_bank_i, // 本命令写入 C 所选的 bank。
    input  wire [OP_CFG_W-1:0]              cmd_op_cfg_i, // 算子扩展配置/描述符索引，内容由执行器解释。
    input  wire [TAG_W-1:0]                 cmd_tag_i, // 命令标识，贯穿下发、完成和退休响应。

    // 命令退休响应。每个被入口接收的命令最终严格产生一次 response。
    // 前提是事务未被复位取消、执行器最终返回 done；非法命令可直接返回失败而不执行。
    // valid=1、ready=0 时保持 tag/status；响应只携带完成状态，不携带 C 矩阵数据。
    output wire                             cmd_rsp_valid_o, // 存在一条待上游接收的命令响应。
    input  wire                             cmd_rsp_ready_i, // 上游可接收响应；握手后释放响应槽。
    output wire [TAG_W-1:0]                 cmd_rsp_tag_o, // 对应原始 cmd_tag_i，用于上游匹配命令。
    // 000=成功；001=非法 opcode；010=非法 cluster mode；
    // 011=cluster mode 配置/确认失败；100=执行器报错；101=done tag 不匹配。
    output wire [2:0]                       cmd_rsp_status_o, // 退休状态码：000成功/001非法算子/010非法模式/011模式配置失败/100执行错误/101完成tag不匹配；仅 rsp_valid 时有效。

    // 完整命令执行接口。exec_cmd_ready_i 应由真正接管全部字段的执行器产生；
    // 它也可以综合所选 A/B bank ready、输出资源和内部命令槽状态。
    // 这是命令描述符接口，不是 cluster 的 A/B 数据流接口。模式就绪后才允许下发；
    // valid=1、ready=0 时保持全部字段。握手即转移所有权，执行器须接管所需字段，
    // 不能在握手后继续依赖这些输出保持；本模块最多等待一条已下发命令的 done。
    output wire                             exec_cmd_valid_o, // 队首命令可下发；不等于计算已经完成。
    input  wire                             exec_cmd_ready_i, // 执行器能接管整条命令；与 valid 共同形成下发握手。
    output wire [1:0]                       exec_cmd_opcode_o, // 原命令的 GEMM/CONV 类别。
    output wire [DIM_W-1:0]                 exec_cmd_m_o, // 原命令的 M，交给执行器分块/寻址。
    output wire [DIM_W-1:0]                 exec_cmd_n_o, // 原命令的 N。
    output wire [DIM_W-1:0]                 exec_cmd_k_o, // 原命令的 K。
    output wire [1:0]                       exec_cmd_cluster_mode_o, // 本次执行所用阵列模式；下发时已确认就绪。
    output wire [2:0]                       exec_cmd_layout_o, // 原命令的布局编码。
    output wire [ADDR_W-1:0]                exec_cmd_a_base_o, // 原命令的 A 起始地址。
    output wire [ADDR_W-1:0]                exec_cmd_b_base_o, // 原命令的 B 起始地址。
    output wire [ADDR_W-1:0]                exec_cmd_c_base_o, // 原命令的 C 写回地址。
    output wire [BANK_W-1:0]                exec_cmd_a_bank_o, // 原命令的 A bank 编号。
    output wire [BANK_W-1:0]                exec_cmd_b_bank_o, // 原命令的 B bank 编号。
    output wire [BANK_W-1:0]                exec_cmd_c_bank_o, // 原命令的 C bank 编号。
    output wire [OP_CFG_W-1:0]              exec_cmd_op_cfg_o, // 原样转发的算子扩展配置。
    output wire [TAG_W-1:0]                 exec_cmd_tag_o, // 执行器须保存此 tag，并在 done 中回传。

    // exec_done 必须代表当前命令已经到达允许下一命令接管 cluster 的安全点。
    // 由完整执行器/结果收集器产生，不可仅用“分块描述符发完”代替完成。
    // done 也有反压：valid=1、ready=0 时，执行器必须保持 valid/tag/error 至握手。
    input  wire                             exec_done_valid_i, // 当前已下发命令的完成通知有效。
    output wire                             exec_done_ready_o, // 正等待完成且响应槽可用；为 0 时不能丢弃 done。
    input  wire [TAG_W-1:0]                 exec_done_tag_i, // 必须匹配当前命令下发握手时保存的 exec_cmd_tag_o。
    input  wire                             exec_done_error_i, // 1=执行失败，0=执行成功；失败也须满足安全完成条件。

    // 直接连接 npu_v13_systolic_cluster_runtime_stream 的 cfg 端口。
    // cfg 由内部 mode controller 独占驱动；不可同时接入第二个配置主机。
    output wire                             cluster_cfg_valid_o, // 接 cluster.cfg_valid_i：提交模式切换请求。
    output wire [1:0]                       cluster_cfg_mode_o, // 接 cluster.cfg_mode_i：目标模式，等待握手期间保持。
    input  wire                             cluster_cfg_ready_i, // 接 cluster.cfg_ready_o：集群当前允许提交配置。
    input  wire                             cluster_cfg_error_i, // 接 cluster.cfg_error_o：集群返回配置错误。
    input  wire [1:0]                       cluster_active_mode_i, // 接 cluster.active_mode_o：实际模式，用于同模式判断/确认。

    // queue_level 报告 FIFO 的物理占用。为切断时序路径，head 在处置事件的下一拍
    // 才由寄存 pop 移除，因此执行器刚接管命令后的一个周期内 level 仍包含该 head。
    output wire                             queue_empty_o, // FIFO 无命令；不代表执行器空闲或响应已取走。
    output wire                             queue_full_o, // FIFO 占用达到 FIFO_DEPTH；入口暂停接收。
    output wire [$clog2(FIFO_DEPTH+1)-1:0]  queue_level_o, // FIFO 总占用，包含预取级；不是系统全部未完成命令数。
    output wire                             dispatcher_busy_o, // 队列/调度/模式事务/未取响应任一非空闲时为 1。
    output wire                             exec_active_o // STATE_RUNNING：已下发命令、尚未接收 done；不是 PE 每拍使能。
);
    localparam [1:0] OPCODE_GEMM = 2'b00;
    localparam [1:0] OPCODE_CONV = 2'b01;

    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;

    localparam [2:0] RSP_OK                 = 3'b000;
    localparam [2:0] RSP_ILLEGAL_OPCODE     = 3'b001;
    localparam [2:0] RSP_ILLEGAL_MODE       = 3'b010;
    localparam [2:0] RSP_MODE_APPLY_ERROR   = 3'b011;
    localparam [2:0] RSP_EXECUTION_ERROR    = 3'b100;
    localparam [2:0] RSP_DONE_TAG_MISMATCH  = 3'b101;

    localparam [1:0] STATE_HEAD      = 2'd0;
    localparam [1:0] STATE_WAIT_MODE = 2'd1;
    localparam [1:0] STATE_ISSUE     = 2'd2;
    localparam [1:0] STATE_RUNNING   = 2'd3;

    localparam integer COMMAND_W =
        2 + (3 * DIM_W) + 2 + 3 + (3 * ADDR_W) +
        (3 * BANK_W) + OP_CFG_W + TAG_W;

    wire [COMMAND_W-1:0] fifo_in_data_w = {
        cmd_opcode_i,
        cmd_m_i,
        cmd_n_i,
        cmd_k_i,
        cmd_cluster_mode_i,
        cmd_layout_i,
        cmd_a_base_i,
        cmd_b_base_i,
        cmd_c_base_i,
        cmd_a_bank_i,
        cmd_b_bank_i,
        cmd_c_bank_i,
        cmd_op_cfg_i,
        cmd_tag_i
    };

    wire fifo_head_valid_w;
    wire fifo_head_ready_w;
    wire [COMMAND_W-1:0] fifo_head_data_w;

    npu_v13_command_fifo #(
        .DATA_W(COMMAND_W),
        .DEPTH(FIFO_DEPTH)
    ) u_command_fifo (
        .clk(clk),
        .resetn(resetn),
        .in_valid_i(cmd_valid_i),
        .in_ready_o(cmd_ready_o),
        .in_data_i(fifo_in_data_w),
        .out_valid_o(fifo_head_valid_w),
        .out_ready_i(fifo_head_ready_w),
        .out_data_o(fifo_head_data_w),
        .empty_o(queue_empty_o),
        .full_o(queue_full_o),
        .level_o(queue_level_o)
    );

    // FIFO 保存完整命令，并在 head 被正式 pop 前保证全部字段稳定。
    // 宽字段直接送往执行器，不在 dispatcher 中复制一份 194-bit pending command。
    assign {
        exec_cmd_opcode_o,
        exec_cmd_m_o,
        exec_cmd_n_o,
        exec_cmd_k_o,
        exec_cmd_cluster_mode_o,
        exec_cmd_layout_o,
        exec_cmd_a_base_o,
        exec_cmd_b_base_o,
        exec_cmd_c_base_o,
        exec_cmd_a_bank_o,
        exec_cmd_b_bank_o,
        exec_cmd_c_bank_o,
        exec_cmd_op_cfg_o,
        exec_cmd_tag_o
    } = fifo_head_data_w;

    // 只有参与控制决策的窄字段需要打一拍。若直接从 BRAM head 解码，
    // head -> reject/mode/response -> fifo pop -> BRAM EN/REGCE 会形成跨模块
    // 组合反馈路径。锁存 opcode/mode/tag 后，完整命令仍留在 FIFO head，
    // 但所有控制判断都从这些小寄存器出发，既切断关键路径，也避免复制地址、
    // M/K/N、op_cfg 等宽 payload。
    reg               head_meta_valid_r;
    reg [1:0]         head_opcode_r;
    reg [1:0]         head_mode_r;
    reg [TAG_W-1:0]   head_tag_r;
    reg               fifo_pop_r;

    // pop 脉冲有效的周期，FIFO 端口仍呈现旧 head；禁止误把它重新锁存。
    wire head_meta_load_w =
        !head_meta_valid_r && fifo_head_valid_w && !fifo_pop_r;
    wire head_opcode_legal_w =
        (head_opcode_r == OPCODE_GEMM) ||
        (head_opcode_r == OPCODE_CONV);
    wire head_mode_legal_w =
        (head_mode_r == MODE_16X16) ||
        (head_mode_r == MODE_4X8X8) ||
        (head_mode_r == MODE_16X4X4);
    wire head_legal_w = head_opcode_legal_w && head_mode_legal_w;
    wire head_same_mode_w =
        head_mode_r == cluster_active_mode_i;

    reg [1:0] state_r;

    // mode controller 的 request/response 完全隐藏在统一 dispatcher 内部。
    wire mode_req_valid_w =
        (state_r == STATE_HEAD) && head_meta_valid_r &&
        head_legal_w && !head_same_mode_w;
    wire mode_req_ready_w;
    wire mode_rsp_valid_w;
    wire mode_rsp_ready_w;
    wire [1:0] mode_rsp_mode_w;
    wire mode_rsp_error_w;
    wire mode_busy_w;

    npu_v13_cluster_mode_ctrl u_cluster_mode_ctrl (
        .clk(clk),
        .resetn(resetn),
        .mode_req_valid_i(mode_req_valid_w),
        .mode_req_ready_o(mode_req_ready_w),
        .mode_req_mode_i(head_mode_r),
        .mode_rsp_valid_o(mode_rsp_valid_w),
        .mode_rsp_ready_i(mode_rsp_ready_w),
        .mode_rsp_mode_o(mode_rsp_mode_w),
        .mode_rsp_error_o(mode_rsp_error_w),
        .mode_busy_o(mode_busy_w),
        .cluster_cfg_valid_o(cluster_cfg_valid_o),
        .cluster_cfg_mode_o(cluster_cfg_mode_o),
        .cluster_cfg_ready_i(cluster_cfg_ready_i),
        .cluster_cfg_error_i(cluster_cfg_error_i),
        .cluster_active_mode_i(cluster_active_mode_i)
    );

    wire mode_req_fire_w = mode_req_valid_w && mode_req_ready_w;
    wire mode_rsp_failure_w =
        mode_rsp_error_w || (mode_rsp_mode_w != head_mode_r);

    reg               rsp_valid_r;
    reg [TAG_W-1:0]   rsp_tag_r;
    reg [2:0]         rsp_status_r;
    wire rsp_fire_w = rsp_valid_r && cmd_rsp_ready_i;
    // 一深 response 槽支持“旧 response 同拍取走，新 response 同拍写入”。
    wire rsp_slot_available_w = !rsp_valid_r || cmd_rsp_ready_i;

    assign cmd_rsp_valid_o = rsp_valid_r;
    assign cmd_rsp_tag_o = rsp_tag_r;
    assign cmd_rsp_status_o = rsp_status_r;

    wire local_reject_w =
        (state_r == STATE_HEAD) && head_meta_valid_r && !head_legal_w;
    wire local_reject_fire_w = local_reject_w && rsp_slot_available_w;

    // 失败 response 必须先有空间；成功 mode response 不占 command response 槽。
    assign mode_rsp_ready_w =
        (state_r == STATE_WAIT_MODE) && mode_rsp_valid_w &&
        (!mode_rsp_failure_w || rsp_slot_available_w);
    wire mode_rsp_fire_w = mode_rsp_valid_w && mode_rsp_ready_w;
    wire mode_failure_fire_w = mode_rsp_fire_w && mode_rsp_failure_w;

    // 同模式 head 直接下发；不同模式只有确认成功后才能下发。
    assign exec_cmd_valid_o = fifo_head_valid_w && head_meta_valid_r &&
        head_legal_w &&
        (((state_r == STATE_HEAD) && head_same_mode_w) ||
         (state_r == STATE_ISSUE));
    wire exec_cmd_fire_w = exec_cmd_valid_o && exec_cmd_ready_i;

    reg [TAG_W-1:0] active_tag_r;
    assign exec_active_o = (state_r == STATE_RUNNING);

    // done 被接收时生成 command response，因此 response 槽满会自然反压执行器。
    assign exec_done_ready_o =
        (state_r == STATE_RUNNING) && rsp_slot_available_w;
    wire exec_done_fire_w = exec_done_valid_i && exec_done_ready_o;

    // 三种事件都代表当前 head 已经被处置。事件先锁存为单周期 pop 脉冲，
    // 下一拍再释放 FIFO head，使 payload decode/response/exec ready 不会组合进入
    // RAMB36 的 EN/REGCE；增加的一个命令退休周期会被 RUNNING 阶段隐藏。
    wire head_retire_w =
        local_reject_fire_w || mode_failure_fire_w || exec_cmd_fire_w;
    assign fifo_head_ready_w = fifo_pop_r;

    // 隔离实验r4：fifo_pop_r经FIFO预取ready逻辑直接驱动BRAM读使能。
    // 若异步清零，BRAM的EN可在非时钟边沿变化，Vivado报告REQP-1839。
    // 因此仅此处改为同步复位：resetn须已同步且至少覆盖一个上升沿，
    // 与隔离FIFO一致。FIFO在resetn=0时屏蔽握手和RAM访问；其他控制
    // 寄存器保留原实现。本模块不替代顶层复位同步器。
    always @(posedge clk) begin
        if (!resetn)
            fifo_pop_r <= 1'b0;
        else
            fifo_pop_r <= head_retire_w;
    end

    assign dispatcher_busy_o =
        (state_r != STATE_HEAD) || fifo_head_valid_w ||
        !queue_empty_o || mode_busy_w || rsp_valid_r;

    // metadata 与 FIFO head 一一对应。命令 pop 后立即失效；下一个 head
    // 可以在当前命令 RUNNING 期间提前锁存，但 mode request 仍由 STATE_HEAD
    // 门控，因此不会在计算未完成时切换 runtime cluster。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            head_meta_valid_r <= 1'b0;
        end else begin
            if (head_retire_w) begin
                head_meta_valid_r <= 1'b0;
            end else if (head_meta_load_w) begin
                head_meta_valid_r <= 1'b1;
            end
        end
    end

    // metadata data 位由 valid 保护，无需接入高扇出 reset 网络。
    always @(posedge clk) begin
        if (head_meta_load_w) begin
            head_opcode_r <= exec_cmd_opcode_o;
            head_mode_r <= exec_cmd_cluster_mode_o;
            head_tag_r <= exec_cmd_tag_o;
        end
    end

    // FSM 只复位协议状态；宽 command 位于 BRAM/ram_q 中，不在此复制或复位。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state_r <= STATE_HEAD;
        end else begin
            case (state_r)
                STATE_HEAD: begin
                    if (mode_req_fire_w)
                        state_r <= STATE_WAIT_MODE;
                    else if (exec_cmd_fire_w)
                        state_r <= STATE_RUNNING;
                end

                STATE_WAIT_MODE: begin
                    if (mode_rsp_fire_w) begin
                        if (mode_rsp_failure_w)
                            state_r <= STATE_HEAD;
                        else
                            state_r <= STATE_ISSUE;
                    end
                end

                STATE_ISSUE: begin
                    if (exec_cmd_fire_w)
                        state_r <= STATE_RUNNING;
                end

                STATE_RUNNING: begin
                    if (exec_done_fire_w)
                        state_r <= STATE_HEAD;
                end

                default: state_r <= STATE_HEAD;
            endcase
        end
    end

    // 下游接管命令后，FIFO 可立即释放 head；RUNNING 期间只需保留 tag。
    always @(posedge clk) begin
        if (exec_cmd_fire_w)
            active_tag_r <= head_tag_r;
    end

    // command response 是独立的一深弹性寄存器，反压期间 tag/status 均保持。
    // 所有 data 字段由 rsp_valid_r 保护，因此无需 reset。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rsp_valid_r <= 1'b0;
        end else begin
            if (rsp_fire_w)
                rsp_valid_r <= 1'b0;

            if (local_reject_fire_w || mode_failure_fire_w ||
                exec_done_fire_w)
                rsp_valid_r <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (local_reject_fire_w) begin
            rsp_tag_r <= head_tag_r;
            if (!head_opcode_legal_w)
                rsp_status_r <= RSP_ILLEGAL_OPCODE;
            else
                rsp_status_r <= RSP_ILLEGAL_MODE;
        end else if (mode_failure_fire_w) begin
            rsp_tag_r <= head_tag_r;
            rsp_status_r <= RSP_MODE_APPLY_ERROR;
        end else if (exec_done_fire_w) begin
            rsp_tag_r <= active_tag_r;
            if (exec_done_tag_i != active_tag_r)
                rsp_status_r <= RSP_DONE_TAG_MISMATCH;
            else if (exec_done_error_i)
                rsp_status_r <= RSP_EXECUTION_ERROR;
            else
                rsp_status_r <= RSP_OK;
        end
    end
endmodule
