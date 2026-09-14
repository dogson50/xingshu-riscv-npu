// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// 模块名称：npu_v13_command_fifo
//
// 一、模块职责
// -----------
// 单时钟、单写口、单读口的参数化 ready/valid FIFO。FIFO 不解释 payload 中的
// GEMM/CONV、M/K/N、地址或 mode 字段，因此命令格式变化不会修改本模块。
//
// 二、BRAM 推断约束
// ---------------
// memory 只有同步写和同步读，且不参与 reset。读口后保留 raw stage 与 BRAM
// 可选输出寄存器 stage；两个宽数据寄存器都不复位，只有对应 valid 才有意义。
// Vivado 可把第二级吸收到 RAMB36 的 DO_REG，而不是消耗 DATA_W 个 Slice FF。
//
// 三、吞吐和延迟
// -------------
// * raw/output 两级都装满后，连续命令仍可每拍出队，稳态 II=1；
// * 空 FIFO 的首项需要经过同步读和输出寄存两个周期；
// * 输出被反压时，当前 head 保持不动，raw stage 还可多预取一项；
// * FIFO 已满时不使用当前 pop 组合放行 push：上游只多等待一个周期，却切断
//   consumer/decode -> pop -> BRAM 写使能的长路径，不影响计算数据流吞吐。
//
// 四、参数限制
// -----------
// DEPTH 必须大于等于 2 且为 2 的幂，使读写指针可以自然回绕，避免在指针关键
// 路径加入 DEPTH-1 比较器。
//////////////////////////////////////////////////////////////////////////////////
module npu_v13_command_fifo #(
    parameter integer DATA_W = 64,
    parameter integer DEPTH  = 64
) (
    input  wire                             clk, // FIFO 单时钟；入队、出队及 BRAM 预取在上升沿进行。
    input  wire                             resetn, // 低有效异步复位计数和有效状态，逻辑清空队列；不清零 RAM/数据寄存器内容。

    // 入队接口。valid=1、ready=0 时，上游必须保持 in_data_i 不变。
    input  wire                             in_valid_i, // 整条输入命令数据有效；在 in_ready_o=0 时保持 valid 与 data，握手才算入队。
    output wire                             in_ready_o, // 非复位且总占用未满时可入队；满队列不因同拍 pop 而组合放行新写入。
    input  wire [DATA_W-1:0]                in_data_i, // 待入队的 DATA_W 位原始命令载荷，本模块不解释字段；仅入队握手时写入。

    // 出队接口。out_valid_o=1、out_ready_i=0 时，本模块保持 out_data_o 不变。
    output wire                             out_valid_o, // 预取输出槽内存在有效队首命令，与 out_ready_i 无关；为 0 时 RAM 中仍可能有待预取数据。
    input  wire                             out_ready_i, // 下游能接收队首命令；只有与 out_valid_o 同为 1 才发生 pop，不控制内部提前预取。
    output wire [DATA_W-1:0]                out_data_o, // 预取后的队首载荷；valid=1 且 ready=0 时保持稳定，valid=0 时内容无意义。

    output wire                             empty_o, // 总占用为 0，包含 RAM 未读项及两个预取级的占用；不能简单用 !out_valid_o 替代。
    output wire                             full_o, // 总占用达到 DEPTH；包括已从 RAM 预取但尚未被下游取走的命令。
    output wire [$clog2(DEPTH+1)-1:0]       level_o // 已接收入队数减去已出队数，范围 0..DEPTH；包含 RAM 与预取级，不只是未读 RAM 项数。
);
    localparam integer PTR_W   = $clog2(DEPTH);
    localparam integer COUNT_W = $clog2(DEPTH + 1);

    // 参数错误应在仿真/综合展开阶段立即暴露，不能静默生成错误指针逻辑。
    initial begin
        if (DEPTH < 2)
            $error("npu_v13_command_fifo DEPTH must be >= 2");
        if ((DEPTH & (DEPTH - 1)) != 0)
            $error("npu_v13_command_fifo DEPTH must be a power of two");
    end

    // memory 内容不复位；清空 FIFO 只需复位 count/valid/指针。
    (* ram_style = "block" *) reg [DATA_W-1:0] memory [0:DEPTH-1];

    reg [PTR_W-1:0]   write_ptr_r;
    reg [PTR_W-1:0]   fetch_ptr_r;
    reg [COUNT_W-1:0] count_r;
    reg [COUNT_W-1:0] unread_count_r;
    reg               ram_valid_r;
    reg               out_valid_r;
    reg [DATA_W-1:0]  ram_q;
    reg [DATA_W-1:0]  out_q;

    wire pop_w = out_valid_r && out_ready_i;

    assign empty_o = (count_r == {COUNT_W{1'b0}});
    assign full_o = (count_r == DEPTH);

    // reset 期间禁止宣告 ready，避免上游把随后会被清空的写入误认为已接收。
    // 满队列不组合旁路 pop，可避免下游逻辑进入 BRAM write-enable 关键路径。
    assign in_ready_o = resetn && !full_o;
    wire push_w = in_valid_i && in_ready_o;

    assign out_valid_o = out_valid_r;
    assign out_data_o = out_q;
    assign level_o = count_r;

    // out stage 可在空闲或当前 head 被接收时装入；raw stage 可在自身为空，
    // 或同拍会向 out stage 前移时接收下一次 BRAM read。fetch_ptr_r 直接驱动
    // BRAM 地址，地址路径不再包含 pop、payload decode、mux 或加法器。
    wire out_slot_open_w = !out_valid_r || pop_w;
    wire ram_slot_open_w = !ram_valid_r || out_slot_open_w;
    wire ram_read_en_w =
        (unread_count_r != {COUNT_W{1'b0}}) && ram_slot_open_w;

    // BRAM 写口：单时钟、单写使能、整字写入。
    always @(posedge clk) begin
        if (push_w)
            memory[write_ptr_r] <= in_data_i;
    end

    // BRAM raw 读级：严格同步读。fetch_ptr_r 是唯一地址来源。
    always @(posedge clk) begin
        if (ram_read_en_w)
            ram_q <= memory[fetch_ptr_r];
    end

    // 第二级对应 RAMB36E1 的可选输出寄存器。REGCE 可独立于读 EN，
    // 因此输出反压时 out_q 保持，同时 raw stage 仍可缓存下一条命令。
    always @(posedge clk) begin
        if (out_slot_open_w)
            out_q <= ram_q;
    end

    // 只有协议控制状态参与 reset，避免 reset 网络进入宽 memory/data 通路。
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            write_ptr_r <= {PTR_W{1'b0}};
            fetch_ptr_r <= {PTR_W{1'b0}};
            count_r <= {COUNT_W{1'b0}};
            unread_count_r <= {COUNT_W{1'b0}};
            ram_valid_r <= 1'b0;
            out_valid_r <= 1'b0;
        end else begin
            if (push_w)
                write_ptr_r <= write_ptr_r +
                               {{(PTR_W-1){1'b0}}, 1'b1};
            if (ram_read_en_w)
                fetch_ptr_r <= fetch_ptr_r +
                               {{(PTR_W-1){1'b0}}, 1'b1};

            case ({push_w, pop_w})
                2'b10: count_r <= count_r +
                                  {{(COUNT_W-1){1'b0}}, 1'b1};
                2'b01: count_r <= count_r -
                                  {{(COUNT_W-1){1'b0}}, 1'b1};
                default: count_r <= count_r;
            endcase

            case ({push_w, ram_read_en_w})
                2'b10: unread_count_r <= unread_count_r +
                         {{(COUNT_W-1){1'b0}}, 1'b1};
                2'b01: unread_count_r <= unread_count_r -
                         {{(COUNT_W-1){1'b0}}, 1'b1};
                default: unread_count_r <= unread_count_r;
            endcase

            if (out_slot_open_w)
                out_valid_r <= ram_valid_r;

            if (ram_read_en_w)
                ram_valid_r <= 1'b1;
            else if (out_slot_open_w)
                ram_valid_r <= 1'b0;
        end
    end
endmodule
