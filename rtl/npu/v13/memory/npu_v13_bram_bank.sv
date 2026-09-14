// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps

// ============================================================================
// 模块作用：一个独立的、同步读写的 BRAM bank。
// ============================================================================
// 1. 本模块只负责“按地址存取一个字”，不解释 A/B/C、矩阵维度或 GEMM/CONV。
//    它也不是 FIFO：没有内部读写指针，请求方每次都必须给出明确的字地址。
// 2. bank 的 FREE/LOADING/READY/IN_USE 等状态由 buffer_manager 管理。
//    外层须先检查访问权限，并同时门控送入本模块的 valid 和返回主机的 ready，
//    不能只阻断 valid 却仍让主机误以为请求已握手成功。
// 3. 一个独立写口 + 一个独立读口，共用 clk；每拍最多接收一次写和一次读。
//    读响应没有 ready，接收方必须在发请求前预留响应接收能力。
// 4. 所有地址均以 DATA_W 位的“字”为单位，不是字节地址；写操作覆盖整个字。
//    RAM 不自动初始化为零；有意义的读取应由系统保证该地址已经写入有效数据。
//
// 读时序约定：E0/E1 表示相邻时钟上升沿；“沿后”指寄存器更新后的周期。
//   请求在 E0 握手：READ_LATENCY=1 -> E0 沿后响应有效；
//                  READ_LATENCY=2 -> E1 沿后响应有效。
//   这两种配置均允许每拍接收新读请求；延迟不同不等于吞吐间隔不同。
//   请求中有气泡时流水仍每拍推进，data/tag/error 必须结合响应 valid 解释。
//
// 错误与复位约定：
//   写越界：写请求被受理并当拍报错，但不修改 RAM。
//   读越界：读请求仍被受理，固定延迟后返回原 tag 和 error=1，数据无意义。
//   同拍同地址有效读写：写照常提交，物理读禁止，读请求返回错误响应。
//   resetn 只清有效状态并禁止新请求，不擦除 RAM，也不清 data/tag/error。
// ============================================================================
module npu_v13_bram_bank #(
    // 每个存储字的位宽；可以存打包操作数或结果，本模块不解释其数值格式。
    parameter integer DATA_W=32,
    // bank 容量，单位为“字”；有效地址从 0 到 DEPTH-1，允许非 2 的幂深度。
    parameter integer DEPTH=1024,
    // 请求地址的位宽；至少覆盖全部 DEPTH 个字。DEPTH=1 时仍保留 1 位端口。
    // 当 DEPTH 不是 2 的幂，或人为把 ADDR_W 配得更宽时，会有可编码但越界的地址。
    parameter integer ADDR_W=(DEPTH>1 ? $clog2(DEPTH) : 1),
    // 读请求关联标识的位宽；随响应原样返回，可由上层用来关联请求和数据。
    parameter integer TAG_W=8,
    // 读响应流水级数，仅支持 1 或 2；具体 E0/E1 对应关系见上方时序约定。
    parameter integer READ_LATENCY=2
)(
    // ------------------------------------------------------------------------
    // 一、时钟与复位
    // ------------------------------------------------------------------------
    // 单时钟域；所有读写请求均在 clk 上升沿采样。
    input wire clk,
    // 低有效异步清除读响应有效位；复位期间两个请求 ready 均为 0。
    // RAM 内容及数据/tag/error 寄存器不清零；相关主机也须协调取消在途事务。
    input wire resetn,

    // ------------------------------------------------------------------------
    // 二、整字写请求接口
    // wr_valid_i && wr_ready_o 表示请求被受理；还需 wr_error_o=0 才真正写 RAM。
    // 等待接收期间保持 valid/address/data 稳定；复位取消事务时由系统统一处理。
    // ------------------------------------------------------------------------
    // 当前写请求有效；访问该 bank 的所有权必须已经由外层检查。
    input wire wr_valid_i,
    // 写请求接收许可，当前实现等于 resetn；不是写成功的独立响应。
    output wire wr_ready_o,
    // 写字地址，合法范围 0..DEPTH-1；例如 DATA_W=32 时，每增加 1 跨过一个 32 位字。
    input wire [ADDR_W-1:0] wr_addr_i,
    // 待写入的完整 DATA_W 位数据；没有 byte enable，成功写入会覆盖整个字。
    input wire [DATA_W-1:0] wr_data_i,
    // 仅写握手周期有意义的组合错误标志：1=地址越界，RAM 不变；无延后写响应。
    output wire wr_error_o,

    // ------------------------------------------------------------------------
    // 三、读请求接口
    // rd_valid_i && rd_ready_o 表示请求被受理，合法读和错误读都产生一次响应。
    // ------------------------------------------------------------------------
    // 当前读请求有效；发起前须确认 bank 读权限，并预留固定延迟后的响应接收空间。
    input wire rd_valid_i,
    // 读请求接收许可，当前实现等于 resetn；不会因地址非法或读写冲突而撤销 ready。
    output wire rd_ready_o,
    // 读字地址，合法范围 0..DEPTH-1；与同拍实际写入地址相等时，本次读返回错误。
    input wire [ADDR_W-1:0] rd_addr_i,
    // 本次读的关联 tag，在请求握手时采样，随后与响应同拍返回；本模块不解释其内容。
    input wire [TAG_W-1:0] rd_tag_i,

    // ------------------------------------------------------------------------
    // 四、固定延迟读响应接口：没有 rsp_ready，不能要求本模块保持某个有效响应。
    // ------------------------------------------------------------------------
    // 本拍有一条读响应；请求在 E0 握手时，延迟参数 1/2 分别在 E0/E1 沿后置位。
    output wire rd_rsp_valid_o,
    // 读出的完整字；仅 valid=1 且 error=0 时使用，其他周期可以是旧值或未初始化值。
    output wire [DATA_W-1:0] rd_rsp_data_o,
    // 与本拍有效响应对应的原始 rd_tag_i；valid=0 时此端口没有事务意义。
    output wire [TAG_W-1:0] rd_rsp_tag_o,
    // 本拍读响应错误：1=地址越界或同拍同地址有效读写冲突；仅 rsp_valid=1 时解释。
    output wire rd_rsp_error_o
);
    // ========================================================================
    // 五、存储体与读响应流水寄存器
    // ========================================================================
    // 地址比较的上限，多留 1 位是为了表示 DEPTH 本身：
    // 例如 ADDR_W=10、DEPTH=1024，地址只需 10 位，但上限 1024 需要 11 位。
    localparam [ADDR_W:0] DEPTH_LIMIT=DEPTH;

    // 二维数组表示 DEPTH 个 DATA_W 位存储字；属性请求工具采用 block RAM 实现。
    // 本存储体没有 reset 清零分支；复位后旧内容保留，不能当作全零矩阵使用。
    (* ram_style="block" *) reg [DATA_W-1:0] memory_r[0:DEPTH-1];
    // 同步 RAM 读出的第一级数据；只有实际执行合法读时才更新，否则保持旧值。
    reg [DATA_W-1:0] ram_read_r;
    // 第 s 位表示第 s 级是否有一条有效读响应，包括“受理了但读出报错”的请求。
    // 它是判断下面 data/tag/error 是否属于真实事务的依据，因此必须复位。
    reg [READ_LATENCY-1:0] valid_r;
    // 与 valid 同步推进的错误标记；无有效响应时，即使为 1 也不能解释为新错误。
    reg [READ_LATENCY-1:0] error_r;
    // 与 valid 同步推进的请求 tag；每一级保存对应请求的身份，不参与寻址。
    reg [TAG_W-1:0] tag_r[0:READ_LATENCY-1];

    // ========================================================================
    // 六、地址合法性、请求受理与读写冲突
    // ========================================================================
    // 把地址前补 0 后与同宽的 DEPTH_LIMIT 比较，合法条件是 address < DEPTH。
    // 显式检查可以拦截非 2 的幂深度或加宽地址端口产生的多余编码。
    wire wr_addr_ok_w=({1'b0,wr_addr_i}<DEPTH_LIMIT);
    wire rd_addr_ok_w=({1'b0,rd_addr_i}<DEPTH_LIMIT);

    // 不忙等也不排队：复位释放后，独立读/写口每拍都能接收一个请求。
    // 这里的 ready 不检查 bank 权限或输出容量，这两项由外层保证。
    assign wr_ready_o=resetn;
    assign rd_ready_o=resetn;
    // 写错误当拍返回；由于表达式包含 valid&&ready，无写事务时不会报写错误。
    assign wr_error_o=wr_valid_i && wr_ready_o && !wr_addr_ok_w;

    // 注意两个 fire 的含义不同，不能为了“统一形式”把它们改成同一种门控：
    // wr_fire_w 表示“本拍真正写 RAM”，因此必须同时通过地址检查。
    wire wr_fire_w=wr_valid_i && wr_ready_o && wr_addr_ok_w;
    // rd_fire_w 表示“本拍读请求被受理”，不能排除错误读；否则错误读将丢失响应。
    wire rd_fire_w=rd_valid_i && rd_ready_o;

    // 同地址冲突只看本拍实际成立的写操作；越界写不会阻止其他合法读取。
    // 此信号没有 rd_fire 门控，无读请求时也可能为 1，但这时不会产生有效响应。
    wire collision_w=wr_fire_w && (wr_addr_i==rd_addr_i);
    // 读错误来源为地址越界或同地址读写冲突；错误随请求进入响应流水。
    wire rd_error_w=!rd_addr_ok_w || collision_w;

    // ========================================================================
    // 七、独立整字写口与同步读口
    // ========================================================================
    // 成功写请求在当前上升沿更新指定字；没有写请求或写地址越界则保持存储体。
    // 即使同拍存在同地址读请求，写也照常完成；本模块选择让那次读明确报错。
    always @(posedge clk) begin
        if(wr_fire_w) memory_r[wr_addr_i]<=wr_data_i;
    end

    // 只有已受理且无错误的读才访问存储体，并在该沿后更新 ram_read_r。
    // 错误读不触发物理 RAM 读取，但 valid/error/tag 仍照常产生一条错误响应。
    // 因而避免依赖同拍读写同一地址时器件可能出现的旧值/新值选择行为。
    // 这里不为错误数据增加清零 mux；接收方本就必须根据响应 error 丢弃它。
    always @(posedge clk) begin
        if(rd_fire_w && !rd_error_w) ram_read_r<=memory_r[rd_addr_i];
    end

    // ========================================================================
    // 八、根据参数选择读数据输出级数（综合时确定，不是运行时 mode）
    // ========================================================================
    generate if(READ_LATENCY==1) begin:g_latency1
        // RAM 同步读寄存器直接作为输出：请求在 E0 接收，E0 沿后数据更新。
        // 这里的 assign 不代表“异步读 RAM”，因为 ram_read_r 已在上面的 always 中寄存。
        assign rd_rsp_data_o=ram_read_r;
    end else begin:g_latency2
        // 合法参数下本分支对应 READ_LATENCY=2，再增加一级读数据输出寄存器。
        // E1 采样 E0 已读出的 ram_read_r，所以数据在 E1 沿后到达模块输出。
        // 无 reset、每拍推进，有利于吸收到 RAMB36 的内部输出寄存器。
        reg [DATA_W-1:0] ram_output_r;
        always @(posedge clk) ram_output_r<=ram_read_r;
        assign rd_rsp_data_o=ram_output_r;
    end endgenerate

    // ========================================================================
    // 九、读响应 valid 流水：记录“哪一拍必须返回响应”
    // ========================================================================
    // valid 逐时钟移动，而不是等下一次读请求才移动，否则气泡会改变响应延迟。
    // 每条 rd_fire（包括错误读）都注入一个 1；没有读请求则注入一个 0。
    integer s;
    always @(posedge clk or negedge resetn) begin
        // 复位取消全部尚未返回的读响应，但不清理存储数据。
        if(!resetn) valid_r<={READ_LATENCY{1'b0}};
        else begin
            valid_r[0]<=rd_fire_w;
            for(s=1;s<READ_LATENCY;s=s+1) valid_r[s]<=valid_r[s-1];
        end
    end

    // ========================================================================
    // 十、读响应 error/tag 流水：与对应的 valid 保持相同级数
    // ========================================================================
    // 每拍采样和移动，不加 ready，也不在气泡时冻结；valid=0 会标出无效槽。
    // 非阻塞赋值令高一级取得的是前一周期低一级的值，因此 tag/error/valid 对齐。
    // 它们不用复位：复位已清除 valid，未初始化或旧的 tag/error 不会成为有效响应。
    integer t;
    always @(posedge clk) begin
        error_r[0]<=rd_error_w;
        tag_r[0]<=rd_tag_i;
        for(t=1;t<READ_LATENCY;t=t+1) begin
            error_r[t]<=error_r[t-1]; tag_r[t]<=tag_r[t-1];
        end
    end

    // 统一从流水最后一级输出。resetn 再门控 valid，复位期间不会对外声明有效响应。
    // error/tag 不强制清零，也不要求 data 在 valid=0 时稳定；外部不可脱离 valid 使用。
    assign rd_rsp_valid_o=resetn && valid_r[READ_LATENCY-1];
    assign rd_rsp_error_o=error_r[READ_LATENCY-1];
    assign rd_rsp_tag_o=tag_r[READ_LATENCY-1];

    // ========================================================================
    // 十一、仅仿真的参数检查，不是运行时检查电路
    // ========================================================================
    // 位宽/深度必须为正，地址位数须覆盖容量，READ_LATENCY 只能取 1 或 2。
    // 错误参数在仿真开始时直接终止，避免把非法配置误当成受支持的硬件行为。
    // synthesis translate_off
    initial begin
        if(DATA_W<1 || DEPTH<1 || TAG_W<1 || ADDR_W<1 ||
           $clog2(DEPTH)>ADDR_W || (READ_LATENCY!=1 && READ_LATENCY!=2))
            $fatal(1,"Invalid npu_v13_bram_bank parameters");
    end
    // synthesis translate_on
endmodule
