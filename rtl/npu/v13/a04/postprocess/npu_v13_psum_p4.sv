// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 局部P4跨K累加：同步BRAM读 -> 本地输出寄存 -> base寄存 -> 四路32bit加法 -> RAM提交/最终输出。
// 只认识word地址；GEMM/CONV坐标映射、chunk顺序、panel所有权由上层负责。
// 关键契约：非first只能读取本panel已经first初始化的lane；RAM本身不复位。
// INT32运算按模2^32回绕，不能在中间Kchunk做饱和、量化、bias或ReLU。
module npu_v13_psum_p4 #(
    parameter integer DEPTH=1024, // 本island的128bit word容量，可为非2次幂。
    parameter integer ADDR_W=(DEPTH<=2 ? 1 : $clog2(DEPTH)),
    parameter integer META_W=48 // 上层opaque标签，例如{父任务tag,行,首列}。
)(
    input wire clk, // 单计算时钟域；本模块不是CDC。
    input wire resetn, // 已同步复位，低电平至少跨一个上升沿；取消全部在途事务。
    input wire in_valid_i, // 输入有效；valid&&!ready期间所有输入字段须保持。
    output wire in_ready_o, // 本地流水可前进；不保证下游永久反压时仍接收。
    input wire [ADDR_W-1:0] in_addr_i, // 本PSUM bank的word地址，不是DDR字节地址。
    input wire [127:0] in_data_i, // 低lane在低32bit，四个有符号INT32部分和。
    input wire [3:0] in_keep_i, // 每lane独立写使能；0位既不修改RAM也不产生有效结果。
    input wire in_first_i, // 本beat有效lane覆盖旧值；不能只对整个命令首beat置1。
    input wire in_final_i, // 本beat是其输出位置的最终Kchunk，才送下游后处理。
    input wire [META_W-1:0] in_meta_i, // 随数据逐级寄存，不自行解释其中字段。
    output wire out_valid_o, // 最终累加结果有效；中间chunk及全零keep不输出。
    input wire out_ready_i, // 消费者反压；输出数据、地址、keep和meta同时保持。
    output wire [127:0] out_data_o, // final的四个INT32，keep=0的lane固定输出0。
    output wire [3:0] out_keep_o, // 对应final输入keep。
    output wire [ADDR_W-1:0] out_addr_o, // 对应PSUM word地址；便于后续mapper/store。
    output wire [META_W-1:0] out_meta_o, // 原样传递final输入meta。
    output wire commit_valid_o, // 本拍上升沿退休一个输入；有效lane此沿写入RAM。
    output wire commit_error_o, // commit伴随的地址越界错误；错误请求不读写RAM。
    output wire commit_final_o, // 被退休输入的final属性，不代表下游已接受final结果。
    output wire [3:0] commit_keep_o, // 被退休请求原keep，包括全0；计数不能只数有数据的beat。
    output wire [ADDR_W-1:0] commit_addr_o, // 被退休请求原地址，错误时也不截断伪装合法。
    output wire [META_W-1:0] commit_meta_o, // 退休的事务身份，供完成栅栏逐项记账。
    output wire idle_o, // 读、base、计算级和待消费final输出均空；RAM旧内容不算在途。
    output wire error_o // 地址错误黏滞到reset；上层须使本父任务以错误完成。
);
    // p66：r0同步RAM原始读；r1本地BRAM输出寄存；r2已选择base；r3累加结果；wb提交/最终输出。
    // 新增base寄存切断BRAM输出->旁路mux->32bit carry长路径；接口固定延迟增加一拍，稳态仍为II=1。
    reg r0_valid,r1_valid,r2_valid,r3_valid,wb_valid;
    reg wb_emit;
    reg r0_first,r1_first;
    reg r0_final,r1_final,r2_final,r3_final;
    reg r0_bad,r1_bad,r2_bad,r3_bad,wb_bad,error_r;
    reg [ADDR_W-1:0] r0_addr,r1_addr,r2_addr,r3_addr,wb_addr;
    reg [3:0] r0_keep,r1_keep,r2_keep,r3_keep,wb_keep;
    reg [META_W-1:0] r0_meta,r1_meta,r2_meta,r3_meta,wb_meta;
    reg [127:0] r0_data,r1_data,r2_data;
    reg [3:0] r2_prev_hit;

    // 内部流控只看已寄存pending状态，不让同步resetn进入BRAM操作使能组合锥。
    wire out_pending=wb_emit;
    wire advance=!out_pending || out_ready_i;
    wire accept=in_valid_i && in_ready_o;
    wire address_bad=(in_addr_i>=DEPTH);
    assign in_ready_o=resetn && advance;
    assign out_valid_o=resetn && out_pending;
    assign out_keep_o=wb_keep;
    assign out_addr_o=wb_addr;
    assign out_meta_o=wb_meta;
    assign commit_valid_o=resetn && advance && r3_valid;
    assign commit_error_o=r3_bad;
    assign commit_final_o=r3_final;
    assign commit_keep_o=r3_keep;
    assign commit_addr_o=r3_addr;
    assign commit_meta_o=r3_meta;
    assign idle_o=resetn && !r0_valid && !r1_valid && !r2_valid && !r3_valid && !out_valid_o;
    assign error_o=error_r;

    // Q在r0->r1沿预译码与四个较老事务的地址关系。
    // old r1是直接前驱：Q捕获base时其结果尚未形成，故只记录prev_hit，下一拍从sum_r紧邻旁路。
    // old r2/r3/wb在Q捕获base时分别已位于sum_r/wb_data/history_data，可直接寄存所选值。
    // 每lane独立keep；更年轻同址事务若该lane未写，必须继续回退到更老来源。first清除全部命中。
    reg hit_prev_match_r;
    reg [3:0] hit_prev_keep_r;
    // p72: these are only twelve hazard bitmap bits. Prevent the zero-valued
    // compare result from being extracted onto synchronous R pins; keeping the
    // compare on D avoids long address-compare-to-control-pin routes without
    // touching the 128-bit base/data path or adding a pipeline stage.
    (* extract_reset="no" *) reg [3:0] hit_sum_r,hit_wb_r,hit_history_r;
    wire [3:0] hit_prev_r={4{hit_prev_match_r}} & hit_prev_keep_r;
    wire addr_eq_r1,addr_eq_r2,addr_eq_r3,addr_eq_wb;
    generate if(ADDR_W<2) begin:G_ADDR_EQ_TINY
        assign addr_eq_r1=(r1_addr==r0_addr);
        assign addr_eq_r2=(r2_addr==r0_addr);
        assign addr_eq_r3=(r3_addr==r0_addr);
        assign addr_eq_wb=(wb_addr==r0_addr);
    end else begin:G_ADDR_EQ_SPLIT
        localparam integer EQ_SPLIT=ADDR_W/2;
        (* keep="true" *) wire r1_eq_lo=(r1_addr[EQ_SPLIT-1:0]==r0_addr[EQ_SPLIT-1:0]);
        (* keep="true" *) wire r1_eq_hi=(r1_addr[ADDR_W-1:EQ_SPLIT]==r0_addr[ADDR_W-1:EQ_SPLIT]);
        (* keep="true" *) wire r2_eq_lo=(r2_addr[EQ_SPLIT-1:0]==r0_addr[EQ_SPLIT-1:0]);
        (* keep="true" *) wire r2_eq_hi=(r2_addr[ADDR_W-1:EQ_SPLIT]==r0_addr[ADDR_W-1:EQ_SPLIT]);
        (* keep="true" *) wire r3_eq_lo=(r3_addr[EQ_SPLIT-1:0]==r0_addr[EQ_SPLIT-1:0]);
        (* keep="true" *) wire r3_eq_hi=(r3_addr[ADDR_W-1:EQ_SPLIT]==r0_addr[ADDR_W-1:EQ_SPLIT]);
        (* keep="true" *) wire wb_eq_lo=(wb_addr[EQ_SPLIT-1:0]==r0_addr[EQ_SPLIT-1:0]);
        (* keep="true" *) wire wb_eq_hi=(wb_addr[ADDR_W-1:EQ_SPLIT]==r0_addr[ADDR_W-1:EQ_SPLIT]);
        assign addr_eq_r1=r1_eq_lo && r1_eq_hi;
        assign addr_eq_r2=r2_eq_lo && r2_eq_hi;
        assign addr_eq_r3=r3_eq_lo && r3_eq_hi;
        assign addr_eq_wb=wb_eq_lo && wb_eq_hi;
    end endgenerate
    always @(posedge clk) if(advance && r0_valid) begin
        hit_prev_match_r<=r1_valid && !r1_bad && addr_eq_r1;
        hit_prev_keep_r<=r1_keep;
        hit_sum_r<={4{r2_valid && !r2_bad && addr_eq_r2}} & r2_keep;
        hit_wb_r<={4{r3_valid && !r3_bad && addr_eq_r3}} & r3_keep;
        hit_history_r<={4{wb_valid && !wb_bad && addr_eq_wb}} & wb_keep;
    end
    // 命中位只在有效r0推进时更新；各级valid隔离reset前旧命中，宽RAM数据无需复位。

    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin:G_LANE
        (* ram_style="block" *) reg [31:0] mem [0:DEPTH-1];
        reg [31:0] ram_q,ram_pipe_r,base_pipe_r,sum_r,wb_data_r,history_data_r;
        // p73 single-variable experiment: replicate only the narrow r1 base-control state
        // into each lane.  lane_r1_clear_r precomputes valid&&first one stage earlier,
        // so the base R/CE cones start from nearby one-bit state and each use one LUT.
        // Data, RAMs, pipeline stages, retirement order, and II=1 are unchanged.
        (* keep="true", equivalent_register_removal="no" *) reg lane_r1_valid_r;
        (* keep="true", equivalent_register_removal="no" *) reg lane_r1_clear_r;
        (* keep="true", max_fanout=32 *) wire lane_base_update=advance && lane_r1_valid_r;
        (* keep="true", max_fanout=32 *) wire lane_base_clear=advance && lane_r1_clear_r;
        wire [31:0] older_base=hit_sum_r[lane] ? sum_r :
                               (hit_wb_r[lane] ? wb_data_r :
                               (hit_history_r[lane] ? history_data_r : ram_pipe_r));
        wire [31:0] adder_base=r2_prev_hit[lane] ? sum_r : base_pipe_r;
        assign out_data_o[lane*32+:32]=wb_keep[lane] ? wb_data_r : 32'b0;

        // 同步简单双口RAM：写使能逐lane；读写碰撞数据可未知，由四年龄旁路覆盖。
        always @(posedge clk) begin
            if(accept && !address_bad && !in_first_i && in_keep_i[lane])
                ram_q<=mem[in_addr_i];
            if(advance && r3_valid && !r3_bad && r3_keep[lane])
                mem[r3_addr]<=sum_r;
        end
        // Local replicas advance and freeze exactly with the shared pipeline.  The clear bit
        // includes valid, therefore lane_base_clear always implies lane_base_update semantically.
        always @(posedge clk) begin
            if(!resetn) begin
                lane_r1_valid_r<=1'b0;
                lane_r1_clear_r<=1'b0;
            end else if(advance) begin
                lane_r1_valid_r<=r0_valid;
                lane_r1_clear_r<=r0_valid && r0_first;
            end
        end
        // base保持原来的advance&&r1_valid更新语义；显式局部clear便于映射为每lane同步R。
        always @(posedge clk) begin
            if(lane_base_clear)
                base_pipe_r<=32'b0;
            else if(lane_base_update)
                base_pipe_r<=older_base;
        end
        // 其余数据级与valid共用advance；final反压时整体冻结，输出保持稳定。
        always @(posedge clk) if(advance) begin
            ram_pipe_r<=ram_q;
            if(r2_valid)
                sum_r<=(!r2_bad && r2_keep[lane]) ? (adder_base+r2_data[lane*32+:32]) : 32'b0;
            if(r3_valid) wb_data_r<=sum_r;
            if(wb_valid) history_data_r<=wb_data_r;
        end
    end endgenerate

    // 只同步复位可见性valid与错误。wb包含已退休历史；非final wb不算新在途请求。
    always @(posedge clk) begin
        if(!resetn) begin
            r0_valid<=0;r1_valid<=0;r2_valid<=0;r3_valid<=0;wb_valid<=0;wb_emit<=0;error_r<=0;
        end else begin
            if(accept && address_bad) error_r<=1;
            if(advance) begin
                r0_valid<=accept;
                if(accept) begin
                    r0_addr<=in_addr_i;r0_data<=in_data_i;r0_keep<=in_keep_i;
                    r0_first<=in_first_i;r0_final<=in_final_i;
                    r0_meta<=in_meta_i;r0_bad<=address_bad;
                end
                r1_valid<=r0_valid;
                if(r0_valid) begin
                    r1_addr<=r0_addr;r1_data<=r0_data;r1_keep<=r0_keep;
                    r1_first<=r0_first;r1_final<=r0_final;
                    r1_meta<=r0_meta;r1_bad<=r0_bad;
                end
                r2_valid<=r1_valid;
                if(r1_valid) begin
                    r2_addr<=r1_addr;r2_data<=r1_data;r2_keep<=r1_keep;
                    r2_final<=r1_final;r2_meta<=r1_meta;r2_bad<=r1_bad;
                    r2_prev_hit<=r1_first ? 4'b0 : hit_prev_r;
                end
                r3_valid<=r2_valid;
                if(r2_valid) begin
                    r3_addr<=r2_addr;r3_keep<=r2_keep;r3_final<=r2_final;
                    r3_meta<=r2_meta;r3_bad<=r2_bad;
                end
                wb_valid<=r3_valid;
                wb_emit<=r3_valid && r3_final && !r3_bad && (|r3_keep);
                if(r3_valid) begin
                    wb_addr<=r3_addr;wb_keep<=r3_keep;
                    wb_meta<=r3_meta;wb_bad<=r3_bad;
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(DEPTH<2 || ADDR_W<$clog2(DEPTH) || ADDR_W>30 || META_W<1)
            $fatal(1,"PSUM illegal static parameters");
    end
    // synthesis translate_on
endmodule
