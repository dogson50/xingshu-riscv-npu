// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps

// 独立缓存所有权管理器，不含 BRAM、不计算地址、不产生数据 valid。
// A/B 各 AB_BANKS 个 bank，C 独立 C_BANKS（默认单 C，绝不强制输出双缓冲）。
// 输入状态：FREE -> LOADING -> READY -> IN_USE -> (RETAIN_INPUTS?READY:FREE)；装载失败回FREE。
// 输出状态：默认FREE -> IN_USE -> READY -> DRAINING -> FREE；流式已消费/执行失败release直接回FREE。
// load_finish 只能在所有写已落入 BRAM 后提交；c_return 只能在读响应/下游消费已排空后提交。
// acquire 是 A/B/C 全有或全无；忙则等待，非法编号/重复租约则握手拒绝。
// 一个在执行租约，与 job_executor 对齐。release 必须匹配已锁存 bank/tag。
// 基于正式buffer_manager的隔离扩展，不修改原文件。默认参数保持原有单次消费行为。
// RETAIN_INPUTS=1：正常/失败命令均保留只读A/B，重装必须显式discard READY->FREE。
// C_STREAM_CONSUMED=1：仅在结果末字已实际消费后释放C；不能与未排空的feature-store混用。
// reset 必须和 executor/装载器/feeder/collector 同步中止任务。只清状态，不清数据/tag。
module npu_v13_retained_buffer_manager #(
    parameter integer AB_BANKS=2,
    parameter integer C_BANKS=1,
    parameter integer BANK_W=1,
    parameter integer TAG_W=8,
    parameter integer RETAIN_INPUTS=0, // 0兼容正式版；1在release后保留A/B为READY供后续命令复用。
    parameter integer C_STREAM_CONSUMED=0 // 1仅用于完成已保证结果被消费者接收的流式后端；release后C回FREE。
)(
    input wire clk, // 所有 bank 状态事务共用的时钟；valid&&ready 在上升沿受理，不同 bank 的事务可并行。
    input wire resetn, // 低有效异步复位状态/租约/诊断，逻辑归还全部 bank；不清 RAM，须与装载器、执行器、消费者协调复位。
    // 通用事务约定：valid=1、ready=0 时保持该事务的所有请求字段稳定。
    // 带 error_o 的接口只在 valid&&ready 时解释 error_o；ready 只表示受理，不保证成功。
    // 状态权限不会自动阻断 BRAM：外层连接时须同时门控请求 valid 和返回给主机的 ready。
    // 装载器申请一个输入 bank；operand=0 为 A，1 为 B。只能在成功 begin 后写 RAM。
    input wire load_begin_valid_i, // 装载器申请输入 bank 的请求有效；等待 ready 时保持 valid、operand 和 bank。
    output wire load_begin_ready_o, // 合法且 FREE 的 bank 可受理；忙 bank 等待，越界编号也受理但报错，不能仅凭 ready 开始写。
    input wire load_begin_operand_i, // 选择输入缓冲空间：0=A，1=B；不是 bank 编号的一部分。
    input wire [BANK_W-1:0] load_begin_bank_i, // 所选 A/B 空间内待装载 bank 的编号；成功握手后 FREE->LOADING，才允许装载器写 RAM。
    output wire load_begin_error_o, // 仅 begin 握手时解释：1=bank 编号越界，状态不变；0=已取得装载权限。
    // 装载结束事务；error_i=1 表示主动放弃本次装载，不能发布 READY。
    input wire load_finish_valid_i, // 装载完成或主动放弃的请求有效；完成发布前应确保该 bank 的所有装载写已提交。
    output wire load_finish_ready_o, // 非复位时始终受理 finish，包括非法请求；事务成功与否由 load_finish_error_o 判断。
    input wire load_finish_operand_i, // 本次结束装载的输入空间：0=A，1=B；须与之前成功 begin 对应。
    input wire [BANK_W-1:0] load_finish_bank_i, // 结束装载的 bank 编号；必须当前处于 LOADING，不能结束他人 IN_USE/READY bank。
    input wire load_finish_error_i, // 装载器主动放弃标记：合法 finish 时 1=回 FREE，0=发布 READY；不是管理器的协议错误输出。
    output wire load_finish_error_o, // finish 握手时 1=编号/状态非法，不改 bank 且置粘滞诊断；0=已按 error_i 发布或放弃。
    // 命令在 acquire 前取消/被拒绝时，显式丢弃未使用的 READY 输入。
    // 只允许 READY -> FREE；不能抢走 LOADING/IN_USE。与同 bank acquire 同拍时 discard 优先。
    input wire input_discard_valid_i, // 请求丢弃尚未使用的 READY 输入，例如命令在 acquire 前被拒绝；不是取消正在计算的命令。
    output wire input_discard_ready_o, // 非复位时受理 discard；不代表一定能丢弃，须同时检查 discard_error_o。
    input wire input_discard_operand_i, // 选择丢弃哪个输入空间：0=A，1=B；须与 bank 编号一起保持到握手。
    input wire [BANK_W-1:0] input_discard_bank_i, // 待丢弃的 READY bank 编号；成功后回 FREE，不允许抢占 LOADING 或 IN_USE。
    output wire input_discard_error_o, // discard 握手时 1=越界或非 READY，状态不变；成功 discard 对同 bank 的 acquire 优先。
    // 直接连接 executor 的 ctx bank/tag 和 acquire/release；上下文在租约期间不变。
    input wire [BANK_W-1:0] req_a_bank_i, // executor 稳定 ctx 指定的 A bank；acquire/release 共用，持有租约期间不得更换。
                            req_b_bank_i, // executor 指定的 B bank；B 与 A 使用独立编号空间，必须 READY 才可成功 acquire。
                            req_c_bank_i, // executor 指定的 C bank；C 为独立输出空间，必须 FREE 才可与 A/B 一起取得。
    input wire [TAG_W-1:0] req_tag_i, // 申请/释放租约的命令身份；成功 acquire 时保存，release 时须连同三个 bank 全部匹配。
    input wire buffer_acquire_valid_i, // 原子申请所选 A/B/C 租约；等待时保持 valid 和 req_*，不会先占部分 bank。
    output wire buffer_acquire_ready_o, // 资源齐备时受理，未就绪则等待；非法编号/重复租约也受理并报错，须结合 error 判断。
    output wire buffer_acquire_error_o, // acquire 握手时 1=编号非法或已有活跃租约，全部状态不变；0=同时取得 A/B/C。
    input wire buffer_release_valid_i, // 当前命令申请归还租约；必须已停止并排空所有读响应、计算和结果写入。
    output wire buffer_release_ready_o, // 存在活跃租约且 req bank/tag 全部匹配才允许释放；身份不匹配不会握手，并记录协议错误。
    input wire buffer_release_error_i, // release 握手时 0=发布 C READY 并保存 tag，1=丢弃 C 回 FREE；两种情况都归还 A/B。
    // C 结果消费者：take 成功后才能读，return 归还后生产者才可覆盖。
    input wire c_take_valid_i, // 结果消费者申请取走一个 C READY bank；成功握手后获得读取权限，状态转 DRAINING。
    output wire c_take_ready_o, // 所选 C 已 READY 时可受理；未就绪则等待，越界也受理但报错，不能只看 ready 发读。
    input wire [BANK_W-1:0] c_take_bank_i, // 消费者待读取的 C bank 编号；等待握手时保持，成功后保留该编号用于读出及 return。
    output wire c_take_error_o, // take 握手时 1=bank 编号越界，未取得读取权限；0=成功进入 DRAINING。
    output wire [TAG_W-1:0] c_take_tag_o, // 所选 C 结果所属命令 tag；只在 take 成功握手时取用，不能将无效/空闲 bank 的旧 tag 当新结果。
    input wire c_return_valid_i, // 消费者读完并排空读响应及下游使用后归还 C；不能只因最后一条读请求发出就置位。
    output wire c_return_ready_o, // 非复位时受理 return；编号/状态是否合法仍由 c_return_error_o 给出。
    input wire [BANK_W-1:0] c_return_bank_i, // 待归还的 C bank 编号，必须处于 DRAINING；成功后变为 FREE，可由后续命令覆盖。
    output wire c_return_error_o, // return 握手时 1=越界或非 DRAINING，不改状态且置粘滞诊断；0=已归还。
    // 每位对应一个 bank。权限必须与实际写/读端口接线，状态本身不会阻断 RAM。
    output wire [AB_BANKS-1:0] a_free_o, // 每位对应一个 A bank：1=FREE，可申请装载；所有状态输出在复位期间均为 0。
                               a_loading_o, // 每位对应一个 A bank：1=LOADING，仅成功 begin 的装载方可写；外层须实际门控 RAM 接口。
                               a_ready_o, // 每位对应一个 A bank：1=装载完成待使用，可供 acquire；不等于任意读者已取得权限。
                               a_in_use_o, // 每位对应一个 A bank：1=执行器持有输入租约，禁止装载覆盖；RAM 访问仍需后端启动控制。
    output wire [AB_BANKS-1:0] b_free_o, // 每位对应一个 B bank：1=FREE，可申请下一次装载；与 A 的同编号 bank 相互独立。
                               b_loading_o, // 每位对应一个 B bank：1=LOADING，装载器可按其权限写入，不能被 acquire。
                               b_ready_o, // 每位对应一个 B bank：1=数据已发布，等待执行器申请使用；不可继续随意写入。
                               b_in_use_o, // 每位对应一个 B bank：1=已被当前租约占用，供后端读取，装载器不得覆盖。
    output wire [C_BANKS-1:0] c_free_o, // 每位对应一个 C bank：1=FREE，可供新命令申请作为输出；不要求 C 必须双缓冲。
                              c_in_use_o, // 每位对应一个 C bank：1=执行器持有写回租约，结果尚未向消费者发布。
                              c_ready_o, // 每位对应一个 C bank：1=成功命令已发布完整结果，等待消费者 take；不能被生产者覆盖。
                              c_draining_o, // 每位对应一个 C bank：1=消费者已 take、尚未 return，禁止生产者覆盖。
    output wire lease_active_o, // 当前存在一份成功 acquire 尚未 release 的 A/B/C 租约；本模块一次仅管理一份活跃计算租约。
    output reg protocol_error_o // 粘滞诊断：非法 finish/return 或错误身份 release 后置 1，仅复位清除；不是所有事务 error 的汇总。
);
    localparam [1:0] FREE=0, LOADING=1, READY=2, IN_USE=3;
    localparam [1:0] C_FREE=0,C_IN_USE=1,C_READY=2,C_DRAINING=3;
    reg [1:0] a_state_r[0:AB_BANKS-1],b_state_r[0:AB_BANKS-1];
    reg [1:0] c_state_r[0:C_BANKS-1];
    reg [TAG_W-1:0] c_tag_r[0:C_BANKS-1];
    reg lease_r;
    reg [BANK_W-1:0] owner_a_r,owner_b_r,owner_c_r;
    reg [TAG_W-1:0] owner_tag_r;
    wire begin_index_ok_w=(load_begin_bank_i<AB_BANKS);
    wire finish_index_ok_w=(load_finish_bank_i<AB_BANKS);
    wire begin_free_w=begin_index_ok_w &&
        (load_begin_operand_i ? b_state_r[load_begin_bank_i]==FREE : a_state_r[load_begin_bank_i]==FREE);
    wire finish_loading_w=finish_index_ok_w &&
        (load_finish_operand_i ? b_state_r[load_finish_bank_i]==LOADING : a_state_r[load_finish_bank_i]==LOADING);
    assign load_begin_error_o=!begin_index_ok_w;
    assign load_begin_ready_o=resetn && (!begin_index_ok_w || begin_free_w);
    assign load_finish_error_o=!finish_loading_w;
    assign load_finish_ready_o=resetn; // 无效 finish 消费并报错，不改变任何 bank。
    wire acquire_index_ok_w=(req_a_bank_i<AB_BANKS) && (req_b_bank_i<AB_BANKS) && (req_c_bank_i<C_BANKS);
    wire discard_index_ok_w=(input_discard_bank_i<AB_BANKS);
    wire discard_ready_state_w=discard_index_ok_w &&
        (input_discard_operand_i ? b_state_r[input_discard_bank_i]==READY : a_state_r[input_discard_bank_i]==READY);
    assign input_discard_ready_o=resetn; // 非 READY/越界也消费并报错，不修改状态。
    assign input_discard_error_o=!discard_ready_state_w;
    wire discard_fire_w=input_discard_valid_i && input_discard_ready_o && !input_discard_error_o;
    wire discard_conflict_w=discard_fire_w &&
        (input_discard_operand_i ? input_discard_bank_i==req_b_bank_i : input_discard_bank_i==req_a_bank_i);
    wire available_w=acquire_index_ok_w && a_state_r[req_a_bank_i]==READY &&
        b_state_r[req_b_bank_i]==READY && c_state_r[req_c_bank_i]==C_FREE && !discard_conflict_w;
    assign buffer_acquire_error_o=!acquire_index_ok_w || lease_r;
    assign buffer_acquire_ready_o=resetn && (buffer_acquire_error_o || available_w);
    wire acquire_fire_w=buffer_acquire_valid_i && buffer_acquire_ready_o && !buffer_acquire_error_o;
    wire owner_match_w=lease_r && req_a_bank_i==owner_a_r && req_b_bank_i==owner_b_r &&
        req_c_bank_i==owner_c_r && req_tag_i==owner_tag_r;
    assign buffer_release_ready_o=resetn && owner_match_w;
    wire release_fire_w=buffer_release_valid_i && buffer_release_ready_o;
    wire take_index_ok_w=(c_take_bank_i<C_BANKS);
    wire return_index_ok_w=(c_return_bank_i<C_BANKS);
    assign c_take_error_o=!take_index_ok_w;
    assign c_take_ready_o=resetn && (!take_index_ok_w || c_state_r[c_take_bank_i]==C_READY);
    assign c_take_tag_o=take_index_ok_w ? c_tag_r[c_take_bank_i] : {TAG_W{1'b0}};
    assign c_return_error_o=!(return_index_ok_w && c_state_r[c_return_bank_i]==C_DRAINING);
    assign c_return_ready_o=resetn;
    assign lease_active_o=resetn && lease_r;
    // owner/tag 宽数据只在有效事务时更新，无复位网络。
    always @(posedge clk) begin
        if(acquire_fire_w) begin
            owner_a_r<=req_a_bank_i; owner_b_r<=req_b_bank_i;
            owner_c_r<=req_c_bank_i; owner_tag_r<=req_tag_i;
        end
        if(release_fire_w && !buffer_release_error_i) c_tag_r[owner_c_r]<=owner_tag_r;
    end
    integer i;
    always @(posedge clk or negedge resetn) begin
        if(!resetn) begin
            lease_r<=0; protocol_error_o<=0;
            for(i=0;i<AB_BANKS;i=i+1) begin a_state_r[i]<=FREE; b_state_r[i]<=FREE; end
            for(i=0;i<C_BANKS;i=i+1) c_state_r[i]<=C_FREE;
        end else begin
            // 各事务依据旧状态判断。同 bank 不允许同拍跨两级；不同 bank 可并行。
            if(load_begin_valid_i && load_begin_ready_o && !load_begin_error_o) begin
                if(load_begin_operand_i) b_state_r[load_begin_bank_i]<=LOADING;
                else a_state_r[load_begin_bank_i]<=LOADING;
            end
            if(load_finish_valid_i && load_finish_ready_o) begin
                if(load_finish_error_o) protocol_error_o<=1;
                else if(load_finish_operand_i) b_state_r[load_finish_bank_i]<=load_finish_error_i?FREE:READY;
                else a_state_r[load_finish_bank_i]<=load_finish_error_i?FREE:READY;
            end
            if(discard_fire_w) begin
                if(input_discard_operand_i) b_state_r[input_discard_bank_i]<=FREE;
                else a_state_r[input_discard_bank_i]<=FREE;
            end
            if(acquire_fire_w) begin
                a_state_r[req_a_bank_i]<=IN_USE; b_state_r[req_b_bank_i]<=IN_USE;
                c_state_r[req_c_bank_i]<=C_IN_USE; lease_r<=1;
            end
            if(buffer_release_valid_i && !owner_match_w) protocol_error_o<=1;
            if(release_fire_w) begin
                a_state_r[owner_a_r]<=RETAIN_INPUTS?READY:FREE; b_state_r[owner_b_r]<=RETAIN_INPUTS?READY:FREE;
                c_state_r[owner_c_r]<=(buffer_release_error_i || C_STREAM_CONSUMED)?C_FREE:C_READY;
                lease_r<=0;
            end
            if(c_take_valid_i && c_take_ready_o && !c_take_error_o) c_state_r[c_take_bank_i]<=C_DRAINING;
            if(c_return_valid_i && c_return_ready_o) begin
                if(c_return_error_o) protocol_error_o<=1;
                else c_state_r[c_return_bank_i]<=C_FREE;
            end
        end
    end
    genvar b;
    generate for(b=0;b<AB_BANKS;b=b+1) begin:g_ab_status
        assign a_free_o[b]=resetn && a_state_r[b]==FREE;
        assign a_loading_o[b]=resetn && a_state_r[b]==LOADING;
        assign a_ready_o[b]=resetn && a_state_r[b]==READY;
        assign a_in_use_o[b]=resetn && a_state_r[b]==IN_USE;
        assign b_free_o[b]=resetn && b_state_r[b]==FREE;
        assign b_loading_o[b]=resetn && b_state_r[b]==LOADING;
        assign b_ready_o[b]=resetn && b_state_r[b]==READY;
        assign b_in_use_o[b]=resetn && b_state_r[b]==IN_USE;
    end
    for(b=0;b<C_BANKS;b=b+1) begin:g_c_status
        assign c_free_o[b]=resetn && c_state_r[b]==C_FREE;
        assign c_in_use_o[b]=resetn && c_state_r[b]==C_IN_USE;
        assign c_ready_o[b]=resetn && c_state_r[b]==C_READY;
        assign c_draining_o[b]=resetn && c_state_r[b]==C_DRAINING;
    end endgenerate
    // synthesis translate_off
    initial if(AB_BANKS<1 || C_BANKS<1 || BANK_W<1 || TAG_W<1 ||
        $clog2(AB_BANKS)>BANK_W || $clog2(C_BANKS)>BANK_W) $fatal(1,"Invalid buffer manager parameters");
    // synthesis translate_on
endmodule

