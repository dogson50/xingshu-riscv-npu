// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 实验用单物理 tile 收数器。先预约容量，各 PE 按自身完成事件写本地槽，再按 P4 行输出。
// 槽按 packet 首次启动预约，包括尚未返回的结果；不能只看已经返回的 FIFO 占用。
// 数据采用分片异步读 LUTRAM 候选；C 写侧有 ready，停顿期间地址/数据/掩码不变。
// C 地址单位为 P*32-bit 字，每个结果固定占 16/P 字；尾块仍占完整槽，keep 标示有效元素。
module npu_v23_native_collector #(
    parameter integer P=4,
    parameter integer FAST_CAPTURE=0, // 实验对照：寄存 pending 非空，缩短结果写使能路径。
    parameter integer SLOTS=16,
    parameter integer ADDR_W=10,
    parameter integer TAG_W=8,
    parameter integer PTR_W=(SLOTS>1?$clog2(SLOTS):1),
    parameter integer COUNT_W=$clog2(SLOTS+1)
)(
    input wire clk, // 时钟。
    input wire resetn, // 清空预约/有效状态，不擦数据 RAM。
    input wire reserve_valid_i, // 新 packet 预约；只有 valid&&ready 才允许相应 feeder 启动。
    output wire reserve_ready_o, // 尚有完整结果槽，包含在途结果的容量保护。
    input wire [ADDR_W-1:0] reserve_base_i, // 本结果在 C 分片中的起始宽字地址。
    input wire [TAG_W-1:0] reserve_tag_i, // 描述符关联标识，不参与数学计算。
    input wire result_valid_i, // 计算核无反压的结果事件，必须有此前的预约。
    input wire [15:0] pe_valid_i, // 每个 PE 用独立游标写 FIFO 顺序的预约槽。
    input wire [511:0] result_data_i, // 仅 tile 内部原始 PE 结果；各 32-bit 片段只在对应 pe_valid_i 时有效。
    input wire [3:0] result_shape_i, // {rows_m1,cols_m1}，与结果同拍。
    output wire wr_valid_o, // 当前 C 写请求有效，停顿时保持。
    input wire wr_ready_i, // C 写入许可；只在握手时推进分拍写回。
    output wire [ADDR_W-1:0] wr_addr_o, // C 宽字地址。
    output wire [P*32-1:0] wr_data_o, // P 个 32-bit 结果，低编号元素在低位。
    output wire [P-1:0] wr_keep_o, // 每个结果元素的逻辑有效位；C 仍可存尾部无效数据。
    output wire [TAG_W-1:0] wr_tag_o, // 当前写回所属预约的 tag。
    output wire retire_o, // 最后一字写入握手；此后才能归还该暂存槽。
    output wire [COUNT_W-1:0] used_o, // 已预约尚未退休总数，不只是已返回结果数。
    output reg protocol_error_o // 黏滞诊断：无预约结果、队列溢出；正常流必须为 0。
);
    localparam integer WORDS=16/P;
    localparam integer CHUNK_W=(WORDS>1?$clog2(WORDS):1);
    reg [PTR_W-1:0] alloc_ptr_r,capture_ptr_r,rd_ptr_r;
    // used: 所有未提交结果；pending: 已启动未返回；queued: 已返回未完全移入输出级。
    // 这三个计数语义不能混用：最后一个分片进入弹性寄存器，不等于已写入 C。
    reg [COUNT_W-1:0] used_r,pending_r,queued_r;
    reg [CHUNK_W-1:0] chunk_r;
    (* ram_style="distributed" *) reg [ADDR_W-1:0] base_r[0:SLOTS-1];
    (* ram_style="distributed" *) reg [TAG_W-1:0] tag_r[0:SLOTS-1];
    (* ram_style="distributed" *) reg [3:0] shape_r[0:SLOTS-1];
    wire [P*32-1:0] words_w[0:WORDS-1];
    wire out_last_w;
    wire output_room_w;
    wire [P-1:0] row_keep_w;
    localparam integer ROW_W=P*32+P+ADDR_W+TAG_W+1;
    wire [ROW_W-1:0] row_payload_w={chunk_r==WORDS-1,base_r[rd_ptr_r]+ADDR_W'(chunk_r),tag_r[rd_ptr_r],row_keep_w,words_w[chunk_r]};
    wire [ROW_W-1:0] output_payload_w;
    wire reserve_w=reserve_valid_i && reserve_ready_o;
    wire pending_present_w;
    wire capture_w=resetn && result_valid_i && pending_present_w;
    generate if(FAST_CAPTURE) begin:g_pending_flag
        reg present_r;
        // 与 pending_r!=0 严格同拍。只预译码控制，不给结果数据增加延迟。
        always @(posedge clk or negedge resetn) begin
            if(!resetn) present_r<=1'b0;
            else case({reserve_w,capture_w})
                2'b10:present_r<=1'b1;
                2'b01:present_r<=pending_r>1;
                default:present_r<=present_r;
            endcase
        end
        assign pending_present_w=present_r;
        // synthesis translate_off
        always @(posedge clk) if(resetn && present_r !== (pending_r!=0))
            $fatal(1,"collector pending predecode mismatch");
        // synthesis translate_on
    end else begin:g_pending_comb
        assign pending_present_w=pending_r!=0;
    end endgenerate
    wire stage_load_w=output_room_w && queued_r!=0;
    wire stage_last_w=stage_load_w && chunk_r==WORDS-1;
    assign reserve_ready_o=resetn && used_r<SLOTS;
    // p23：ready在两字本地弹性队列处终止，不再直接驱动整行寄存器更新。
    npu_v23_row_elastic #(.W(ROW_W)) u_row_output(
        .clk(clk),.resetn(resetn),.in_valid_i(queued_r!=0),.in_ready_o(output_room_w),.in_data_i(row_payload_w),
        .out_valid_o(wr_valid_o),.out_ready_i(wr_ready_i),.out_data_o(output_payload_w),.used_o());
    assign {out_last_w,wr_addr_o,wr_tag_o,wr_keep_o,wr_data_o}=output_payload_w;
    assign retire_o=wr_valid_o && wr_ready_i && out_last_w;
    assign used_o=used_r;
    // p22: No full-matrix payload capture. Each PE owns one 32-bit bank
    // and its write pointer. Physical tile events are ordered per PE even
    // when different packets overlap in the systolic wavefront.
    genvar w,e;
    generate for(w=0;w<16;w=w+1) begin:G_PE_BANK
        (* ram_style="distributed" *) reg [31:0] data_r[0:SLOTS-1];
        reg [PTR_W-1:0] pe_wr_r;
        // No global pending/reset on the wide payload WE. Reset cancels
        // ownership; any reset-edge write is to an unobservable old slot.
        always @(posedge clk) if(pe_valid_i[w])
            data_r[pe_wr_r]<=result_data_i[w*32+:32];
        always @(posedge clk or negedge resetn) begin
            if(!resetn) pe_wr_r<=0;
            else if(pe_valid_i[w]) pe_wr_r<=next_ptr(pe_wr_r);
        end
        assign words_w[w/4][(w%4)*32+:32]=data_r[rd_ptr_r];
        // synthesis translate_off
        integer debt;
        reg [SLOTS-1:0] written;
        always @(posedge clk or negedge resetn) begin
            if(!resetn)begin debt<=0;written<=0;end
            else begin
                debt<=debt+reserve_w-pe_valid_i[w];
                if(pe_valid_i[w] && debt<=0)$fatal(1,"NATIVE unreserved PE result");
                if(pe_valid_i[w] && written[pe_wr_r])$fatal(1,"NATIVE live slot overwrite");
                if(capture_w && !written[capture_ptr_r])$fatal(1,"NATIVE completion before PE write");
                if(stage_last_w)written[rd_ptr_r]<=0;
                if(pe_valid_i[w])written[pe_wr_r]<=1;
            end
        end
        // synthesis translate_on
    end
    for(e=0;e<P;e=e+1) begin:g_keep
        wire [4:0] element_w=chunk_r*P+e;
        assign row_keep_w[e]=(element_w/4<=shape_r[rd_ptr_r][3:2]) && (element_w%4<=shape_r[rd_ptr_r][1:0]);
    end endgenerate
    // 元数据存储仍按预约/完成事件写入；本地行读取游标仅在push时推进。
    always @(posedge clk) begin
        if(reserve_w) begin base_r[alloc_ptr_r]<=reserve_base_i;tag_r[alloc_ptr_r]<=reserve_tag_i;end
        if(capture_w) shape_r[capture_ptr_r]<=result_shape_i;
    end
    function [PTR_W-1:0] next_ptr(input [PTR_W-1:0] p);
        next_ptr=(p==SLOTS-1)?0:p+1'b1;
    endfunction
    always @(posedge clk or negedge resetn) begin
        if(!resetn) begin
            alloc_ptr_r<=0;capture_ptr_r<=0;rd_ptr_r<=0;used_r<=0;pending_r<=0;queued_r<=0;
            chunk_r<=0;protocol_error_o<=0;
        end else begin
            case({reserve_w,retire_o})
                2'b10:used_r<=used_r+1'b1;
                2'b01:used_r<=used_r-1'b1;
                default:used_r<=used_r;
            endcase
            case({reserve_w,capture_w})
                2'b10:pending_r<=pending_r+1'b1;
                2'b01:pending_r<=pending_r-1'b1;
                default:pending_r<=pending_r;
            endcase
            case({capture_w,stage_last_w})
                2'b10:queued_r<=queued_r+1'b1;
                2'b01:queued_r<=queued_r-1'b1;
                default:queued_r<=queued_r;
            endcase
            if(reserve_w) alloc_ptr_r<=next_ptr(alloc_ptr_r);
            if(capture_w) capture_ptr_r<=next_ptr(capture_ptr_r);
            if(stage_load_w) begin
                if(stage_last_w) begin chunk_r<=0;rd_ptr_r<=next_ptr(rd_ptr_r);end
                else chunk_r<=chunk_r+1'b1;
            end
            if((result_valid_i && !capture_w) || used_r>SLOTS || pending_r>used_r || queued_r>used_r) protocol_error_o<=1;
        end
    end
    // synthesis translate_off
    initial begin
        if(P!=4 || SLOTS<2) $fatal(1,"collector parameters");
    end
    // synthesis translate_on
endmodule
