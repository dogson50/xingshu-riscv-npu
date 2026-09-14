// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

// 命令执行控制器：接管一条命令，持有上下文，协调 bank/后端，并启动独立 scheduler。
// 不实现地址计算、卷积窗口、BRAM、feeder、collector，也不再次配置 cluster mode。
//
// 生命周期：IDLE -> CHECK -> ACQUIRE -> PREPARE -> LAUNCH -> RUN -> RELEASE -> DONE。
// 非法通用字段直接 DONE(error)；申请失败不获得 bank；后端拒绝先释放 bank 再 DONE。
// exec_cmd 握手之后，上游可改变所有输入字段；ctx_* 一直保持到 exec_done 握手。
//
// 接口契约（都是本时钟域）：
// 1. buffer_acquire 的 valid&&ready 是原子授予/拒绝，error=1 表示一个 bank 也未占用。
//    A/B/C 是独立存储空间，编号相同不自动意味着冲突；别名/依赖由 buffer manager 判断。
// 2. backend_prepare 握手检查地址、op_cfg、算子能力，并准备接收本命令；尚不能读写数据。
//    error=0 的后端必须能接收后续 job_start 单拍脉冲。error=1 不得留下执行副作用。
//    CONV 的 M/N/K 已是等效 GEMM 维度；真实窗口语义属于后端，不支持时必须拒绝。
// 3. job_start 与内部 scheduler 命令握手同拍。后端据此开始一次执行，不是每拍 MAC 使能。
// 4. tile_batch 只是一份分块描述符，不是 A/B 数据或 K 拍 tuser/tlast。
// 5. job_complete 必须来自真实完成跟踪：所有结果已收集/提交写回，数据通路已安全排空。
//    出错也要接收并丢弃剩余描述符、排空已启动工作，再返回 error 完成。不能中途停读
//    描述符又等待本模块完成；本模块不提供任意时刻强停计算阵列的功能。
//    完成 valid 必须保持到 ready；只有 schedule_done 后才允许握手，禁止提前释放 bank。
//    错 tag 会被消费并记为协议错误，但不能释放当前命令；仍需正确 tag 的安全完成。
// 6. buffer_release 握手原子归还 A/B、提交/作废 C；error=1 时不得发布有效 C。
//    release 被反压时仍持有 bank，只有 release 完成后才向 dispatcher 报 exec_done。
// 7. resetn 必须与 dispatcher、bank manager、后端一起复位；reset 中断任务不产生 done。
//    本模块只复位控制状态，不复位宽命令字段，ctx_valid=0 时这些字段无协议意义。
module npu_v13_job_executor #(
    parameter integer DIM_W = 16,
    parameter integer ADDR_W = 32,
    parameter integer BANK_W = 1,
    parameter integer OP_CFG_W = 32,
    parameter integer TAG_W = 8
) (
    input wire clk, // 执行器与相连控制接口的统一时钟；各 ready/valid 事务在上升沿握手。
    input wire resetn, // 低有效异步复位执行状态、租约标记和完成状态；宽上下文不清零，须与 manager/后端协调复位。

    // 直接对接 command_queue_dispatcher 的 exec_cmd_*；一深上下文，与 bank ready 解耦。
    input wire exec_cmd_valid_i, // dispatcher 下发的整条命令有效；ready=0 时保持 valid 及所有 exec_cmd_* 字段。
    output wire exec_cmd_ready_o, // 非复位且上下文槽为空时可接收命令；不要求 A/B 已就绪，握手不等于获得 bank 或开始计算。
    input wire [1:0] exec_cmd_opcode_i, // 命令类别：00=GEMM，01=CONV；10/11 拒绝，不支持的合法类别由后端 prepare 报错。
    input wire [DIM_W-1:0] exec_cmd_m_i, // 原始/等效 GEMM 的输出行数 M，实际数量而非减一编码；必须大于 0。
                           exec_cmd_n_i, // 原始/等效 GEMM 的输出列数 N，实际数量；必须大于 0。
                           exec_cmd_k_i, // 原始/等效 GEMM 的归约长度 K，实际数量；必须大于 0，由每条命令动态指定。
    input wire [1:0] exec_cmd_cluster_mode_i, // 已由 dispatcher 确认的阵列模式：00=16x16，01=4组8x8，10=16组4x4，11 非法。
    input wire [2:0] exec_cmd_layout_i, // 逻辑 group 排列编码；模式 00/01/10 的合法范围分别为 0/0..2/0..4，由 scheduler 解释。
    input wire [ADDR_W-1:0] exec_cmd_a_base_i, // A 起始地址描述字段；地址单位与布局由上游和后端约定，此处只锁存转发。
                            exec_cmd_b_base_i, // B 起始地址描述字段；不在执行器内计算实际 BRAM 读地址。
                            exec_cmd_c_base_i, // C 写回起始地址描述字段；由后端结果写回模块解释。
    input wire [BANK_W-1:0] exec_cmd_a_bank_i, // 本命令待读取的 A bank 编号；编号不代表 READY，后续向 manager 申请。
                            exec_cmd_b_bank_i, // 本命令待读取的 B bank 编号；与 A/C 属于各自独立的 bank 空间。
                            exec_cmd_c_bank_i, // 本命令待写入的 C bank 编号；需要 manager 确认其空闲后才能占用。
    input wire [OP_CFG_W-1:0] exec_cmd_op_cfg_i, // 算子扩展参数或描述符索引；原样锁存，不在本模块执行 CONV 展开或量化。
    input wire [TAG_W-1:0] exec_cmd_tag_i, // 当前命令的关联标识；锁存后贯穿租约申请、分块描述符和完成回报，本模块不检查全局唯一性。

    // 安全完成接口；valid/tag/error 在反压期间不变，恰好一次握手结束本命令。
    output wire exec_done_valid_o, // 安全结束响应待取：已释放取得的缓存租约，或在取得租约前失败；不是仅描述符发送结束。
    input wire exec_done_ready_i, // dispatcher 可接收完成响应；反压期间本模块保持 done valid/tag/error 并拒绝新命令。
    output wire [TAG_W-1:0] exec_done_tag_o, // 已结束命令的原始 tag；仅在 exec_done_valid_o=1 时作为有效完成标识。
    output wire exec_done_error_o, // 本命令累计错误状态，0=成功、1=失败；随 done 保持，错误完成也不能遗留在途访问。

    // 当前命令上下文。后续 manager/地址模块各取所需字段；不要复制另一个命令 FIFO。
    // 所有 ctx_* 数据字段仅在 ctx_valid_o=1 时有效，从命令接收到 done 握手期间保持不变。
    output wire ctx_valid_o, // 已锁存上下文存在；从命令接收到 done 被取走期间有效，不能单独作为 RAM 访问授权。
    output reg [1:0] ctx_opcode_o, // 当前锁存的 GEMM/CONV 类别；ctx_valid_o=1 期间保持稳定。
    output reg [DIM_W-1:0] ctx_m_o, // 当前命令完整输出行数 M；不是单个 tile 的有效行数。
                           ctx_n_o, // 当前命令完整输出列数 N；不是单个 tile 的有效列数。
                           ctx_k_o, // 当前命令完整归约长度 K；供后端生成 A/B 连续数据流。
    output reg [1:0] ctx_cluster_mode_o, // 当前命令阵列模式；传给 scheduler/后端，不直接驱动 cluster 的 cfg 握手。
    output reg [2:0] ctx_layout_o, // 当前命令逻辑 group 布局；与模式共同决定每个 batch 的覆盖区域。
    output reg [ADDR_W-1:0] ctx_a_base_o, // 稳定的 A 起始地址描述，供独立后端地址生成器使用；ctx_valid=0 时无意义。
                            ctx_b_base_o, // 稳定的 B 起始地址描述；地址单位沿用命令约定。
                            ctx_c_base_o, // 稳定的 C 写回地址描述；后端仍须做地址范围检查。
    output reg [BANK_W-1:0] ctx_a_bank_o, // 当前 A bank 编号，接 manager.req_a_bank_i；整个命令上下文有效期间保持。
                            ctx_b_bank_o, // 当前 B bank 编号，接 manager.req_b_bank_i；不代表 bank 已取得或数据已准备好。
                            ctx_c_bank_o, // 当前 C bank 编号，接 manager.req_c_bank_i；写入需等待成功 acquire 和后端启动。
    output reg [OP_CFG_W-1:0] ctx_op_cfg_o, // 锁存的算子扩展配置；后端 prepare 阶段验证，执行阶段解释。
    output reg [TAG_W-1:0] ctx_tag_o, // 稳定的命令 tag，接 manager.req_tag_i，并用于核对后端完成事件。

    // 请求的 bank/tag 来自稳定的 ctx_*；ready 不是单纯空闲提示，而是原子处理本请求。
    output wire buffer_acquire_valid_o, // 向 manager 原子申请 ctx 指定的 A/B/C 租约；等待 ready 时保持请求和上下文。
    input wire buffer_acquire_ready_i, // manager 本拍受理申请；只有 valid&&ready 且 error=0 才算同时取得全部资源。
    input wire buffer_acquire_error_i, // 申请握手时的错误结果；1 表示未取得任何 bank，本命令报错结束。
    output wire buffer_release_valid_o, // 通知 manager 释放本命令租约；正常运行必须先收到全部在途操作已排空的正确 tag 完成事件。
    input wire buffer_release_ready_i, // manager 已核对租约身份且本拍可释放；握手后执行器才撤销 owned 并产生 done。
    output wire buffer_release_error_o, // 随 release 的命令失败标记：1 要求丢弃 C，0 发布有效 C；两种情况都归还 A/B。
    output wire buffers_owned_o, // 成功 acquire 后到 release 握手前为 1；表示持有租约，不代表后端已经启动。

    // 后端准备握手也使用 ctx_*。不支持 CONV/地址越界等在握手时返回 error。
    output wire backend_prepare_valid_o, // 要求后端校验稳定 ctx 并准备任务；此阶段不能开始实际数据访问。
    input wire backend_prepare_ready_i, // 后端本拍受理 prepare；若同时 error=0，须保证随后能够接收无反压的 job_start。
    input wire backend_prepare_error_i, // prepare 握手时报告不支持算子、非法地址等错误；1 时不启动任务，转入释放租约。
    output wire job_start_o, // prepare 成功后与内部 scheduler 命令握手同拍的一周期启动通知；无 ready，后端由此开始任务。
    output wire job_cancel_o, // scheduler 意外拒绝命令时的一周期取消通知；后端清理后仍须返回安全完成，不是通用异步强停。

    // scheduler 的真实描述符输出，反压与 II=1 契约原样保留。
    output wire tile_batch_valid_o, // scheduler 当前分块批次描述符有效；在 ready=0 时保持 valid 和所有 tile_batch_* 字段。
    input wire tile_batch_ready_i, // 后端能接收一个批次描述符；不是 systolic cluster 的 A/B 数据流 ready。
    output wire [DIM_W-1:0] tile_batch_m_o, // 每个描述符重复携带完整命令 M，供后端计算尾块；不是当前 tile 行数。
                            tile_batch_n_o, // 每个描述符重复携带完整命令 N，供后端计算尾块；不是当前 tile 列数。
                            tile_batch_k_o, // 该命令完整 K 归约长度；每个 batch 的 A/B 数据流由后端按此生成。
    output wire [DIM_W-1:0] tile_batch_m_base_o, // 本批次在逻辑 C 矩阵中的零起始行坐标；不是 BRAM/字节地址。
                            tile_batch_n_base_o, // 本批次在逻辑 C 矩阵中的零起始列坐标；结合 ctx_c_base_o 等生成实际写回地址。
    output wire [1:0] tile_batch_cluster_mode_o, // 本批次采用的 cluster 模式；只随描述符传输，不触发运行时模式切换。
    output wire [2:0] tile_batch_layout_o, // 本批次逻辑 group 排列方式；与 mode 和基坐标共同解释覆盖区域。
    output wire tile_batch_cmd_first_o, // 当前描述符是整条命令的首个 batch；不是 K 数据 packet 的 tuser。
                tile_batch_cmd_last_o, // 当前描述符是整条命令的最后一个 batch；不是 K 数据 packet 的 tlast，也不是结果完成。
    output wire [TAG_W-1:0] tile_batch_tag_o, // 本批次所属命令 tag；与描述符同拍，供后端关联结果和完成计数。
    output wire schedule_finished_o, // 当前命令描述符已全部交接的粘滞状态，或 scheduler 拒绝后置位；新命令/复位清除，不代表计算排空。

    // 来自独立 completion tracker 的安全完成事件；不是 cluster 的单个 tile_valid。
    input wire job_complete_valid_i, // 后端安全完成事件有效：所有计算、读响应和结果写入均已排空；等待 ready 时保持 valid/tag/error。
    output wire job_complete_ready_o, // 执行器处于 RUN 且调度已结束，允许接收完成事件；不是允许释放任意 tag 的租约。
    input wire [TAG_W-1:0] job_complete_tag_i, // 安全完成对应的命令 tag；不匹配事件会被消费并记错，但仍等待正确 tag，不能提前释放 bank。
    input wire job_complete_error_i, // 后端完成错误位，仅完成握手且 tag 匹配时并入命令错误；失败也必须满足安全排空条件。
    output wire busy_o // 当前命令生命周期尚未结束，含检查/等待资源/运行/释放/等待 done 被取走；复位时为 0。
);

    localparam [3:0] ST_IDLE=0, ST_CHECK=1, ST_ACQUIRE=2, ST_PREPARE=3,
                     ST_LAUNCH=4, ST_RUN=5, ST_RELEASE=6, ST_DONE=7;
    // 保留行为级状态编号，由综合器使用 one-hot：降低状态 -> scheduler 启动使能译码深度。
    // 只改变物理编码，不改变任何状态驻留周期和上下文稳定窗口。
    (* fsm_encoding = "one_hot" *) reg [3:0] state_r;
    reg error_r;
    reg owned_r;
    reg schedule_finished_r;
    wire scheduler_ready_w, scheduler_error_w, scheduler_done_w;
    wire [TAG_W-1:0] scheduler_done_tag_w;

    // 通用合法性只检查几何/类别；地址、bank 依赖与卷积参数留给独立后端。
    wire shape_legal_w = (ctx_m_o != 0) && (ctx_n_o != 0) && (ctx_k_o != 0);
    wire layout_legal_w =
        ((ctx_cluster_mode_o == 2'b00) && (ctx_layout_o == 0)) ||
        ((ctx_cluster_mode_o == 2'b01) && (ctx_layout_o <= 2)) ||
        ((ctx_cluster_mode_o == 2'b10) && (ctx_layout_o <= 4));
    wire command_legal_w = !ctx_opcode_o[1] && shape_legal_w && layout_legal_w;

    assign busy_o = resetn && (state_r != ST_IDLE);
    assign ctx_valid_o = busy_o;
    assign exec_cmd_ready_o = resetn && (state_r == ST_IDLE);
    wire command_fire_w = exec_cmd_valid_i && exec_cmd_ready_o;
    assign exec_done_valid_o = resetn && (state_r == ST_DONE);
    assign exec_done_tag_o = ctx_tag_o;
    assign exec_done_error_o = error_r;
    assign buffer_acquire_valid_o = resetn && (state_r == ST_ACQUIRE);
    assign buffer_release_valid_o = resetn && (state_r == ST_RELEASE);
    assign buffer_release_error_o = error_r;
    assign buffers_owned_o = resetn && owned_r;
    assign backend_prepare_valid_o = resetn && (state_r == ST_PREPARE);
    wire scheduler_valid_w = resetn && (state_r == ST_LAUNCH);
    assign job_start_o = scheduler_valid_w && scheduler_ready_w;
    assign job_cancel_o = resetn && (state_r == ST_RUN) && scheduler_error_w;
    assign schedule_finished_o = resetn && schedule_finished_r;
    assign job_complete_ready_o = resetn && (state_r == ST_RUN) && schedule_finished_r;

    // 命令交接后锁存一次，整个命令期间不再依赖 FIFO head；宽数据不接 reset。
    always @(posedge clk) begin
        if (command_fire_w) begin
            ctx_opcode_o <= exec_cmd_opcode_i;
            ctx_m_o <= exec_cmd_m_i;
            ctx_n_o <= exec_cmd_n_i;
            ctx_k_o <= exec_cmd_k_i;
            ctx_cluster_mode_o <= exec_cmd_cluster_mode_i;
            ctx_layout_o <= exec_cmd_layout_i;
            ctx_a_base_o <= exec_cmd_a_base_i;
            ctx_b_base_o <= exec_cmd_b_base_i;
            ctx_c_base_o <= exec_cmd_c_base_i;
            ctx_a_bank_o <= exec_cmd_a_bank_i;
            ctx_b_bank_o <= exec_cmd_b_bank_i;
            ctx_c_bank_o <= exec_cmd_c_bank_i;
            ctx_op_cfg_o <= exec_cmd_op_cfg_i;
            ctx_tag_o <= exec_cmd_tag_i;
        end
    end

    // 仅控制状态复位。每条命令串行执行，RUN 期间不接收下一条命令/切换模式。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state_r <= ST_IDLE;
            error_r <= 1'b0;
            owned_r <= 1'b0;
            schedule_finished_r <= 1'b0;
        end else begin
            case (state_r)
                ST_IDLE: if (command_fire_w) begin
                    state_r <= ST_CHECK;
                    error_r <= 1'b0;
                    schedule_finished_r <= 1'b0;
                end
                ST_CHECK: begin
                    if (command_legal_w) state_r <= ST_ACQUIRE;
                    else begin
                        error_r <= 1'b1;
                        state_r <= ST_DONE;
                    end
                end
                ST_ACQUIRE: if (buffer_acquire_ready_i) begin
                    if (buffer_acquire_error_i) begin
                        error_r <= 1'b1;
                        state_r <= ST_DONE;
                    end else begin
                        owned_r <= 1'b1;
                        state_r <= ST_PREPARE;
                    end
                end
                ST_PREPARE: if (backend_prepare_ready_i) begin
                    if (backend_prepare_error_i) begin
                        error_r <= 1'b1;
                        state_r <= ST_RELEASE;
                    end else state_r <= ST_LAUNCH;
                end
                ST_LAUNCH: if (scheduler_ready_w) state_r <= ST_RUN;
                ST_RUN: begin
                    if (scheduler_done_w) begin
                        schedule_finished_r <= 1'b1;
                        if (scheduler_done_tag_w != ctx_tag_o) error_r <= 1'b1;
                    end
                    // 正常本地检查已挡住非法几何。若 scheduler 仍拒绝，不把拒绝
                    // 当作后端已停止：先 cancel，再等后端明确返回安全完成。
                    if (scheduler_error_w) begin
                        schedule_finished_r <= 1'b1;
                        error_r <= 1'b1;
                    end
                    if (job_complete_valid_i && job_complete_ready_o) begin
                        if (job_complete_tag_i != ctx_tag_o) error_r <= 1'b1;
                        else begin
                            error_r <= error_r || job_complete_error_i;
                            state_r <= ST_RELEASE;
                        end
                    end
                end
                ST_RELEASE: if (buffer_release_ready_i) begin
                    owned_r <= 1'b0;
                    state_r <= ST_DONE;
                end
                ST_DONE: if (exec_done_ready_i) state_r <= ST_IDLE;
                default: state_r <= ST_IDLE;
            endcase
        end
    end

    // 几何枚举模块保持独立实现；此处只连接，不改动其经过验证的每拍数据路径。
    npu_v13_gemm_tile_scheduler #(.DIM_W(DIM_W), .TAG_W(TAG_W)) u_scheduler (
        .clk(clk), .resetn(resetn),
        .cmd_valid_i(scheduler_valid_w), .cmd_ready_o(scheduler_ready_w),
        .cmd_m_i(ctx_m_o), .cmd_n_i(ctx_n_o), .cmd_k_i(ctx_k_o),
        .cmd_mode_i(ctx_cluster_mode_o), .cmd_layout_i(ctx_layout_o), .cmd_tag_i(ctx_tag_o),
        .cmd_error_o(scheduler_error_w),
        .tile_batch_valid_o(tile_batch_valid_o), .tile_batch_ready_i(tile_batch_ready_i),
        .tile_batch_m_o(tile_batch_m_o), .tile_batch_n_o(tile_batch_n_o), .tile_batch_k_o(tile_batch_k_o),
        .tile_batch_m_base_o(tile_batch_m_base_o), .tile_batch_n_base_o(tile_batch_n_base_o),
        .tile_batch_cluster_mode_o(tile_batch_cluster_mode_o), .tile_batch_layout_o(tile_batch_layout_o),
        .tile_batch_cmd_first_o(tile_batch_cmd_first_o), .tile_batch_cmd_last_o(tile_batch_cmd_last_o),
        .tile_batch_tag_o(tile_batch_tag_o), .scheduler_busy_o(),
        .schedule_done_o(scheduler_done_w), .schedule_done_tag_o(scheduler_done_tag_w)
    );
endmodule
