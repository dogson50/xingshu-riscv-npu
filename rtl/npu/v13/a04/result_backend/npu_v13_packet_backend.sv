// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 可复用的计算数据面：描述符 -> 预约 -> BRAM预取 -> 原runtime核 -> 四组结果缓存。
// 不管理命令FIFO或bank所有权，不解释DDR地址；上层负责发布已就绪的A/B panel。
// 第一批只接16x16模式，保留原核实现；四P4输出是片上带宽，不是DDR接口。
module npu_v13_packet_backend #(
    parameter integer AW=12, MAX_K=512, TOTAL_SLOTS=32, CAPTURE_SLOTS=4,
    parameter integer UW=$clog2(TOTAL_SLOTS+1)
)(
    input wire clk,resetn, // 同一计算域，复位同时取消所有已预约事务。
    input wire cfg_valid_i, // 正式dispatcher的模式请求，直接到真实runtime核。
    input wire [1:0] cfg_mode_i, // 第一批计算仅用00；其他模式可配置但prepare拒绝执行。
    output wire cfg_ready_o,cfg_error_o, // 真实核的配置应答，不能用常量模拟成功。
    output wire [1:0] active_mode_o, // 真实核当前生效模式。
    output wire cluster_idle_o, // 真实核在途状态，不等于整个后端结果已排空。
    input wire start_i, // 新命令开始；busy=0时单拍，不能与首个描述符同拍提交。
    input wire [15:0] tag_i, // start时采样，直到完成回应保持任务身份。
    input wire buffers_owned_i, // 上层保证本任务使用的A/B不会被覆盖。
    input wire schedule_finished_i, // 最后一个描述符已握手，不等于结果完成。
    input wire desc_valid_i, // 子块描述符有效，等待ready期间全部字段稳定。
    output wire desc_ready_o, // 本地issue描述符暂存空闲。
    input wire [AW-1:0] desc_a_i,desc_b_i, // A/B panel word起址。
    input wire [15:0] desc_k_i,desc_m_i,desc_n_i, // 本packet K及输出子块起始坐标。
    input wire [4:0] desc_rows_i,desc_cols_i, // 动态实际行列数1..16。
    input wire allow_beat_i, // 可暂停发起新BRAM读；已发请求的响应不可丢弃。
    output wire rd_valid_o, // 一次同步读取A/B各128bit；读响应固定两拍。
    output wire [AW-1:0] rd_a_addr_o,rd_b_addr_o, // 不含bank选择，bank由上层租约固定。
    input wire ram_valid_i, // 与固定两拍响应一致，不支持此处的可变延迟DDR响应。
    input wire [127:0] ram_a_i,ram_b_i, // A的16行、B的16列，低编号在低8bit。
    output wire [3:0] c_valid_o, // 四个独立P4结果端口。
    input wire [3:0] c_ready_i, // 各组独立反压，数据与元数据一起保持。
    output wire [511:0] c_data_o, // 每组128bit=4个INT32，组0在低位。
    output wire [15:0] c_keep_o, // 每组4个元素有效位，整字keep=0也要握手。
    output wire [63:0] c_m_o,c_n_o,c_tag_o, // 每组16bit：行、首列、命令tag。
    output wire [3:0] c_tile_last_o, // 每tile第四行；用于归还预约，不是job last。
    output wire done_valid_o, // 所有在途计算及结果均被最终消费者接收。
    input wire done_ready_i, // 上层接收完成，允许下一任务。
    output wire [15:0] done_tag_o, // 与start采样的tag一致。
    output wire done_error_o,busy_o, // 完成错误及命令生命周期状态。
    output wire input_beat_o,packet_issue_o,reserve_wait_o, // 实验性能事件，不当作控制握手。
    output wire [4*UW-1:0] slots_used_o, // 每组预约未退休的tile数。
    output wire [15:0] pending_o,outstanding_o, // 返回前/最终消费前的tile守恒计数。
    output wire error_o // 错误汇总；协议错误要求整个数据面协调复位。
);
    reg [15:0] tag_r;
    always @(posedge clk) if(start_i) tag_r<=tag_i;
    wire reserve,pv,pr,issue_idle,issue_error,feeder_idle;
    wire [3:0] reserve_ready,retire,empty,island_error;
    wire [15:0] mask,rm,rn,rt,pk;
    wire [AW-1:0] pa,pb;
    wire [4:0] prows,pcols;
    wire issue_ready;
    assign desc_ready_o=issue_ready && busy_o && !done_valid_o;
    npu_v13_packet_issue_ctrl #(.AW(AW),.MAX_K(MAX_K)) u_issue(
        .clk(clk),.resetn(resetn),.desc_valid_i(desc_valid_i && busy_o && !done_valid_o),.desc_ready_o(issue_ready),
        .desc_a_i(desc_a_i),.desc_b_i(desc_b_i),.desc_k_i(desc_k_i),
        .desc_rows_i(desc_rows_i),.desc_cols_i(desc_cols_i),.desc_m_i(desc_m_i),.desc_n_i(desc_n_i),.desc_tag_i(tag_r),
        .buffers_owned_i(buffers_owned_i),.reserve_valid_o(reserve),.reserve_ready_i(reserve_ready),
        .reserve_mask_o(mask),.reserve_m_o(rm),.reserve_n_o(rn),.reserve_tag_o(rt),
        .packet_valid_o(pv),.packet_ready_i(pr),.packet_a_o(pa),.packet_b_o(pb),.packet_k_o(pk),
        .packet_rows_o(prows),.packet_cols_o(pcols),.idle_o(issue_idle),.error_o(issue_error));
    assign packet_issue_o=pv && pr;
    assign reserve_wait_o=!issue_idle && !pv && !reserve;
    // feeder只见到已经预约的packet；核没有ready，故不能将下游反压传播到在途结果。
    wire cv,ci,cl;
    wire [4:0] cr,cc;
    wire [127:0] ca,cb;
    panel_feeder_exp #(.G(16),.S(1),.WORD_W(128),.AW(AW),.KW($clog2(MAX_K+1))) u_feeder(
        .clk(clk),.resetn(resetn),.packet_valid_i(pv),.packet_ready_o(pr),.a_base_i(pa),.b_base_i(pb),
        .steps_i(pk),.last_lanes_i(3'd1),.rows_i(prows),.cols_i(pcols),.allow_beat_i(allow_beat_i),
        .rd_valid_o(rd_valid_o),.rd_a_addr_o(rd_a_addr_o),.rd_b_addr_o(rd_b_addr_o),
        .ram_valid_i(ram_valid_i),.ram_a_i(ram_a_i),.ram_b_i(ram_b_i),
        .valid_o(cv),.init_o(ci),.last_o(cl),.rows_o(cr),.cols_o(cc),.a_o(ca),.b_o(cb),.idle_o(feeder_idle));
    assign input_beat_o=cv;
    wire [15:0] result_valid;
    wire [15:0] native_reserve,native_ready,row_valid,row_ready,row_error;
    wire [2047:0] row_data;
    wire [63:0] row_keep;
    wire [31:0] row_index;
    wire [767:0] row_meta;
    wire core_error;
    npu_v22_runtime_panel_bridge #(.CAPTURE_SLOTS(CAPTURE_SLOTS)) u_compute(.clk(clk),.resetn(resetn),
        .cfg_valid_i(cfg_valid_i),.cfg_mode_i(cfg_mode_i),.cfg_ready_o(cfg_ready_o),.cfg_error_o(cfg_error_o),
        .active_mode_o(active_mode_o),.cluster_idle_o(cluster_idle_o),.valid_i(cv),.init_i(ci),.last_i(cl),
        .rows_i(cr),.cols_i(cc),.a_i(ca),.b_i(cb),.valid_o(result_valid),
        .reserve_valid_i(native_reserve),.reserve_ready_o(native_ready),.reserve_meta_i({rt,rm,rn}),
        .row_valid_o(row_valid),.row_ready_i(row_ready),.row_data_o(row_data),.row_keep_o(row_keep),
        .row_index_o(row_index),.row_meta_o(row_meta),.row_error_o(row_error),.error_o(core_error));
    genvar g;
    generate for(g=0;g<4;g=g+1) begin:G_ISLAND
        npu_v22_result_island #(.TILE_ROW(g),.TOTAL_SLOTS(TOTAL_SLOTS),.CAPTURE_SLOTS(CAPTURE_SLOTS)) u_island(
            .clk(clk),.resetn(resetn),.reserve_valid_i(reserve),.reserve_ready_o(reserve_ready[g]),
            .reserve_mask_i(mask[g*4+:4]),.reserve_tag_i(rt),.reserve_m_i(rm),.reserve_n_i(rn),
            .native_reserve_o(native_reserve[g*4+:4]),.capture_ready_i(native_ready[g*4+:4]),
            .row_valid_i(row_valid[g*4+:4]),.row_ready_o(row_ready[g*4+:4]),.row_data_i(row_data[g*512+:512]),
            .row_keep_i(row_keep[g*16+:16]),.row_index_i(row_index[g*8+:8]),.row_meta_i(row_meta[g*192+:192]),.row_error_i(row_error[g*4+:4]),
            .out_valid_o(c_valid_o[g]),.out_ready_i(c_ready_i[g]),.out_data_o(c_data_o[g*128+:128]),
            .out_keep_o(c_keep_o[g*4+:4]),.out_tag_o(c_tag_o[g*16+:16]),.out_m_o(c_m_o[g*16+:16]),.out_n_o(c_n_o[g*16+:16]),
            .out_tile_last_o(c_tile_last_o[g]),.retire_o(retire[g]),.used_o(slots_used_o[g*UW+:UW]),.empty_o(empty[g]),.error_o(island_error[g]));
    end endgenerate
    wire backend_error=issue_error || core_error || |island_error;
    assign error_o=backend_error || done_error_o;
    // 三个事件独立计账：预约、核返回、消费者接收第四字；任何一个都不能代替另一个。
    // 最大在途tile数由四组物理预约容量决定，与运行时M/N/K或累加位宽无关。
    // 64槽/组时仅需9bit；输出仍零扩展为16bit，外部调试接口保持不变。
    localparam integer CW=$clog2(4*TOTAL_SLOTS+1);
    wire [CW-1:0] pending_count,outstanding_count;
    assign pending_o=pending_count;
    assign outstanding_o=outstanding_count;
    // p9：先对原始位图判有无事件，避免mask→popcount→判零→done的组合旁路。
    // popcount在u_events内部仅送计数寄存器；三事件仍统一延迟一拍。
    // pending/outstanding是调试账本，现比物理事件晚一拍，不作为槽池预约控制。
    wire [4:0] reserve_event_r,capture_event_r;
    wire [2:0] retire_event_r;
    wire event_now;
    npu_v13_completion_event_slice u_events(.clk(clk),.resetn(resetn),.enable_i(busy_o && !done_valid_o),
        .reserve_valid_i(reserve),.reserve_mask_i(mask),.capture_mask_i(result_valid),.retire_mask_i(retire),
        .reserve_count_o(reserve_event_r),.capture_count_o(capture_event_r),.retire_count_o(retire_event_r),.event_now_o(event_now));
    // 完成器原有“当前输入事件为0”检查保护已寄存事件；event_now另外保护尚未寄存的本拍事件。
    // 即使外部empty提前为1，也不能在新事件尚未入账时发布done；reset清空这一级。
    npu_v13_completion_tracker #(.CW(CW)) u_completion(.clk(clk),.resetn(resetn),.start_i(start_i),.tag_i(tag_i),
        .reserve_count_i(reserve_event_r),.capture_count_i(capture_event_r),.retire_count_i(retire_event_r),
        .schedule_finished_i(schedule_finished_i),.issue_idle_i(issue_idle),.feeder_idle_i(feeder_idle),
        .results_empty_i((&empty) && !event_now),.backend_error_i(backend_error),.done_valid_o(done_valid_o),.done_ready_i(done_ready_i),
        .done_tag_o(done_tag_o),.done_error_o(done_error_o),.busy_o(busy_o),.pending_o(pending_count),.outstanding_o(outstanding_count));
endmodule
