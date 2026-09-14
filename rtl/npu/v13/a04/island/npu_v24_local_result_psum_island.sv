// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// p27候选单岛：在p26静态地址基础上，仅给窄校验控制增加一拍流水。
// payload/meta/address/keep仍在输入握手时写本地bank；校验token下一拍写flag并发布unread ownership。
// 校验流水每拍都可接收新token，因此只增加固定首包延迟，不降低稳态II=1。
// 长距离只保留ready/valid、读写指针、占用和地址控制；128bit只在bank到相邻P4 PSUM之间出现。
// 输入时完成坐标/keep预译码，读侧不再复制“180bit slice + 180bit mapped”两层宽记录。
module npu_v24_local_result_psum_island #(
    parameter integer ISLAND_ID=0,
    parameter integer MAX_M=128, MAX_N=128,
    parameter integer STORE_DEPTH=128,
    parameter integer LOCAL_DEPTH=STORE_DEPTH+3, // 等价覆盖参考FIFO+slice2+mapped的131个前端位置。
    parameter integer PSUM_DEPTH=(MAX_M/4)*(MAX_N/4),
    parameter integer PSUM_AW=(PSUM_DEPTH<=2 ? 1 : $clog2(PSUM_DEPTH)),
    parameter integer LOCAL_AW=(LOCAL_DEPTH<=2 ? 1 : $clog2(LOCAL_DEPTH)),
    parameter integer LOCAL_CW=$clog2(LOCAL_DEPTH+1),
    parameter integer STORE_CW=$clog2(STORE_DEPTH+1)
)(
    input wire clk,input wire resetn,input wire clear_error_i,
    input wire [15:0] ctx_m_i,ctx_n_i,ctx_tag_i,
    input wire ctx_first_i,ctx_final_i,
    input wire in_valid_i,output wire in_ready_o,
    input wire [127:0] in_data_i,input wire [3:0] in_keep_i,
    input wire [15:0] in_m_i,in_n_i,in_tag_i,input wire in_tile_last_i,
    output wire out_valid_o,input wire out_ready_i,
    output wire [127:0] out_data_o,output wire [3:0] out_keep_o,
    output wire [PSUM_AW-1:0] out_addr_o,output wire [47:0] out_meta_o,
    output wire commit_valid_o,output wire commit_error_o,output wire commit_final_o,
    output wire [3:0] commit_keep_o,output wire [PSUM_AW-1:0] commit_addr_o,
    output wire [47:0] commit_meta_o,output wire idle_o,output wire error_o,
    output wire [STORE_CW-1:0] store_used_o
);
    localparam integer MAX_M_AW=$clog2(MAX_M);
    localparam integer MAX_N_AW=$clog2(MAX_N);
    localparam integer LOCAL_ROW_AW=$clog2(MAX_M/4);
    localparam integer LOCAL_COL_AW=$clog2(MAX_N/4);

    // p71：写侧也采用“局部current-address + 单个lookahead”，避免一个wr_ptr直接跨区驱动全部bank。
    // 四个局部指针始终锁步，仅复制窄地址状态，不复制payload；单个lookahead保留LOCAL_DEPTH=131回绕逻辑。
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] wr_ptr_payload01_r;
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] wr_ptr_payload23_r;
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] wr_ptr_meta_r;
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] wr_ptr_ctrl_r;
    reg [LOCAL_AW-1:0] wr_ptr_next_r;
    // p68：四组memory各用局部current-address寄存器，但非2幂回绕只在单个lookahead状态中计算。
    // current-address在read_issue沿先完成本拍读、再从lookahead装入下一地址；lookahead自行前进一步。
    // BRAM地址长线因此终止于局部FF，且不会像p67那样复制四套LOCAL_DEPTH=131计数器。
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] rd_ptr_payload01_r;
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] rd_ptr_payload23_r;
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] rd_ptr_meta_r;
    (* keep="true", equivalent_register_removal="no" *) reg [LOCAL_AW-1:0] rd_ptr_ctrl_r;
    reg [LOCAL_AW-1:0] rd_ptr_next_r;
    reg [LOCAL_CW-1:0] total_r,unread_r;
    reg q_valid_r,error_r,full_r;

    // ingress校验只携带窄predicate和slot token；不复制128bit payload。
    reg check_valid_r;
    reg [LOCAL_AW-1:0] check_ptr_r;
    reg check_fixed_bad_r,check_tag_bad_r,check_m_in_ctx_r;
    reg [3:0] check_n_in_ctx_r,check_keep_r;
    reg check_tile_last_r,check_first_r,check_final_r;

    // 128bit不作为跨模块队列记录：每lane独立物理bank，同一个窄slot token寻址。
    (* ram_style="block" *) reg [31:0] payload0_mem[0:LOCAL_DEPTH-1];
    (* ram_style="block" *) reg [31:0] payload1_mem[0:LOCAL_DEPTH-1];
    (* ram_style="block" *) reg [31:0] payload2_mem[0:LOCAL_DEPTH-1];
    (* ram_style="block" *) reg [31:0] payload3_mem[0:LOCAL_DEPTH-1];
    (* ram_style="block" *) reg [47:0] meta_mem[0:LOCAL_DEPTH-1];
    (* ram_style="distributed" *) reg [PSUM_AW-1:0] addr_mem[0:LOCAL_DEPTH-1];
    (* ram_style="distributed" *) reg [3:0] keep_mem[0:LOCAL_DEPTH-1];
    // {tile_last,first,final,bad}；tile_last保留语义但当前单岛PSUM不需要向外传递。
    (* ram_style="distributed" *) reg [3:0] flag_mem[0:LOCAL_DEPTH-1];

    // 对静态2幂MAX尺寸，本地row/col索引是纯位重排，不综合32bit乘法、加法或除法。
    wire [LOCAL_ROW_AW-1:0] push_local_row={in_m_i[MAX_M_AW-1:4],in_m_i[1:0]};
    wire [LOCAL_COL_AW-1:0] push_local_col=in_n_i[MAX_N_AW-1:2];
    wire [PSUM_AW-1:0] push_address={push_local_row,push_local_col};
    wire push_m_oob=|(in_m_i>>MAX_M_AW);
    wire push_n_oob=|(in_n_i>>MAX_N_AW);
    wire push_fixed_bad=(push_m_oob || push_n_oob || in_n_i[1:0]!=0 ||
                         in_m_i[3:2]!=ISLAND_ID);
    wire push_tag_bad=(in_tag_i!=ctx_tag_i);
    wire push_m_in_ctx=(in_m_i<ctx_m_i);
    wire [3:0] push_n_in_ctx;
    genvar l;
    generate for(l=0;l<4;l=l+1) begin:G_PUSH_KEEP
        assign push_n_in_ctx[l]=({1'b0,in_n_i}+l < {1'b0,ctx_n_i});
    end endgenerate
    // 第一拍把长比较链截在普通FF；第二拍只有4bit keep核对和少量OR进入flag LUTRAM。
    wire check_keep_bad=(check_keep_r!=({4{check_m_in_ctx_r}}&check_n_in_ctx_r));
    wire check_bad=check_fixed_bad_r || check_tag_bad_r || check_keep_bad;
    wire check_commit=resetn && check_valid_r;
    // p56：在p55稳定双列布局上注册精确full状态，切断occupancy比较器到各BRAM写使能的同拍路径。
    // 满边界仍不允许同拍pop+push，行为与原total_r<LOCAL_DEPTH完全一致；稳态非满时仍保持II=1。
    assign in_ready_o=resetn && !full_r;
    wire push=in_valid_i && in_ready_o;
    // p33：把同一握手条件温和地分成三个局部写使能锚点。
    // KEEP阻止综合把命名边界完全吸收；MAX_FANOUT允许复制末级LUT，使其靠近对应BRAM组。
    // 这里只复制窄控制，不寄存/复制128bit payload，不改变握手、容量、首包延迟或稳态II=1。
    (* keep="true", max_fanout=6 *) wire push_payload01=in_valid_i && in_ready_o;
    (* keep="true", max_fanout=6 *) wire push_payload23=in_valid_i && in_ready_o;
    (* keep="true", max_fanout=8 *) wire push_meta_ctrl=in_valid_i && in_ready_o;

    reg [31:0] q_data0_r,q_data1_r,q_data2_r,q_data3_r;
    reg [47:0] q_meta_r;
    reg [PSUM_AW-1:0] q_addr_r;
    reg [3:0] q_keep_r,q_flag_r;
    wire q_bad=q_flag_r[0];
    wire q_final=q_flag_r[1];
    wire q_first=q_flag_r[2];
    wire psum_ready,psum_idle,psum_error;
    wire psum_valid=resetn && q_valid_r && !q_bad;
    wire q_take=resetn && q_valid_r && (q_bad || psum_ready);
    // q是bank的唯一宽读出寄存；take同拍可预取下一token，正常持续II=1。
    wire read_issue=resetn && unread_r!=0 && (!q_valid_r || q_take);
    // p49：与p33写侧局部使能相同，只复制窄read_issue控制，不复制或寄存任何宽数据。
    // 三个逻辑等价的锚点分别靠近payload 0/1、payload 2/3和meta/control bank，
    // 目标是缩短“PSUM输出反压 -> q_take -> BRAM ENARDEN”的高扇出布线路径；容量、拍位和II=1不变。
    (* keep="true", max_fanout=6 *) wire read_payload01=resetn && unread_r!=0 && (!q_valid_r || q_take);
    (* keep="true", max_fanout=6 *) wire read_payload23=resetn && unread_r!=0 && (!q_valid_r || q_take);
    (* keep="true", max_fanout=8 *) wire read_meta_ctrl=resetn && unread_r!=0 && (!q_valid_r || q_take);

    always @(posedge clk) begin
        if(push_payload01) begin
            payload0_mem[wr_ptr_payload01_r]<=in_data_i[0+:32];
            payload1_mem[wr_ptr_payload01_r]<=in_data_i[32+:32];
        end
        if(push_payload23) begin
            payload2_mem[wr_ptr_payload23_r]<=in_data_i[64+:32];
            payload3_mem[wr_ptr_payload23_r]<=in_data_i[96+:32];
        end
        if(push_meta_ctrl) begin
            meta_mem[wr_ptr_meta_r]<={in_tag_i,in_m_i,in_n_i};
            addr_mem[wr_ptr_ctrl_r]<=push_address[PSUM_AW-1:0];
            keep_mem[wr_ptr_ctrl_r]<=in_keep_i;
            check_ptr_r<=wr_ptr_ctrl_r;
            check_fixed_bad_r<=push_fixed_bad;
            check_tag_bad_r<=push_tag_bad;
            check_m_in_ctx_r<=push_m_in_ctx;
            check_n_in_ctx_r<=push_n_in_ctx;
            check_keep_r<=in_keep_i;
            check_tile_last_r<=in_tile_last_i;
            check_first_r<=ctx_first_i;
            check_final_r<=ctx_final_i;
        end
        // flag提交后才增加unread，保证读token永远不会观察到尚未写入的校验结果。
        if(check_commit)
            flag_mem[check_ptr_r]<={check_tile_last_r,check_first_r,check_final_r,check_bad};
        if(read_payload01) begin
            q_data0_r<=payload0_mem[rd_ptr_payload01_r];q_data1_r<=payload1_mem[rd_ptr_payload01_r];
        end
        if(read_payload23) begin
            q_data2_r<=payload2_mem[rd_ptr_payload23_r];q_data3_r<=payload3_mem[rd_ptr_payload23_r];
        end
        if(read_meta_ctrl) begin
            q_meta_r<=meta_mem[rd_ptr_meta_r];q_addr_r<=addr_mem[rd_ptr_ctrl_r];
            q_keep_r<=keep_mem[rd_ptr_ctrl_r];q_flag_r<=flag_mem[rd_ptr_ctrl_r];
        end
    end

    function [LOCAL_AW-1:0] next_ptr(input [LOCAL_AW-1:0] p);
        next_ptr=(p==LOCAL_DEPTH-1)?0:p+1'b1;
    endfunction
    always @(posedge clk) begin
        if(!resetn) begin
            wr_ptr_payload01_r<=0;wr_ptr_payload23_r<=0;wr_ptr_meta_r<=0;wr_ptr_ctrl_r<=0;
            // LOCAL_DEPTH>=2，写侧第一个lookahead同样恒为地址1。
            wr_ptr_next_r<=1'b1;
            rd_ptr_payload01_r<=0;rd_ptr_payload23_r<=0;rd_ptr_meta_r<=0;rd_ptr_ctrl_r<=0;
            // LOCAL_DEPTH>=2，因此复位后的第一个lookahead恒为地址1。
            rd_ptr_next_r<=1'b1;
            total_r<=0;unread_r<=0;q_valid_r<=0;error_r<=0;
            check_valid_r<=0;full_r<=0;
        end else begin
            // 旧check token本拍无条件提交，新push可在同拍占据check级，稳态无气泡。
            check_valid_r<=push;
            if(push) begin
                wr_ptr_payload01_r<=wr_ptr_next_r;
                wr_ptr_payload23_r<=wr_ptr_next_r;
                wr_ptr_meta_r<=wr_ptr_next_r;
                wr_ptr_ctrl_r<=wr_ptr_next_r;
                wr_ptr_next_r<=next_ptr(wr_ptr_next_r);
            end
            if(read_issue) begin
                rd_ptr_payload01_r<=rd_ptr_next_r;
                rd_ptr_payload23_r<=rd_ptr_next_r;
                rd_ptr_meta_r<=rd_ptr_next_r;
                rd_ptr_ctrl_r<=rd_ptr_next_r;
                rd_ptr_next_r<=next_ptr(rd_ptr_next_r);
            end
            case({push,q_take})
                2'b10:begin
                    total_r<=total_r+1'b1;
                    if(total_r==LOCAL_DEPTH-1) full_r<=1'b1;
                end
                2'b01:begin
                    total_r<=total_r-1'b1;
                    full_r<=1'b0;
                end
                default:;
            endcase
            case({check_commit,read_issue})
                2'b10:unread_r<=unread_r+1'b1;
                2'b01:unread_r<=unread_r-1'b1;
                default:;
            endcase
            if(read_issue) q_valid_r<=1;
            else if(q_take) q_valid_r<=0;
            if(clear_error_i) error_r<=0;
            else if(q_valid_r && q_bad) error_r<=1;
        end
    end

    npu_v13_psum_p4 #(.DEPTH(PSUM_DEPTH),.ADDR_W(PSUM_AW),.META_W(48)) u_psum(
        .clk(clk),.resetn(resetn),.in_valid_i(psum_valid),.in_ready_o(psum_ready),
        .in_addr_i(q_addr_r),.in_data_i({q_data3_r,q_data2_r,q_data1_r,q_data0_r}),
        .in_keep_i(q_keep_r),.in_first_i(q_first),.in_final_i(q_final),.in_meta_i(q_meta_r),
        .out_valid_o(out_valid_o),.out_ready_i(out_ready_i),.out_data_o(out_data_o),
        .out_keep_o(out_keep_o),.out_addr_o(out_addr_o),.out_meta_o(out_meta_o),
        .commit_valid_o(commit_valid_o),.commit_error_o(commit_error_o),.commit_final_o(commit_final_o),
        .commit_keep_o(commit_keep_o),.commit_addr_o(commit_addr_o),.commit_meta_o(commit_meta_o),
        .idle_o(psum_idle),.error_o(psum_error));
    assign idle_o=resetn && total_r==0 && psum_idle;
    assign error_o=error_r || psum_error;
    // 仅为与旧端口宽度兼容；候选真实容量为LOCAL_DEPTH，饱和显示全1而不截断回零。
    assign store_used_o=(total_r>={STORE_CW{1'b1}})?{STORE_CW{1'b1}}:total_r[STORE_CW-1:0];

    // synthesis translate_off
    initial begin
        if(ISLAND_ID<0 || ISLAND_ID>3 || STORE_DEPTH<4 || LOCAL_DEPTH<STORE_DEPTH+3 ||
           MAX_M<32 || MAX_N<8 || (MAX_M&(MAX_M-1))!=0 || (MAX_N&(MAX_N-1))!=0 ||
           (1<<LOCAL_AW)<LOCAL_DEPTH || PSUM_DEPTH!=(MAX_M/4)*(MAX_N/4) ||
           PSUM_AW!=LOCAL_ROW_AW+LOCAL_COL_AW)
            $fatal(1,"p26 candidate static-address parameters");
    end
    always @(posedge clk) if(resetn) begin
        if(total_r>LOCAL_DEPTH || unread_r>LOCAL_DEPTH ||
           total_r!=unread_r+q_valid_r+check_valid_r ||
           full_r!=(total_r==LOCAL_DEPTH))
            $fatal(1,"p56 registered-full local token ownership invariant");
    end
    // synthesis translate_on
endmodule


