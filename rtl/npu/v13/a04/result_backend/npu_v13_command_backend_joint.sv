// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 二级联合：正式FIFO/dispatcher -> 正式executor/scheduler -> panel适配 -> packet后端。
// 命令、存储所有权、每拍数据通路彼此解耦，不另放一个与executor重复的M/N调度器。
// 当前能力：已装载panel内的INT8 GEMM，mode00/layout0/op_cfg0，INT32坐标结果流。
// CONV、跨K的PSUM、后处理及DDR由后续批次加入；当前不支持的字段必须返回错误。
// A/B base单位是128bit BRAM word；C当前输出坐标尚无地址生成，因此非零C base明确拒绝。
module npu_v13_command_backend_joint #(
    parameter integer LOAD_W=128,
    parameter integer MAX_MN=128,MAX_K=512,TOTAL_SLOTS=64,CAPTURE_SLOTS=4,FIFO_DEPTH=8,
    parameter integer AW=$clog2((MAX_MN/16)*MAX_K),UW=$clog2(TOTAL_SLOTS+1)
)(
    input wire clk,resetn, // 整条命令/存储/计算链协调复位，复位取消所有排队和在途工作。
    input wire cmd_valid_i, // 整条命令有效，等待ready期间所有cmd_*字段保持。
    output wire cmd_ready_o, // FIFO入口有空间；不要求此时输入bank已READY。
    input wire [1:0] cmd_opcode_i,cmd_cluster_mode_i, // opcode0=GEMM/1=CONV，mode0/1/2为核原有模式。
    input wire [2:0] cmd_layout_i, // 分组布局；第一批只接受mode00/layout0执行。
    input wire [15:0] cmd_m_i,cmd_n_i,cmd_k_i,cmd_tag_i, // 动态实际尺寸和命令身份。
    input wire [31:0] cmd_a_base_i,cmd_b_base_i,cmd_c_base_i, // A/B word地址；C base当前必须0。
    input wire cmd_a_bank_i,cmd_b_bank_i,cmd_c_bank_i, // 三个独立地址空间的bank编号0/1。
    input wire [31:0] cmd_op_cfg_i, // 保留给CONV/postop；当前非零报执行错误而非静默忽略。
    output wire rsp_valid_o, // 命令退休响应，非计算tile的valid。
    input wire rsp_ready_i, // 响应消费者可接收，反压时tag/status稳定。
    output wire [15:0] rsp_tag_o, // 一一对应已入队命令。
    output wire [2:0] rsp_status_o, // 0成功/1非法opcode/2非法mode/3配置错/4执行错/5完成tag错。
    input wire load_begin_valid_i, // FREE输入bank的装载申请，可与另一bank计算重叠。
    output wire load_begin_ready_o,load_begin_error_o, // 成功握手后才允许写目标bank。
    input wire load_begin_operand_i,load_begin_bank_i, // operand0=A/1=B，bank0/1。
    input wire load_valid_i, // LOAD_W位搬运beat；64位在目标bank本地拼成128位。
    output wire load_ready_o, // 目标LOADING且地址合法才接受。
    input wire load_operand_i,load_bank_i, // 当前装载数据目标。
    input wire [AW+(LOAD_W==64)-1:0] load_addr_i, // LOAD_W-bit panel beat地址，不是DDR字节地址。
    input wire [LOAD_W-1:0] load_data_i, // 窄载荷保持到bank叶节点；计算读口仍128位。
    input wire load_finish_valid_i, // 写入完毕/放弃通知；不会越过BRAM写流水。
    output wire load_finish_ready_o,load_finish_error_o, // 握手确认发布READY或报告非法finish。
    input wire load_finish_operand_i,load_finish_bank_i,load_finish_error_i, // finish目标及主动放弃标记。
    input wire discard_valid_i, // 重装旧panel前显式归还READY输入，不能抢占使用中的bank。
    output wire discard_ready_o,discard_error_o, // discard受理与合法性分开报告。
    input wire discard_operand_i,discard_bank_i, // 丢弃目标。
    input wire allow_beat_i, // 为验证合法气泡而暂停新BRAM请求，已发响应仍完整进入核。
    output wire [3:0] c_valid_o, // 四个独立P4 INT32结果流，必须按坐标而非扫描顺序消费。
    input wire [3:0] c_ready_i, // 下游独立反压；无容量时禁止启动新packet。
    output wire [511:0] c_data_o, // 每组128bit=四个INT32，组0在低位。
    output wire [15:0] c_keep_o, // 每组4bit有效元素标记，包括全0的尾块空行。
    output wire [63:0] c_m_o,c_n_o,c_tag_o, // 每组16bit，输出行/首列/tag。
    output wire [3:0] c_tile_last_o, // 每物理tile第四字，真正握手才归还预约。
    output wire busy_o, // 队列、执行上下文、未消费响应任一存在即忙。
    output wire [$clog2(FIFO_DEPTH+1)-1:0] queue_level_o, // FIFO物理占用，包含预取级。
    output wire [3:0] retained_o,loading_o,in_use_o, // {B1,B0,A1,A0}的输入状态。
    output wire [1:0] c_free_o,c_in_use_o,active_mode_o, // C目的地租约状态及真实核模式。
    output wire input_beat_o,packet_issue_o, // 性能计数事件，不作为控制握手。
    output wire [4*UW-1:0] slots_used_o, // 四组预约尚未最终消费的tile数。
    output wire [15:0] pending_o,outstanding_o, // 在途/未退休守恒计数。
    output wire error_o // 后端/manager协议故障；合法拒绝命令仅反映在rsp_status。
);
    // dispatcher与executor之间是完整命令事务，ctx只在executor中保存一份。
    wire ev,er,edv,edr,ede,dispatch_busy,exec_busy;
    wire [1:0] eop,emode;
    wire [2:0] elayout;
    wire [15:0] em,en,ek,et,edt;
    wire [31:0] ea,eb,ec,eopcfg;
    wire eab,ebb,ecb;
    wire cfgv,cfgr,cfge,core_idle;
    wire [1:0] cfgmode;
    npu_v13_command_queue_dispatcher #(.TAG_W(16),.FIFO_DEPTH(FIFO_DEPTH)) u_dispatcher(
        .clk(clk),.resetn(resetn),.cmd_valid_i(cmd_valid_i),.cmd_ready_o(cmd_ready_o),
        .cmd_opcode_i(cmd_opcode_i),.cmd_cluster_mode_i(cmd_cluster_mode_i),.cmd_layout_i(cmd_layout_i),
        .cmd_m_i(cmd_m_i),.cmd_n_i(cmd_n_i),.cmd_k_i(cmd_k_i),.cmd_tag_i(cmd_tag_i),
        .cmd_a_base_i(cmd_a_base_i),.cmd_b_base_i(cmd_b_base_i),.cmd_c_base_i(cmd_c_base_i),
        .cmd_a_bank_i(cmd_a_bank_i),.cmd_b_bank_i(cmd_b_bank_i),.cmd_c_bank_i(cmd_c_bank_i),.cmd_op_cfg_i(cmd_op_cfg_i),
        .cmd_rsp_valid_o(rsp_valid_o),.cmd_rsp_ready_i(rsp_ready_i),.cmd_rsp_tag_o(rsp_tag_o),.cmd_rsp_status_o(rsp_status_o),
        .exec_cmd_valid_o(ev),.exec_cmd_ready_i(er),.exec_cmd_opcode_o(eop),.exec_cmd_cluster_mode_o(emode),.exec_cmd_layout_o(elayout),
        .exec_cmd_m_o(em),.exec_cmd_n_o(en),.exec_cmd_k_o(ek),.exec_cmd_tag_o(et),
        .exec_cmd_a_base_o(ea),.exec_cmd_b_base_o(eb),.exec_cmd_c_base_o(ec),
        .exec_cmd_a_bank_o(eab),.exec_cmd_b_bank_o(ebb),.exec_cmd_c_bank_o(ecb),.exec_cmd_op_cfg_o(eopcfg),
        .exec_done_valid_i(edv),.exec_done_ready_o(edr),.exec_done_tag_i(edt),.exec_done_error_i(ede),
        .cluster_cfg_valid_o(cfgv),.cluster_cfg_mode_o(cfgmode),.cluster_cfg_ready_i(cfgr),.cluster_cfg_error_i(cfge),.cluster_active_mode_i(active_mode_o),
        .queue_empty_o(),.queue_full_o(),.queue_level_o(queue_level_o),.dispatcher_busy_o(dispatch_busy),.exec_active_o());
    wire [1:0] op,mode;
    wire [2:0] layout;
    wire [15:0] m,n,k,tag;
    wire [31:0] abase,bbase,cbase,opcfg;
    wire abank,bbank,cbank,owned,acqv,acqr,acqe,relv,relr,rele,prep,prepr,prepe,start,cancel,scheduled;
    wire bv,br,adapter_idle,adapter_error;
    wire [15:0] bm,bn;
    wire donev,doner,donee,backend_busy,backend_error;
    wire [15:0] donetag;
    reg cancel_r; // 先声明后使用，避免工具把前向引用猜成隐式wire。
    npu_v13_job_executor #(.TAG_W(16)) u_executor(
        .clk(clk),.resetn(resetn),.exec_cmd_valid_i(ev),.exec_cmd_ready_o(er),
        .exec_cmd_opcode_i(eop),.exec_cmd_cluster_mode_i(emode),.exec_cmd_layout_i(elayout),
        .exec_cmd_m_i(em),.exec_cmd_n_i(en),.exec_cmd_k_i(ek),.exec_cmd_tag_i(et),
        .exec_cmd_a_base_i(ea),.exec_cmd_b_base_i(eb),.exec_cmd_c_base_i(ec),
        .exec_cmd_a_bank_i(eab),.exec_cmd_b_bank_i(ebb),.exec_cmd_c_bank_i(ecb),.exec_cmd_op_cfg_i(eopcfg),
        .exec_done_valid_o(edv),.exec_done_ready_i(edr),.exec_done_tag_o(edt),.exec_done_error_o(ede),
        .ctx_valid_o(),.ctx_opcode_o(op),.ctx_m_o(m),.ctx_n_o(n),.ctx_k_o(k),.ctx_cluster_mode_o(mode),.ctx_layout_o(layout),
        .ctx_a_base_o(abase),.ctx_b_base_o(bbase),.ctx_c_base_o(cbase),.ctx_a_bank_o(abank),.ctx_b_bank_o(bbank),.ctx_c_bank_o(cbank),
        .ctx_op_cfg_o(opcfg),.ctx_tag_o(tag),.buffers_owned_o(owned),
        .buffer_acquire_valid_o(acqv),.buffer_acquire_ready_i(acqr),.buffer_acquire_error_i(acqe),
        .buffer_release_valid_o(relv),.buffer_release_ready_i(relr),.buffer_release_error_o(rele),
        .backend_prepare_valid_o(prep),.backend_prepare_ready_i(prepr && !backend_busy),.backend_prepare_error_i(prepe || cbase!=0),
        .job_start_o(start),.job_cancel_o(cancel),.tile_batch_valid_o(bv),.tile_batch_ready_i(br),
        .tile_batch_m_o(),.tile_batch_n_o(),.tile_batch_k_o(),.tile_batch_m_base_o(bm),.tile_batch_n_base_o(bn),
        .tile_batch_cluster_mode_o(),.tile_batch_layout_o(),.tile_batch_cmd_first_o(),.tile_batch_cmd_last_o(),.tile_batch_tag_o(),
        .schedule_finished_o(scheduled),.job_complete_valid_i(donev),.job_complete_ready_o(doner),.job_complete_tag_i(donetag),
        .job_complete_error_i(donee || adapter_error || cancel_r),.busy_o(exec_busy));
    // cancel为scheduler异常路径；不强停无ready核，等待已发工作排空后报告错误。
    always @(posedge clk) begin
        if(!resetn || start) cancel_r<=0;
        else if(cancel) cancel_r<=1;
    end
    wire dv,dr;
    wire [AW-1:0] da,db,ra,rb;
    wire [15:0] dk,dm,dn;
    wire [4:0] rows,cols;
    npu_v13_exec_panel_adapter #(.MAX_MN(MAX_MN),.MAX_K(MAX_K)) u_adapter(
        .clk(clk),.resetn(resetn),.prepare_valid_i(prep),.prepare_ready_o(prepr),.prepare_error_o(prepe),
        .ctx_opcode_i(op),.ctx_mode_i(mode),.ctx_layout_i(layout),.ctx_op_cfg_i(opcfg),
        .ctx_m_i(m),.ctx_n_i(n),.ctx_k_i(k),.ctx_a_base_i(abase),.ctx_b_base_i(bbase),
        .batch_valid_i(bv),.batch_ready_o(br),.batch_m_i(bm),.batch_n_i(bn),
        .desc_valid_o(dv),.desc_ready_i(dr),.desc_a_o(da),.desc_b_o(db),.desc_k_o(dk),.desc_m_o(dm),.desc_n_o(dn),
        .desc_rows_o(rows),.desc_cols_o(cols),.idle_o(adapter_idle),.protocol_error_o(adapter_error));
    wire rd,rv,lease,memory_error;
    wire [127:0] ram_a,ram_b;
    npu_v13_managed_panel_store #(.LOAD_W(LOAD_W),.MAX_MN(MAX_MN),.MAX_K(MAX_K)) u_memory(
        .clk(clk),.resetn(resetn),.load_begin_valid_i(load_begin_valid_i),.load_begin_ready_o(load_begin_ready_o),.load_begin_error_o(load_begin_error_o),
        .load_begin_operand_i(load_begin_operand_i),.load_begin_bank_i(load_begin_bank_i),
        .load_valid_i(load_valid_i),.load_ready_o(load_ready_o),.load_operand_i(load_operand_i),.load_bank_i(load_bank_i),
        .load_addr_i(load_addr_i),.load_data_i(load_data_i),.load_finish_valid_i(load_finish_valid_i),
        .load_finish_ready_o(load_finish_ready_o),.load_finish_error_o(load_finish_error_o),
        .load_finish_operand_i(load_finish_operand_i),.load_finish_bank_i(load_finish_bank_i),.load_finish_error_i(load_finish_error_i),
        .discard_valid_i(discard_valid_i),.discard_ready_o(discard_ready_o),.discard_error_o(discard_error_o),
        .discard_operand_i(discard_operand_i),.discard_bank_i(discard_bank_i),
        .acquire_valid_i(acqv),.acquire_ready_o(acqr),.acquire_error_o(acqe),.release_valid_i(relv),.release_ready_o(relr),.release_error_i(rele),
        .req_a_bank_i(abank),.req_b_bank_i(bbank),.req_c_bank_i(cbank),.req_tag_i(tag),
        .rd_valid_i(rd),.rd_a_addr_i(ra),.rd_b_addr_i(rb),.ram_valid_o(rv),.ram_a_o(ram_a),.ram_b_o(ram_b),
        .retained_o(retained_o),.loading_o(loading_o),.in_use_o(in_use_o),.c_free_o(c_free_o),.c_in_use_o(c_in_use_o),.lease_active_o(lease),.error_o(memory_error));
    npu_v13_packet_backend #(.AW(AW),.MAX_K(MAX_K),.TOTAL_SLOTS(TOTAL_SLOTS),.CAPTURE_SLOTS(CAPTURE_SLOTS)) u_backend(
        .clk(clk),.resetn(resetn),.cfg_valid_i(cfgv),.cfg_mode_i(cfgmode),.cfg_ready_o(cfgr),.cfg_error_o(cfge),.active_mode_o(active_mode_o),.cluster_idle_o(core_idle),
        .start_i(start),.tag_i(tag),.buffers_owned_i(owned && lease),
        // 最后batch可能仍留在adapter的寄存槽中；必须同时确认它已经交给issue。
        .schedule_finished_i(scheduled && adapter_idle),.desc_valid_i(dv),.desc_ready_o(dr),
        .desc_a_i(da),.desc_b_i(db),.desc_k_i(dk),.desc_m_i(dm),.desc_n_i(dn),.desc_rows_i(rows),.desc_cols_i(cols),
        .allow_beat_i(allow_beat_i),.rd_valid_o(rd),.rd_a_addr_o(ra),.rd_b_addr_o(rb),.ram_valid_i(rv),.ram_a_i(ram_a),.ram_b_i(ram_b),
        .c_valid_o(c_valid_o),.c_ready_i(c_ready_i),.c_data_o(c_data_o),.c_keep_o(c_keep_o),.c_m_o(c_m_o),.c_n_o(c_n_o),.c_tag_o(c_tag_o),.c_tile_last_o(c_tile_last_o),
        .done_valid_o(donev),.done_ready_i(doner),.done_tag_o(donetag),.done_error_o(donee),.busy_o(backend_busy),
        .input_beat_o(input_beat_o),.packet_issue_o(packet_issue_o),.reserve_wait_o(),.slots_used_o(slots_used_o),.pending_o(pending_o),.outstanding_o(outstanding_o),.error_o(backend_error));
    assign busy_o=dispatch_busy || exec_busy || backend_busy;
    assign error_o=backend_error || memory_error || adapter_error || cancel_r;
    // synthesis translate_off
    always @(posedge clk) if(resetn) begin
        if(start && (!owned || !lease || active_mode_o!=0)) $fatal(1,"start without owned banks/actual mode00");
        if(relv && relr && (backend_busy || pending_o!=0 || outstanding_o!=0 || !adapter_idle || rd || rv))
            $fatal(1,"bank released before backend drained");
        if(cfgv && (backend_busy || owned)) $fatal(1,"mode changed during owned job");
    end
    // synthesis translate_on
endmodule
