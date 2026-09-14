// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 真实 dispatcher + executor + scheduler + runtime 联合测试。
// bank 加载、地址/feeder、结果写回是测试台存储模型，不是生产 BRAM/CONV 实现。
module tb_npu_v13_job_executor_runtime_joint;
    localparam DIM_W=16, ADDR_W=32, BANK_W=1, OP_CFG_W=32, TAG_W=8, FIFO_DEPTH=4;
    localparam STRIDE=4096, JOBS=14;
    reg  clk = 0;
    reg  resetn = 0;
    reg  cmd_valid_i = 0;
    wire  cmd_ready_o;
    reg [1:0] cmd_opcode_i = 0;
    reg [DIM_W-1:0] cmd_m_i = 0;
    reg [DIM_W-1:0] cmd_n_i = 0;
    reg [DIM_W-1:0] cmd_k_i = 0;
    reg [1:0] cmd_cluster_mode_i = 0;
    reg [2:0] cmd_layout_i = 0;
    reg [ADDR_W-1:0] cmd_a_base_i = 0;
    reg [ADDR_W-1:0] cmd_b_base_i = 0;
    reg [ADDR_W-1:0] cmd_c_base_i = 0;
    reg [BANK_W-1:0] cmd_a_bank_i = 0;
    reg [BANK_W-1:0] cmd_b_bank_i = 0;
    reg [BANK_W-1:0] cmd_c_bank_i = 0;
    reg [OP_CFG_W-1:0] cmd_op_cfg_i = 0;
    reg [TAG_W-1:0] cmd_tag_i = 0;
    wire  cmd_rsp_valid_o;
    reg  cmd_rsp_ready_i = 0;
    wire [TAG_W-1:0] cmd_rsp_tag_o;
    wire [2:0] cmd_rsp_status_o;
    wire  cluster_cfg_valid_o;
    wire [1:0] cluster_cfg_mode_o;
    wire  cluster_cfg_ready_i;
    wire  cluster_cfg_error_i;
    wire [1:0] cluster_active_mode_i;
    wire  queue_empty_o;
    wire  queue_full_o;
    wire [$clog2(FIFO_DEPTH+1)-1:0] queue_level_o;
    wire  dispatcher_busy_o;
    wire  ctx_valid_o;
    wire [1:0] ctx_opcode_o;
    wire [DIM_W-1:0] ctx_m_o;
    wire [DIM_W-1:0] ctx_n_o;
    wire [DIM_W-1:0] ctx_k_o;
    wire [1:0] ctx_cluster_mode_o;
    wire [2:0] ctx_layout_o;
    wire [ADDR_W-1:0] ctx_a_base_o;
    wire [ADDR_W-1:0] ctx_b_base_o;
    wire [ADDR_W-1:0] ctx_c_base_o;
    wire [BANK_W-1:0] ctx_a_bank_o;
    wire [BANK_W-1:0] ctx_b_bank_o;
    wire [BANK_W-1:0] ctx_c_bank_o;
    wire [OP_CFG_W-1:0] ctx_op_cfg_o;
    wire [TAG_W-1:0] ctx_tag_o;
    wire  buffer_acquire_valid_o;
    reg  buffer_acquire_ready_i = 0;
    reg  buffer_acquire_error_i = 0;
    wire  buffer_release_valid_o;
    reg  buffer_release_ready_i = 0;
    wire  buffer_release_error_o;
    wire  buffers_owned_o;
    wire  backend_prepare_valid_o;
    reg  backend_prepare_ready_i = 0;
    reg  backend_prepare_error_i = 0;
    wire  job_start_o;
    wire  job_cancel_o;
    wire  tile_batch_valid_o;
    reg  tile_batch_ready_i = 0;
    wire [DIM_W-1:0] tile_batch_m_o;
    wire [DIM_W-1:0] tile_batch_n_o;
    wire [DIM_W-1:0] tile_batch_k_o;
    wire [DIM_W-1:0] tile_batch_m_base_o;
    wire [DIM_W-1:0] tile_batch_n_base_o;
    wire [1:0] tile_batch_cluster_mode_o;
    wire [2:0] tile_batch_layout_o;
    wire  tile_batch_cmd_first_o;
    wire  tile_batch_cmd_last_o;
    wire [TAG_W-1:0] tile_batch_tag_o;
    wire  schedule_finished_o;
    reg  job_complete_valid_i = 0;
    wire  job_complete_ready_o;
    reg [TAG_W-1:0] job_complete_tag_i = 0;
    reg  job_complete_error_i = 0;
    wire  executor_busy_o;
    always #5 clk=~clk;
    npu_v13_command_executor_timing_top #(.FIFO_DEPTH(FIFO_DEPTH)) dut (
        .clk(clk),
        .resetn(resetn),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .cmd_opcode_i(cmd_opcode_i),
        .cmd_m_i(cmd_m_i),
        .cmd_n_i(cmd_n_i),
        .cmd_k_i(cmd_k_i),
        .cmd_cluster_mode_i(cmd_cluster_mode_i),
        .cmd_layout_i(cmd_layout_i),
        .cmd_a_base_i(cmd_a_base_i),
        .cmd_b_base_i(cmd_b_base_i),
        .cmd_c_base_i(cmd_c_base_i),
        .cmd_a_bank_i(cmd_a_bank_i),
        .cmd_b_bank_i(cmd_b_bank_i),
        .cmd_c_bank_i(cmd_c_bank_i),
        .cmd_op_cfg_i(cmd_op_cfg_i),
        .cmd_tag_i(cmd_tag_i),
        .cmd_rsp_valid_o(cmd_rsp_valid_o),
        .cmd_rsp_ready_i(cmd_rsp_ready_i),
        .cmd_rsp_tag_o(cmd_rsp_tag_o),
        .cmd_rsp_status_o(cmd_rsp_status_o),
        .cluster_cfg_valid_o(cluster_cfg_valid_o),
        .cluster_cfg_mode_o(cluster_cfg_mode_o),
        .cluster_cfg_ready_i(cluster_cfg_ready_i),
        .cluster_cfg_error_i(cluster_cfg_error_i),
        .cluster_active_mode_i(cluster_active_mode_i),
        .queue_empty_o(queue_empty_o),
        .queue_full_o(queue_full_o),
        .queue_level_o(queue_level_o),
        .dispatcher_busy_o(dispatcher_busy_o),
        .ctx_valid_o(ctx_valid_o),
        .ctx_opcode_o(ctx_opcode_o),
        .ctx_m_o(ctx_m_o),
        .ctx_n_o(ctx_n_o),
        .ctx_k_o(ctx_k_o),
        .ctx_cluster_mode_o(ctx_cluster_mode_o),
        .ctx_layout_o(ctx_layout_o),
        .ctx_a_base_o(ctx_a_base_o),
        .ctx_b_base_o(ctx_b_base_o),
        .ctx_c_base_o(ctx_c_base_o),
        .ctx_a_bank_o(ctx_a_bank_o),
        .ctx_b_bank_o(ctx_b_bank_o),
        .ctx_c_bank_o(ctx_c_bank_o),
        .ctx_op_cfg_o(ctx_op_cfg_o),
        .ctx_tag_o(ctx_tag_o),
        .buffer_acquire_valid_o(buffer_acquire_valid_o),
        .buffer_acquire_ready_i(buffer_acquire_ready_i),
        .buffer_acquire_error_i(buffer_acquire_error_i),
        .buffer_release_valid_o(buffer_release_valid_o),
        .buffer_release_ready_i(buffer_release_ready_i),
        .buffer_release_error_o(buffer_release_error_o),
        .buffers_owned_o(buffers_owned_o),
        .backend_prepare_valid_o(backend_prepare_valid_o),
        .backend_prepare_ready_i(backend_prepare_ready_i),
        .backend_prepare_error_i(backend_prepare_error_i),
        .job_start_o(job_start_o),
        .job_cancel_o(job_cancel_o),
        .tile_batch_valid_o(tile_batch_valid_o),
        .tile_batch_ready_i(tile_batch_ready_i),
        .tile_batch_m_o(tile_batch_m_o),
        .tile_batch_n_o(tile_batch_n_o),
        .tile_batch_k_o(tile_batch_k_o),
        .tile_batch_m_base_o(tile_batch_m_base_o),
        .tile_batch_n_base_o(tile_batch_n_base_o),
        .tile_batch_cluster_mode_o(tile_batch_cluster_mode_o),
        .tile_batch_layout_o(tile_batch_layout_o),
        .tile_batch_cmd_first_o(tile_batch_cmd_first_o),
        .tile_batch_cmd_last_o(tile_batch_cmd_last_o),
        .tile_batch_tag_o(tile_batch_tag_o),
        .schedule_finished_o(schedule_finished_o),
        .job_complete_valid_i(job_complete_valid_i),
        .job_complete_ready_o(job_complete_ready_o),
        .job_complete_tag_i(job_complete_tag_i),
        .job_complete_error_i(job_complete_error_i),
        .executor_busy_o(executor_busy_o)
    );
    reg [15:0] s_valid=0,s_user=0,s_last=0;
    reg [31:0] s_rows=0,s_cols=0;
    reg [511:0] a_source=0,b_source=0;
    wire [15:0] c_valid;
    wire [31:0] c_rows,c_cols;
    wire [8191:0] c_matrix;
    wire cluster_idle;
    npu_v13_systolic_cluster_runtime_stream u_runtime (
        .clk(clk),.resetn(resetn),.cfg_valid_i(cluster_cfg_valid_o),.cfg_mode_i(cluster_cfg_mode_o),
        .cfg_ready_o(cluster_cfg_ready_i),.cfg_error_o(cluster_cfg_error_i),.active_mode_o(cluster_active_mode_i),
        .cluster_idle_o(cluster_idle),.s_axis_tvalid_i(s_valid),.s_axis_tuser_i(s_user),.s_axis_tlast_i(s_last),
        .active_rows_m1_i(s_rows),.active_cols_m1_i(s_cols),.a_source_i(a_source),.b_source_i(b_source),
        .c_tile_valid_o(c_valid),.c_active_rows_m1_o(c_rows),.c_active_cols_m1_o(c_cols),.c_matrix_o(c_matrix)
    );
    reg signed [7:0] mem_a[0:2*STRIDE-1],mem_b[0:2*STRIDE-1];
    reg signed [31:0] mem_c[0:2*STRIDE-1];
    reg written[0:STRIDE-1];
    integer physical_m[0:15],physical_n[0:15],physical_rows[0:15],physical_cols[0:15];
    integer responses=0,executions=0,tiles_checked=0,elements_checked=0,cycles=0,mode_changes=0;
    integer accept_cycle=0;
    reg writes_pending=0;
    reg [31:0] saved_tag;
    function automatic integer av(input integer m,k,tag); av=((m*3+k*5+tag)%17)-8; endfunction
    function automatic integer bv(input integer k,n,tag); bv=((k*7+n*2+tag)%19)-9; endfunction
    function automatic integer expected_status(input integer tag); expected_status=(tag>=10)?4:0; endfunction
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>200000) $fatal(1,"JOINT_TB_TIMEOUT");
        if(resetn) begin
            if(dut.exec_cmd_valid_i && dut.exec_cmd_ready_o) begin
                accept_cycle=cycles;
                if(dut.exec_cmd_cluster_mode_i!==cluster_active_mode_i) $fatal(1,"exec before mode confirmation");
                if(dut.exec_cmd_a_base_i!==32'(13+3*dut.exec_cmd_tag_i) ||
                   dut.exec_cmd_b_base_i!==32'(29+5*dut.exec_cmd_tag_i) ||
                   dut.exec_cmd_c_base_i!==32'(47+7*dut.exec_cmd_tag_i) ||
                   dut.exec_cmd_op_cfg_i!==32'(dut.exec_cmd_tag_i)) $fatal(1,"FIFO context transfer mismatch");
            end
            if(cluster_cfg_valid_o && cluster_cfg_ready_i) begin
                mode_changes=mode_changes+1;
                if(executor_busy_o || s_valid!=0 || !cluster_idle) $fatal(1,"unsafe mode change");
            end
            if(job_start_o) begin
                if(cycles-accept_cycle<4) $fatal(1,"context multicycle contract broken");
                if(!buffers_owned_o) $fatal(1,"start without bank ownership");
            end
            if(buffer_release_valid_o && (writes_pending || !cluster_idle || s_valid!=0)) $fatal(1,"release before writeback/drain");
            if(dut.exec_done_valid_o && (buffers_owned_o || writes_pending || !cluster_idle)) $fatal(1,"unsafe exec_done");
            if(cmd_rsp_valid_o && cmd_rsp_ready_i) begin
                if(cmd_rsp_tag_o!==TAG_W'(responses) || cmd_rsp_status_o!==3'(expected_status(responses)))
                    $fatal(1,"response mismatch index=%0d tag=%0d status=%0d",responses,cmd_rsp_tag_o,cmd_rsp_status_o);
                responses=responses+1;
            end
        end
    end
    // 与执行器无关的响应消费反压，检查 FIFO 可继续排队但 mode 不能抢跑。
    always @(negedge clk) if(resetn) cmd_rsp_ready_i=(cycles%7>=3);
    task automatic enqueue(input integer tag,op,md,lay,m,n,k);
        begin
            @(negedge clk);
            cmd_valid_i=1; cmd_opcode_i=op; cmd_cluster_mode_i=md; cmd_layout_i=lay;
            cmd_m_i=m; cmd_n_i=n; cmd_k_i=k; cmd_tag_i=tag;
            cmd_a_base_i=13+3*tag; cmd_b_base_i=29+5*tag; cmd_c_base_i=47+7*tag;
            cmd_a_bank_i=tag%2; cmd_b_bank_i=(tag+1)%2; cmd_c_bank_i=tag%2; cmd_op_cfg_i=tag;
            do @(posedge clk); while(!cmd_ready_o);
            @(negedge clk); cmd_valid_i=0;
        end
    endtask
    task automatic load_operands;
        integer m,n,k;
        begin
            for(m=0;m<ctx_m_o;m=m+1) for(k=0;k<ctx_k_o;k=k+1)
                mem_a[ctx_a_bank_o*STRIDE+ctx_a_base_o+m*ctx_k_o+k]=av(m,k,ctx_tag_o);
            for(k=0;k<ctx_k_o;k=k+1) for(n=0;n<ctx_n_o;n=n+1)
                mem_b[ctx_b_bank_o*STRIDE+ctx_b_base_o+k*ctx_n_o+n]=bv(k,n,ctx_tag_o);
            for(m=0;m<ctx_m_o*ctx_n_o;m=m+1) written[m]=0;
        end
    endtask
    task automatic execute_batch(output reg batch_last);
        integer mode,layout,mb,nb,gs,groups,gcols,g,ar,ac,anchor,rows,cols,r,c,k,tr,tc,t,lane;
        integer logical_m,logical_n,sum,actual;
        reg [15:0] expected_tiles,group_mask;
        begin
            while(!tile_batch_valid_o) @(negedge clk);
            repeat(ctx_tag_o%3) @(negedge clk);
            mode=tile_batch_cluster_mode_o; layout=tile_batch_layout_o;
            mb=tile_batch_m_base_o; nb=tile_batch_n_base_o; batch_last=tile_batch_cmd_last_o;
            if(tile_batch_tag_o!==ctx_tag_o || tile_batch_k_o!==ctx_k_o) $fatal(1,"batch context mismatch");
            tile_batch_ready_i=1; @(negedge clk); tile_batch_ready_i=0;
            gs=16>>mode; groups=1<<(2*mode); gcols=groups/(1<<layout);
            expected_tiles=0; group_mask=0; s_rows=0; s_cols=0;
            for(t=0;t<16;t=t+1) begin physical_rows[t]=0;physical_cols[t]=0;end
            for(g=0;g<groups;g=g+1) begin
                ar=mb+(g/gcols)*gs; ac=nb+(g%gcols)*gs;
                rows=(ctx_m_o-ar<gs)?ctx_m_o-ar:gs;
                cols=(ctx_n_o-ac<gs)?ctx_n_o-ac:gs;
                anchor=(mode==0)?0:((mode==1)?(g/2)*8+(g%2)*2:g);
                if(ar<ctx_m_o && ac<ctx_n_o) begin
                    group_mask[anchor]=1;
                    case(mode)
                        0: begin s_rows[3:0]=rows-1; s_cols[3:0]=cols-1; end
                        1: begin s_rows[g*3+:3]=rows-1; s_cols[g*3+:3]=cols-1; end
                        2: begin s_rows[g*2+:2]=rows-1; s_cols[g*2+:2]=cols-1; end
                    endcase
                    for(tr=0;tr<gs/4;tr=tr+1) for(tc=0;tc<gs/4;tc=tc+1) begin
                        t=anchor+tr*4+tc;
                        if(tr*4<rows && tc*4<cols) begin
                            expected_tiles[t]=1;physical_m[t]=ar+tr*4;physical_n[t]=ac+tc*4;
                            physical_rows[t]=(rows-tr*4<4)?rows-tr*4:4;
                            physical_cols[t]=(cols-tc*4<4)?cols-tc*4:4;
                        end
                    end
                end
            end
            // BRAM 数组模型按真实 bank/base/坐标取数，再按实际 source lane 规则送 cluster。
            for(k=0;k<ctx_k_o;k=k+1) begin
                if(k==1 && ctx_tag_o%2) begin s_valid=0;s_user=0;s_last=0;@(negedge clk);end
                a_source=0;b_source=0;
                for(g=0;g<groups;g=g+1) begin
                    ar=mb+(g/gcols)*gs;ac=nb+(g%gcols)*gs;
                    anchor=(mode==0)?0:((mode==1)?(g/2)*8+(g%2)*2:g);
                    if(ar<ctx_m_o && ac<ctx_n_o) begin
                        for(r=0;r<gs && ar+r<ctx_m_o;r=r+1) begin
                            lane=anchor+(r/4)*4;
                            a_source[(lane*4+r%4)*8+:8]=mem_a[ctx_a_bank_o*STRIDE+ctx_a_base_o+(ar+r)*ctx_k_o+k];
                        end
                        for(c=0;c<gs && ac+c<ctx_n_o;c=c+1) begin
                            lane=anchor+c/4;
                            b_source[(lane*4+c%4)*8+:8]=mem_b[ctx_b_bank_o*STRIDE+ctx_b_base_o+k*ctx_n_o+ac+c];
                        end
                    end
                end
                s_valid=group_mask;s_user=(k==0)?group_mask:0;s_last=(k==ctx_k_o-1)?group_mask:0;
                writes_pending=1;
                @(negedge clk);
            end
            s_valid=0;s_user=0;s_last=0;
            while(c_valid==0) @(negedge clk);
            if(c_valid!==expected_tiles) $fatal(1,"tile mask mismatch tag=%0d got=%h want=%h",ctx_tag_o,c_valid,expected_tiles);
            for(t=0;t<16;t=t+1) if(expected_tiles[t]) begin
                tiles_checked=tiles_checked+1;
                if(c_rows[t*2+:2]!==2'(physical_rows[t]-1) || c_cols[t*2+:2]!==2'(physical_cols[t]-1))
                    $fatal(1,"returned shape mismatch");
                for(r=0;r<physical_rows[t];r=r+1) for(c=0;c<physical_cols[t];c=c+1) begin
                    logical_m=physical_m[t]+r;logical_n=physical_n[t]+c;
                    if(logical_m>=ctx_m_o || logical_n>=ctx_n_o) $fatal(1,"reference tile outside C");
                    sum=0;
                    // 参考结果从数学函数产生，不使用 feeder lane 数据。
                    for(k=0;k<ctx_k_o;k=k+1) sum=sum+av(logical_m,k,ctx_tag_o)*bv(k,logical_n,ctx_tag_o);
                    actual=$signed(c_matrix[(((t/4)*4+r)*16+(t%4)*4+c)*32+:32]);
                    if(actual!==sum) $fatal(1,"GEMM mismatch tag=%0d M=%0d N=%0d got=%0d expected=%0d",ctx_tag_o,logical_m,logical_n,actual,sum);
                    if(written[logical_m*ctx_n_o+logical_n]) $fatal(1,"duplicate C write");
                    written[logical_m*ctx_n_o+logical_n]=1;
                    mem_c[ctx_c_bank_o*STRIDE+ctx_c_base_o+logical_m*ctx_n_o+logical_n]=actual;
                    elements_checked=elements_checked+1;
                end
            end
            @(negedge clk);
        end
    endtask
    // 行为后端只模拟缺少的独立模块；启动/分块/队列生命周期由真实 RTL 驱动。
    reg last_batch;
    integer p;
    initial begin
        wait(resetn);
        forever begin
            while(!buffer_acquire_valid_o) @(negedge clk);
            repeat(5) @(negedge clk);
            buffer_acquire_error_i=(ctx_tag_o==12);
            if(!buffer_acquire_error_i) load_operands();
            buffer_acquire_ready_i=1; @(negedge clk); buffer_acquire_ready_i=0;
            if(!buffer_acquire_error_i) begin
                while(!backend_prepare_valid_o) @(negedge clk);
                repeat(3) @(negedge clk);
                // 本测试后端只实现 GEMM；CONV 必须明确拒绝，不能用 GEMM 算术冒充卷积。
                backend_prepare_error_i=(ctx_opcode_o==1 || ctx_op_cfg_o==13);
                backend_prepare_ready_i=1;@(negedge clk);backend_prepare_ready_i=0;
                if(!backend_prepare_error_i) begin
                    while(!job_start_o) @(negedge clk);
                    executions=executions+1;
                    last_batch=0;
                    while(!last_batch) execute_batch(last_batch);
                    // 所有 C 坐标必须恰好写一次；再故意延迟写提交，防止 schedule_done 提前完成。
                    for(p=0;p<ctx_m_o*ctx_n_o;p=p+1) if(!written[p]) $fatal(1,"missing C element");
                    repeat(6) begin
                        @(negedge clk);
                        if(buffer_release_valid_o || dut.exec_done_valid_o) $fatal(1,"completed before write commit");
                    end
                    while(!cluster_idle) @(negedge clk);
                    writes_pending=0;
                    job_complete_tag_i=ctx_tag_o;job_complete_error_i=0;job_complete_valid_i=1;
                    do @(posedge clk);while(!job_complete_ready_o);
                    @(negedge clk);job_complete_valid_i=0;
                end
                while(!buffer_release_valid_o) @(negedge clk);
                repeat(3) @(negedge clk);
                buffer_release_ready_i=1;@(negedge clk);buffer_release_ready_i=0;
                backend_prepare_error_i=0;
            end
            buffer_acquire_error_i=0;
        end
    end
    integer tag,mode,layout,gs,gr,gc;
    initial begin
        repeat(4) @(negedge clk); resetn=1;
        tag=0;
        for(mode=0;mode<3;mode=mode+1) for(layout=0;layout<=2*mode;layout=layout+1) begin
            gs=16>>mode;gr=1<<layout;gc=(1<<(2*mode))/gr;
            enqueue(tag,0,mode,layout,gs*gr+3,gs*gc+1,tag%4+1);tag=tag+1;
        end
        enqueue(9,0,0,0,37,35,5);
        enqueue(10,0,0,0,0,16,3);
        enqueue(11,1,1,0,8,8,9);
        enqueue(12,0,2,0,4,4,2);
        enqueue(13,0,0,0,4,4,2);
        while(responses<JOBS) @(negedge clk);
        repeat(8) @(negedge clk);
        if(executions!=10 || executor_busy_o || dispatcher_busy_o || !queue_empty_o || !cluster_idle) $fatal(1,"joint did not finish cleanly");
        $display("NPU_V13_JOB_EXECUTOR_RUNTIME_JOINT_TB_PASS commands=%0d gemms=%0d physical_tiles=%0d elements=%0d mode_changes=%0d",responses,executions,tiles_checked,elements_checked,mode_changes);
        $finish;
    end
endmodule
