// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_cluster_mode_ctrl
//
// 一、模块职责
// -----------
// 本模块位于 job dispatcher 与 npu_v13_systolic_cluster_runtime_stream 的配置
// 端口之间，只负责把“一次目标 mode 请求”转换为计算集群的 cfg ready/valid
// 事务，并在模式真正生效后返回一条 response。
//
// 上游请求接口：
//   mode_req_valid_i/mode_req_ready_o/mode_req_mode_i
//
// 上游响应接口：
//   mode_rsp_valid_o/mode_rsp_ready_i/mode_rsp_mode_o/mode_rsp_error_o
//
// 下游计算集群配置接口：
//   cluster_cfg_valid_o/cluster_cfg_ready_i/cluster_cfg_mode_o
//   cluster_cfg_error_i/cluster_active_mode_i
//
// 二、为什么需要独立 response
// -----------------------
// 请求握手只表示控制器已经保存目标 mode，不表示计算集群已经切换完成。若集群
// 尚未排空，cfg_ready 会保持为 0，本模块必须保存请求并持续等待。只有出现以下
// 情况之一才返回 response：
//   1. 请求 mode 已经等于 active_mode，无需写配置；
//   2. cfg 完成握手，并观察到 active_mode 更新为请求值；
//   3. 请求 mode 非法，或计算集群返回 cfg_error。
//
// response 也使用 ready/valid，因此上游暂时不能接收完成信息时，本模块会保持
// mode_rsp_* 稳定，不会丢失单周期完成事件。
//
// 三、并发和所有权约束
// ------------------
// 本模块只保存一条 outstanding 请求。mode_busy_o=1 时不接收下一条请求。
// cluster cfg 端口必须由本模块独占，不能再有第二个配置主机同时修改 active_mode。
// 本模块不解释 GEMM/CONV，不观察 A/B 数据，也不决定计算集群什么时候排空；
// cluster_cfg_ready_i 已经完整表达“当前是否允许提交配置”，因此这里不复制
// cluster_idle 或输入数据有效性的判断。
//
// 四、模式编码
// ----------
// 编码必须与 runtime cluster 一致：
//   2'b00：一个 16x16 逻辑组；
//   2'b01：四个 8x8 逻辑组；
//   2'b10：十六个 4x4 逻辑组；
//   2'b11：非法。本模块在本地拒绝，不向 cluster 发出 cfg 请求。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_cluster_mode_ctrl (
    input  wire         clk, // 模式请求、配置和响应共用的时钟；ready/valid 在上升沿握手。
    input  wire         resetn, // 低有效异步复位状态机，取消未完成的控制事务；系统复位期间上游不得提交请求。

    // 上游目标模式请求。发送方在 valid=1、ready=0 时必须保持 mode 稳定。
    input  wire         mode_req_valid_i, // 目标模式请求有效；等待 ready 时保持 valid 和目标模式，握手只表示请求已被锁存。
    output wire         mode_req_ready_o, // 控制器处于 IDLE、可接管一条请求；未用 resetn 门控，复位期间不能据此视为有效接收。
    input  wire [1:0]   mode_req_mode_i, // 目标模式：00=1组16x16，01=4组8x8，10=16组4x4；11 在本地拒绝并返回错误。

    // 每个已接收请求严格返回一次 response。error=0 表示对应 mode 已经生效；
    // error=1 表示请求失败，此时 mode 字段仍回显原始目标值，便于定位命令。
    output wire         mode_rsp_valid_o, // 一条模式请求的响应待取；与 ready 握手后才允许完成该事务，反压期间保持响应。
    input  wire         mode_rsp_ready_i, // 上游能接收模式响应；与 mode_rsp_valid_o 同为 1 时取走本次结果。
    output wire [1:0]   mode_rsp_mode_o, // 回显已锁存的请求目标模式，error=1 时也不改为实际模式；仅在 rsp_valid=1 时使用。
    output wire         mode_rsp_error_o, // 响应错误位：0 表示目标模式已确认生效，1 表示拒绝或配置/确认失败；随响应保持。

    // 控制器存在尚未完成或尚未被上游取走的事务。
    output wire         mode_busy_o, // 控制器尚有未完成请求或未取走响应；不是计算阵列的运算 busy。

    // 直接连接 npu_v13_systolic_cluster_runtime_stream 的 cfg 端口。
    output wire         cluster_cfg_valid_o, // 向 runtime cluster 提交模式配置，在 cfg_ready_i=0 时持续有效并保持模式字段。
    output wire [1:0]   cluster_cfg_mode_o, // 待写入 cluster 的合法目标模式，须与 cluster_cfg_valid_o 一起解释。
    input  wire         cluster_cfg_ready_i, // 来自 cluster 的配置接收许可；valid/ready 握手后进入确认阶段，不等同于已确认成功。
    input  wire         cluster_cfg_error_i, // 来自 cluster 的配置错误脉冲；在配置握手后的确认阶段检查。
    input  wire [1:0]   cluster_active_mode_i // cluster 当前实际生效模式；用于跳过同模式切换及核验配置结果。
);
    localparam [1:0] MODE_16X16  = 2'b00;
    localparam [1:0] MODE_4X8X8  = 2'b01;
    localparam [1:0] MODE_16X4X4 = 2'b10;

    // IDLE：可接收请求；CFG：向 cluster 持续提交配置；
    // CONFIRM：配置已经握手，等待 active_mode/cfg_error 的同步返回；
    // RESPONSE：完成信息保持到上游握手。
    localparam [1:0] STATE_IDLE     = 2'd0;
    localparam [1:0] STATE_CFG      = 2'd1;
    localparam [1:0] STATE_CONFIRM  = 2'd2;
    localparam [1:0] STATE_RESPONSE = 2'd3;

    reg [1:0] state_r;

    // 目标 mode 和 response error 都由 state_r 保护：只有请求被接收后才会被
    // 观察，因此不接 reset，可避免给纯数据寄存器增加复位 mux。
    reg [1:0] target_mode_r;
    reg       response_error_r;

    wire request_fire_w = mode_req_valid_i && mode_req_ready_o;
    wire response_fire_w = mode_rsp_valid_o && mode_rsp_ready_i;
    wire cluster_cfg_fire_w = cluster_cfg_valid_o && cluster_cfg_ready_i;
    wire request_mode_legal_w =
        (mode_req_mode_i == MODE_16X16) ||
        (mode_req_mode_i == MODE_4X8X8) ||
        (mode_req_mode_i == MODE_16X4X4);

    assign mode_req_ready_o = (state_r == STATE_IDLE);
    assign mode_rsp_valid_o = (state_r == STATE_RESPONSE);
    assign mode_rsp_mode_o = target_mode_r;
    assign mode_rsp_error_o = response_error_r;
    assign mode_busy_o = (state_r != STATE_IDLE);

    // STATE_CFG 期间 target_mode_r 不再变化，因此即使 cluster_cfg_ready_i 长时间
    // 为 0，cfg_valid 和 cfg_mode 也严格满足 ready/valid 的稳定性要求。
    assign cluster_cfg_valid_o = (state_r == STATE_CFG);
    assign cluster_cfg_mode_o = target_mode_r;

    // 只有状态寄存器属于复位后必须确定的协议状态。因此带异步 reset 的过程
    // 只写 state_r；把数据寄存器混写在这里会让部分综合器把“复位时保持原值”
    // 解释成特殊 set/reset 优先级，并产生不必要的推断警告。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state_r <= STATE_IDLE;
        end else begin
            case (state_r)
                STATE_IDLE: begin
                    if (request_fire_w) begin
                        if (!request_mode_legal_w) begin
                            // 非法模式在本地结束，绝不把 2'b11 送入计算集群。
                            state_r <= STATE_RESPONSE;
                        end else if (mode_req_mode_i ==
                                     cluster_active_mode_i) begin
                            // 已经处于目标模式，不制造无意义 cfg 事务。
                            state_r <= STATE_RESPONSE;
                        end else begin
                            state_r <= STATE_CFG;
                        end
                    end
                end

                STATE_CFG: begin
                    if (cluster_cfg_fire_w)
                        state_r <= STATE_CONFIRM;
                end

                STATE_CONFIRM: begin
                    // runtime cluster 的 active_mode/cfg_error 都在 cfg 握手后的
                    // 时钟沿更新。本状态至少等待一拍，再检查同步返回值。
                    if (cluster_cfg_error_i) begin
                        state_r <= STATE_RESPONSE;
                    end else if (cluster_active_mode_i == target_mode_r) begin
                        state_r <= STATE_RESPONSE;
                    end
                end

                STATE_RESPONSE: begin
                    if (response_fire_w)
                        state_r <= STATE_IDLE;
                end

                default: begin
                    state_r <= STATE_IDLE;
                end
            endcase
        end
    end

    // 目标 mode 和错误字段是由 state_r 的 valid 语义保护的数据状态，不接
    // reset。每条请求都会覆盖 target_mode_r；每条 response 产生前也一定会
    // 明确写入 response_error_r，因此复位前遗留值不可能作为有效响应出现。
    always @(posedge clk) begin
        if ((state_r == STATE_IDLE) && request_fire_w) begin
            target_mode_r <= mode_req_mode_i;
            response_error_r <= !request_mode_legal_w;
        end else if (state_r == STATE_CONFIRM) begin
            if (cluster_cfg_error_i)
                response_error_r <= 1'b1;
            else if (cluster_active_mode_i == target_mode_r)
                response_error_r <= 1'b0;
        end
    end
endmodule
