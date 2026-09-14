// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 两个独立INT8 resident feature bank，每bank内部按row[3:2]分成四组BRAM。
// 四路P4并行写；一个按坐标寻址的P4同步读口供pool/下一算子/DMA adapter使用。
// 本模块不把四路到达顺序当作空间顺序，不包含DDR仲裁或网络图调度。
// FREE -> FILL -> READY -> FREE；READY只在end后所有寄存写提交且计数匹配时发布。
// 上游契约：本panel每个有效P4坐标恰好出现一次；计数检查不替代逐地址重复检测。
module npu_v13_feature_store #(
    parameter integer MAX_M=128,MAX_N=128,
    parameter integer DEPTH=(MAX_M/4)*(MAX_N/4),
    parameter integer AW=(DEPTH<2 ? 1 : $clog2(DEPTH)),
    parameter integer CW=$clog2(DEPTH+1)
)(
    input wire clk,resetn, // 同域同步复位；清状态/valid，不清RAM。复位后所有bank为FREE。
    input wire begin_valid_i, // 预约一个FREE输出bank；字段保持至ready。
    output wire begin_ready_o, // 无其他FILL/完成响应且所选bank空闲。
    input wire begin_bank_i, // 0/1；A/B输入缓存与此C/feature bank完全独立。
    input wire [15:0] begin_m_i,begin_n_i,begin_tag_i, // resident尺寸/父tag，非全局DDR地址。
    input wire [3:0] in_valid_i, // 四路最终INT8 P4；每组最多一拍一word。
    output wire [3:0] in_ready_o, // 本地两槽缓冲容量；没有坐标检查到上游的长组合路径。
    input wire [127:0] in_data_i, // 每组32bit、每lane8bit，组0/lane0居低位。
    input wire [15:0] in_keep_i, // 每组四lane；只允许有效行的精确尾mask，不接收空物理行。
    input wire [63:0] in_m_i,in_n_i,in_tag_i, // 每组16bit行/四列起点/父tag。
    input wire end_valid_i, // 上游量化已排空，不再产生本任务的数据；申请写可见栅栏。
    output wire end_ready_o, // FILL中尚未end，接收一次。
    input wire end_error_i, // 上游任务失败；排空已接收数据，但绝不发布READY。
    output wire done_valid_o, // 写已可见或失败已隔离；响应保持直到ready。
    input wire done_ready_i, // 上层确认完成响应，不自动释放成功的READY bank。
    output wire done_bank_o, // 完成的bank身份。
    output wire [15:0] done_tag_o, // 父任务身份。
    output wire done_error_o, // 参数/数据身份/mask/总计数/上游错误，失败bank返回FREE。
    output wire [1:0] bank_ready_o,bank_free_o, // READY可反复读取；FREE可新预约。不是DDR带宽指标。
    input wire release_valid_i, // 下一算子不再使用此READY bank，申请释放。
    output wire release_ready_o, // 此bank READY且没有在途/同时发起的读；握手后才允许覆盖。
    input wire release_bank_i, // 所释放bank。
    input wire rd_valid_i, // 按坐标读取P4；越界/未READY请求返回错误响应，不读RAM。
    output wire rd_ready_o, // 同步读流水有空间，连续无反压时II=1。
    input wire rd_bank_i, // 读取的READY bank，可与另一bank写入重叠。
    input wire [15:0] rd_m_i,rd_n_i, // panel相对行及4对齐列，空间顺序由消费者决定。
    output wire rd_valid_o, // 五级请求/校验/RAM/本地寄存/响应流水；响应及错误支持反压。
    input wire rd_ready_i, // 下游接受读响应。
    output wire [31:0] rd_data_o, // 四个INT8；尾部无效lane强制0，错误响应全部0。
    output wire [3:0] rd_keep_o, // 动态尾mask，错误时为0。
    output wire rd_bank_o,rd_error_o, // 读请求对应bank与错误，不返回旧RAM伪有效数据。
    output wire [15:0] rd_m_o,rd_n_o,rd_tag_o, // 请求坐标与该bank保存的父tag。
    output wire [3:0] write_commit_o, // 真正BRAM写入事件；发布READY必须晚于最后一次该事件。
    output wire busy_o // FILL/完成响应/读流水忙；静态READY bank占用另看bank_ready。
);
    reg [1:0] ready_r;
    reg active_r,ended_r,fill_bank_r,bad_r,done_r,done_bad_r,done_bank_r;
    reg [15:0] m_r[0:1],n_r[0:1],tag_r[0:1],done_tag_r;
    // FILL专用上下文只在begin握手更新，避免每拍先选择bank再做shape/tag校验。
    reg [15:0] fill_m_r,fill_n_r,fill_tag_r;
    wire [3:0] lane_idle,map_bad,wr_valid;
    wire [CW-1:0] written[0:3];
    reg [CW-1:0] expected_r[0:3];
    // P87-C：结束检查拆成两拍。第一拍只做四个局部XOR归约并寄存，第二拍发布完成。
    // 这样不再让四组宽计数比较、跨组OR和done_bad寄存器处于同一组合锥中。
    reg finish_pending_r,finish_bad_r;
    reg [3:0] count_bad_lane_r;
    wire [3:0] count_bad_lane_w;
    // Declarations precede all procedural/generate references; this avoids implicit-net ambiguity.
    wire begin_fire=begin_valid_i && begin_ready_o;
    // P87-F：expected只需覆盖静态合法容量。非法shape已由bad_r隔离，不再让16bit输入
    // 经过integer、%16、/16和宽减法进入DSP输入。实际128x128配置把两个操作数缩为6bit。
    // group尾行仅由m[3:0]做2bit组号比较；完整16行块只在“尾组已满”时做一次窄加一。
    localparam integer ROW_BLOCK_W=$clog2(MAX_M/16+1);
    localparam integer GROUP_ROW_W=ROW_BLOCK_W+2;
    localparam integer COL_WORD_W=$clog2(MAX_N/4+1);
    localparam integer EXPECT_PRODUCT_W=GROUP_ROW_W+COL_WORD_W;
    reg [2:0] count_pipe_r;
    always @(posedge clk)begin
        if(!resetn)count_pipe_r<=0;
        else count_pipe_r<={count_pipe_r[1:0],begin_fire};
    end
    function automatic [GROUP_ROW_W-1:0] group_rows_narrow(input [15:0] rows,input [1:0] group_id);
        reg [ROW_BLOCK_W-1:0] blocks,blocks_plus_one;
        reg [2:0] tail_rows;
        begin
            // Only low ROW_BLOCK_W quotient bits are required for legal rows<=MAX_M.
            blocks=rows[ROW_BLOCK_W+3:4];
            if(rows[3:2]>group_id)tail_rows=3'd4;
            else if(rows[3:2]==group_id)tail_rows={1'b0,rows[1:0]};
            else tail_rows=3'd0;
            blocks_plus_one=blocks+1'b1;
            if(tail_rows[2])group_rows_narrow={blocks_plus_one,2'b00};
            else group_rows_narrow={blocks,tail_rows[1:0]};
        end
    endfunction
    genvar cg;
    generate for(cg=0;cg<4;cg=cg+1)begin:G_EXPECT
        localparam [1:0] GROUP_ID=cg;
        reg [GROUP_ROW_W-1:0] rows_r;
        reg [COL_WORD_W-1:0] words_r;
        (* use_dsp="yes" *) reg [EXPECT_PRODUCT_W-1:0] product_r;
        always @(posedge clk)begin
            if(begin_fire)begin
                rows_r<=group_rows_narrow(begin_m_i,GROUP_ID);
                words_r<=begin_n_i[COL_WORD_W+1:2]+(|begin_n_i[1:0]);
            end
            if(resetn && count_pipe_r[0])product_r<=rows_r*words_r;
            if(resetn && count_pipe_r[1])expected_r[cg]<=product_r[CW-1:0];
        end
        // 显式XOR归约避免综合器把四组不等比较拼成长进位/汇聚链。
        assign count_bad_lane_w[cg]=|(written[cg]^expected_r[cg]);
    end endgenerate
    // 计数DSP尚在流水中时，立即end/空输入也不能使用上一个任务的expected。
    wire all_written=active_r && ended_r && (&lane_idle) && !(|count_pipe_r);
    assign bank_ready_o=ready_r;
    assign bank_free_o=~ready_r & ~(active_r ? (2'b01<<fill_bank_r) : 2'b00);
    assign begin_ready_o=resetn && !active_r && !done_r && bank_free_o[begin_bank_i];
    assign end_ready_o=resetn && active_r && !ended_r;
    assign done_valid_o=resetn && done_r;
    assign done_error_o=done_bad_r;assign done_bank_o=done_bank_r;assign done_tag_o=done_tag_r;
    // 单独保存每bank的shape/tag；另一bank完成新任务不能改变旧READY数据的读身份。
    always @(posedge clk)begin
        if(!resetn)begin
            ready_r<=0;active_r<=0;ended_r<=0;bad_r<=0;done_r<=0;finish_pending_r<=0;
        end else begin
            if(done_r && done_ready_i)done_r<=0;
            if(release_valid_i && release_ready_o)ready_r[release_bank_i]<=0;
            if(begin_fire)begin
                active_r<=1;ended_r<=0;fill_bank_r<=begin_bank_i;
                fill_m_r<=begin_m_i;fill_n_r<=begin_n_i;fill_tag_r<=begin_tag_i;
                m_r[begin_bank_i]<=begin_m_i;n_r[begin_bank_i]<=begin_n_i;tag_r[begin_bank_i]<=begin_tag_i;
                bad_r<=begin_m_i==0 || begin_n_i==0 || begin_m_i>MAX_M || begin_n_i>MAX_N;

            end
            if(|map_bad)bad_r<=1;
            if(end_valid_i && end_ready_o)begin ended_r<=1;if(end_error_i)bad_r<=1;end
            // 完成栅栏第一拍：written/expected都已稳定；四组局部比较独立落寄存器。
            if(all_written && !finish_pending_r)begin
                finish_pending_r<=1;finish_bad_r<=bad_r;count_bad_lane_r<=count_bad_lane_w;
                done_bank_r<=fill_bank_r;done_tag_r<=tag_r[fill_bank_r];
            end
            // 第二拍仅汇总5个单bit token并发布READY/done；任务间增加一拍，不影响流内II=1。
            if(finish_pending_r)begin
                finish_pending_r<=0;active_r<=0;done_r<=1;
                done_bad_r<=finish_bad_r || (|count_bad_lane_r);
                if(!finish_bad_r && !(|count_bad_lane_r))ready_r[fill_bank_r]<=1;
            end
        end
    end
    // Read-pipeline state is declared before the BRAM generate block that consumes it.
    reg r0v,r1v,r2v,r3v,r4v,r0ready,r1bad,r2bad,r3bad,r4bad;
    reg r0bank,r1bank,r2bank,r3bank,r4bank;
    reg [15:0] r0m,r0n,r0tag,r0limit_m,r0limit_n;
    reg [15:0] r1m,r1n,r1tag,r2m,r2n,r2tag,r3m,r3n,r3tag,r4m,r4n,r4tag;
    reg [3:0] r1keep,r2keep,r3keep,r4keep;
    reg [AW-1:0] r1address;
    reg [31:0] r4data;
    wire read_advance=resetn && (!r4v || rd_ready_i);
    // 四组各自映射/写流水；不同物理bank实例，没有写bank与读bank共用单端口的竞争。
    wire [AW-1:0] wr_address[0:3];wire [31:0] wr_data[0:3];wire [3:0] wr_keep[0:3];
    wire [31:0] ram_read_data[0:7];
    genvar island,bank,byte_lane;
    generate for(island=0;island<4;island=island+1)begin:G_ISLAND
        wire sv,sr,si,slice_idle;wire [15:0] row,col,tag;wire [3:0] keep;wire [31:0] data;
        wire permit=active_r && !ended_r;
        npu_v13_stream_slice2 #(.WIDTH(84)) u_slice(
            .clk(clk),.resetn(resetn),.in_valid_i(permit && in_valid_i[island]),.in_ready_o(si),
            .in_data_i({in_tag_i[island*16+:16],in_m_i[island*16+:16],in_n_i[island*16+:16],in_keep_i[island*4+:4],in_data_i[island*32+:32]}),
            .out_valid_o(sv),.out_ready_i(sr),.out_data_o({tag,row,col,keep,data}),.idle_o(slice_idle));
        assign in_ready_o[island]=resetn && permit && si;
        assign sr=resetn && active_r;
        wire [31:0] full_address=((row>>4)*4+(row&3))*(MAX_N/4)+(col>>2);
        wire [3:0] expected_keep;
        for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)begin:G_KEEP
            assign expected_keep[byte_lane]=row<fill_m_r && ({1'b0,col}+byte_lane)<fill_n_r;
        end
        // 先分别寄存比较结果，再归并决定写valid；坏数据不写RAM但仍被退休到错误状态。
        // 数据/地址寄存CE只由流水valid决定，不能把shape->mask->bad再串到宽数据CE。
        reg map_v;reg [8:0] checks_r;reg [3:0] expect_keep_r,map_keep_r;
        reg [AW-1:0] map_address_r;reg [31:0] map_data_r;
        wire mapped_bad=(|checks_r) || map_keep_r!=expect_keep_r;
        reg wv;reg [AW-1:0] wa;reg [31:0] wd;reg [3:0] wk;reg [CW-1:0] count_r;
        assign map_bad[island]=map_v && mapped_bad;
        assign lane_idle[island]=slice_idle && !map_v && !wv;
        assign wr_valid[island]=resetn && wv;assign write_commit_o[island]=wr_valid[island];
        assign wr_address[island]=wa;assign wr_data[island]=wd;assign wr_keep[island]=wk;
        assign written[island]=count_r;
        always @(posedge clk)begin
            if(!resetn)begin map_v<=0;wv<=0;count_r<=0;end
            else begin
                map_v<=sv && sr;
                if(sv && sr)begin
                    checks_r<={full_address>=DEPTH,tag!=fill_tag_r,row[3:2]!=island,
                        col[1:0]!=0,col>=fill_n_r,row>=fill_m_r,col>=MAX_N,row>=MAX_M,1'b0};
                    expect_keep_r<=expected_keep;map_keep_r<=keep;
                    map_address_r<=full_address[AW-1:0];map_data_r<=data;
                end
                wv<=map_v && !mapped_bad;
                if(map_v)begin wa<=map_address_r;wd<=map_data_r;wk<=map_keep_r;end
                if(begin_fire)count_r<=0;else if(wr_valid[island])count_r<=count_r+1'b1;
            end
        end
        for(bank=0;bank<2;bank=bank+1)begin:G_BANK
            (* ram_style="block" *) reg [31:0] mem[0:DEPTH-1];
            reg [31:0] rd_data_r,rd_pipe_r;
            for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)begin:G_BYTE
                always @(posedge clk)if(wr_valid[island] && fill_bank_r==bank && wr_keep[island][byte_lane])
                    mem[wr_address[island]][byte_lane*8+:8]<=wr_data[island][byte_lane*8+:8];
            end
            always @(posedge clk)if(read_advance && r1v && !r1bad && r1bank==bank && r1m[3:2]==island)
                rd_data_r<=mem[r1address];
            // p5：RAM原始输出后增加独立本地寄存，先切断BRAM到跨bank/island选择器的长路径。
            // 与整个读流水共享advance；不复位RAM载荷，避免妨碍BRAM可选输出寄存映射。
            // 即使本bank没有新读，也推进旧值；真正有效性由同拍r3元数据限定。
            always @(posedge clk)if(read_advance)rd_pipe_r<=rd_data_r;
            assign ram_read_data[bank*4+island]=rd_pipe_r;
        end
    end endgenerate
    // 五级读流水：请求锁存bank上下文 -> 范围/地址/mask -> RAM同步读 -> 本地输出寄存 -> 选择/屏蔽响应。
    // RAM使能只取已寄存的r1bad；不再经过外部坐标和动态bank的组合检查。
    // 任一输出反压使五级、RAM读口和本地输出寄存一起冻结；无反压时仍为II=1，只增加一拍延迟。

    assign rd_ready_o=read_advance;
    wire read_fire=rd_valid_i && rd_ready_o;
    wire [31:0] read_address=((r0m>>4)*4+(r0m&3))*(MAX_N/4)+(r0n>>2);
    wire read_bad=!r0ready || r0m>=r0limit_m || r0n>=r0limit_n || r0n[1:0]!=0 ||
        r0m>=MAX_M || r0n>=MAX_N || read_address>=DEPTH;
    // P87-H: tail-mask generation is independent of request-error qualification.  Keeping
    // read_bad out of these four registers removes the bounds/error OR cone from their
    // D/R control pins; the registered r3bad token zeros keep/data at the response stage.
    wire [3:0] read_keep;
    generate for(byte_lane=0;byte_lane<4;byte_lane=byte_lane+1)begin:G_READ_KEEP
        assign read_keep[byte_lane]=({1'b0,r0n}+byte_lane)<r0limit_n;
    end endgenerate
    wire [31:0] selected_data=ram_read_data[{r3bank,r3m[3:2]}];
    integer l;
    always @(posedge clk)begin
        if(!resetn)begin r0v<=0;r1v<=0;r2v<=0;r3v<=0;r4v<=0;end
        else if(read_advance)begin
            r0v<=rd_valid_i;r1v<=r0v;r2v<=r1v;r3v<=r2v;r4v<=r3v;
            if(read_fire)begin
                r0ready<=ready_r[rd_bank_i];r0bank<=rd_bank_i;r0m<=rd_m_i;r0n<=rd_n_i;
                r0limit_m<=m_r[rd_bank_i];r0limit_n<=n_r[rd_bank_i];
                r0tag<=ready_r[rd_bank_i] ? tag_r[rd_bank_i] : 16'b0;
            end
            if(r0v)begin
                r1bad<=read_bad;r1bank<=r0bank;r1keep<=read_keep;r1address<=read_address[AW-1:0];
                r1m<=r0m;r1n<=r0n;r1tag<=r0tag;
            end
            if(r1v)begin
                r2bad<=r1bad;r2bank<=r1bank;r2keep<=r1keep;r2m<=r1m;r2n<=r1n;r2tag<=r1tag;
            end
            if(r2v)begin
                r3bad<=r2bad;r3bank<=r2bank;r3keep<=r2keep;r3m<=r2m;r3n<=r2n;r3tag<=r2tag;
                end
            if(r3v)begin
                r4bad<=r3bad;r4bank<=r3bank;r4keep<=r3bad ? 4'b0 : r3keep;
                r4m<=r3m;r4n<=r3n;r4tag<=r3tag;
                for(l=0;l<4;l=l+1)
                    r4data[l*8+:8]<=(!r3bad && r3keep[l]) ? selected_data[l*8+:8] : 8'b0;
            end
        end
    end
    assign rd_valid_o=resetn && r4v;assign rd_data_o=r4data;assign rd_keep_o=r4keep;
    assign rd_error_o=r4bad;assign rd_bank_o=r4bank;assign rd_m_o=r4m;assign rd_n_o=r4n;assign rd_tag_o=r4tag;
    // 从请求握手到最终响应接受，任一级仍持有该bank都禁止释放；包括正在来的同bank请求。
    assign release_ready_o=resetn && ready_r[release_bank_i] && !(r0v && r0bank==release_bank_i) &&
        !(r1v && r1bank==release_bank_i) && !(r2v && r2bank==release_bank_i) &&
        !(r3v && r3bank==release_bank_i) && !(r4v && r4bank==release_bank_i) &&
        !(rd_valid_i && rd_bank_i==release_bank_i);
    assign busy_o=active_r || done_r || r0v || r1v || r2v || r3v || r4v;
    // synthesis translate_off
    initial if(MAX_M<16 || MAX_N<16 || MAX_M%16 || MAX_N%16 || MAX_M>65520 || MAX_N>65520 ||
        DEPTH!=(MAX_M/4)*(MAX_N/4) || AW<$clog2(DEPTH) || CW<$clog2(DEPTH+1))$fatal(1,"FEATURE static capacity");
    always @(posedge clk)if(resetn && end_valid_i && end_ready_o && (|in_valid_i))$fatal(1,"FEATURE end must follow all writes");
    // synthesis translate_on
endmodule


