// SPDX-License-Identifier: CERN-OHL-P-2.0
// Copyright (c) 2026 XingShu Project Contributors

`timescale 1ns/1ps
// 单元测试包含真实 scheduler；外部 bank manager/后端用可反压协议模型替代。
// 这里不声称执行了真实 GEMM/CONV 数据通路；另有 runtime 联合测试。
module tb_npu_v13_job_executor;
    localparam DIM_W=16, ADDR_W=32, BANK_W=2, OP_CFG_W=32, TAG_W=8;
    localparam CTX_W=2+3*DIM_W+2+3+3*ADDR_W+3*BANK_W+OP_CFG_W+TAG_W;
    localparam BATCH_W=5*DIM_W+2+3+2+TAG_W;
    reg  clk = 0;
    reg  resetn = 0;
    reg  exec_cmd_valid_i = 0;
    wire  exec_cmd_ready_o;
    reg [1:0] exec_cmd_opcode_i = 0;
    reg [DIM_W-1:0] exec_cmd_m_i = 0;
    reg [DIM_W-1:0] exec_cmd_n_i = 0;
    reg [DIM_W-1:0] exec_cmd_k_i = 0;
    reg [1:0] exec_cmd_cluster_mode_i = 0;
    reg [2:0] exec_cmd_layout_i = 0;
    reg [ADDR_W-1:0] exec_cmd_a_base_i = 0;
    reg [ADDR_W-1:0] exec_cmd_b_base_i = 0;
    reg [ADDR_W-1:0] exec_cmd_c_base_i = 0;
    reg [BANK_W-1:0] exec_cmd_a_bank_i = 0;
    reg [BANK_W-1:0] exec_cmd_b_bank_i = 0;
    reg [BANK_W-1:0] exec_cmd_c_bank_i = 0;
    reg [OP_CFG_W-1:0] exec_cmd_op_cfg_i = 0;
    reg [TAG_W-1:0] exec_cmd_tag_i = 0;
    wire  exec_done_valid_o;
    reg  exec_done_ready_i = 0;
    wire [TAG_W-1:0] exec_done_tag_o;
    wire  exec_done_error_o;
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
    wire  busy_o;
    always #5 clk=~clk;
    npu_v13_job_executor #(.DIM_W(DIM_W),.ADDR_W(ADDR_W),.BANK_W(BANK_W),
        .OP_CFG_W(OP_CFG_W),.TAG_W(TAG_W)) dut (
        .clk(clk),
        .resetn(resetn),
        .exec_cmd_valid_i(exec_cmd_valid_i),
        .exec_cmd_ready_o(exec_cmd_ready_o),
        .exec_cmd_opcode_i(exec_cmd_opcode_i),
        .exec_cmd_m_i(exec_cmd_m_i),
        .exec_cmd_n_i(exec_cmd_n_i),
        .exec_cmd_k_i(exec_cmd_k_i),
        .exec_cmd_cluster_mode_i(exec_cmd_cluster_mode_i),
        .exec_cmd_layout_i(exec_cmd_layout_i),
        .exec_cmd_a_base_i(exec_cmd_a_base_i),
        .exec_cmd_b_base_i(exec_cmd_b_base_i),
        .exec_cmd_c_base_i(exec_cmd_c_base_i),
        .exec_cmd_a_bank_i(exec_cmd_a_bank_i),
        .exec_cmd_b_bank_i(exec_cmd_b_bank_i),
        .exec_cmd_c_bank_i(exec_cmd_c_bank_i),
        .exec_cmd_op_cfg_i(exec_cmd_op_cfg_i),
        .exec_cmd_tag_i(exec_cmd_tag_i),
        .exec_done_valid_o(exec_done_valid_o),
        .exec_done_ready_i(exec_done_ready_i),
        .exec_done_tag_o(exec_done_tag_o),
        .exec_done_error_o(exec_done_error_o),
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
        .busy_o(busy_o)
    );
    wire [CTX_W-1:0] ctx_bundle={ctx_opcode_o,ctx_m_o,ctx_n_o,ctx_k_o,ctx_cluster_mode_o,ctx_layout_o,ctx_a_base_o,ctx_b_base_o,ctx_c_base_o,ctx_a_bank_o,ctx_b_bank_o,ctx_c_bank_o,ctx_op_cfg_o,ctx_tag_o};
    wire [CTX_W-1:0] cmd_bundle={exec_cmd_opcode_i,exec_cmd_m_i,exec_cmd_n_i,exec_cmd_k_i,exec_cmd_cluster_mode_i,exec_cmd_layout_i,exec_cmd_a_base_i,exec_cmd_b_base_i,exec_cmd_c_base_i,exec_cmd_a_bank_i,exec_cmd_b_bank_i,exec_cmd_c_bank_i,exec_cmd_op_cfg_i,exec_cmd_tag_i};
    wire [BATCH_W-1:0] batch_bundle={tile_batch_m_o,tile_batch_n_o,tile_batch_k_o,
        tile_batch_m_base_o,tile_batch_n_base_o,tile_batch_cluster_mode_o,tile_batch_layout_o,
        tile_batch_cmd_first_o,tile_batch_cmd_last_o,tile_batch_tag_o};
    reg [CTX_W-1:0] expected_ctx;
    reg [BATCH_W-1:0] stalled_batch;
    reg stalled=0;
    integer cases=0, total_batches=0, cycles=0, accepted=0, returned=0, minimum_launches=0;
    integer batches=0, starts=0, acquires=0, releases=0, completed=0;
    integer step_m,step_n,ref_m,ref_n,expected_batches,prev_batch_cycle;
    integer d_m,d_n,d_k,d_mode,d_layout,d_tag,context_capture_cycle;
    reg check_ii=0;
    reg expect_ctx_valid=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        if (!resetn) begin stalled=0; expect_ctx_valid=0; end
        else begin
            if (ctx_valid_o && expect_ctx_valid && ctx_bundle !== expected_ctx)
                $fatal(1,"context changed while command owned");
            if (exec_cmd_valid_i && exec_cmd_ready_o) begin
                expected_ctx=cmd_bundle; expect_ctx_valid=1; accepted=accepted+1;
                context_capture_cycle=cycles;
                batches=0; starts=0; acquires=0; releases=0; completed=0; prev_batch_cycle=-1;
                d_m=exec_cmd_m_i; d_n=exec_cmd_n_i; d_k=exec_cmd_k_i;
                d_mode=exec_cmd_cluster_mode_i; d_layout=exec_cmd_layout_i; d_tag=exec_cmd_tag_i;
                // 独立几何参考：group 大小与 group 的行列数，不复刻 RTL 的计数算法。
                step_m=(16>>d_mode)*(1<<d_layout);
                step_n=(16>>d_mode)*((1<<(2*d_mode))/(1<<d_layout));
                expected_batches=0;
                if(step_m>0 && step_n>0) expected_batches=((d_m+step_m-1)/step_m)*((d_n+step_n-1)/step_n);
                ref_m=0; ref_n=0;
            end
            if (busy_o && exec_cmd_ready_o) $fatal(1,"accepted overlapping command");
            if (buffer_acquire_valid_o && buffer_acquire_ready_i && !buffer_acquire_error_i) acquires=acquires+1;
            if (job_start_o) begin
                if(cycles-context_capture_cycle<4) $fatal(1,"context stable-window contract broken");
                if(cycles-context_capture_cycle==4) minimum_launches=minimum_launches+1;
                starts=starts+1;
                if (!buffers_owned_o || starts!=1) $fatal(1,"start without bank or duplicate start");
            end
            if (stalled && (!tile_batch_valid_o || batch_bundle !== stalled_batch)) $fatal(1,"unstable stalled batch");
            stalled=tile_batch_valid_o && !tile_batch_ready_i;
            stalled_batch=batch_bundle;
            if (tile_batch_valid_o && tile_batch_ready_i) begin
                if (starts!=1 || !buffers_owned_o) $fatal(1,"batch before start/reservation");
                if ({tile_batch_m_o,tile_batch_n_o,tile_batch_k_o} !== {DIM_W'(d_m),DIM_W'(d_n),DIM_W'(d_k)} ||
                    tile_batch_cluster_mode_o!==2'(d_mode) || tile_batch_layout_o!==3'(d_layout) || tile_batch_tag_o!==TAG_W'(d_tag) ||
                    tile_batch_m_base_o!==DIM_W'(ref_m) || tile_batch_n_base_o!==DIM_W'(ref_n) ||
                    tile_batch_cmd_first_o !== (batches==0) || tile_batch_cmd_last_o !== (batches==expected_batches-1))
                    $fatal(1,"batch mismatch case=%0d index=%0d base=%0d/%0d expected=%0d/%0d",cases,batches,tile_batch_m_base_o,tile_batch_n_base_o,ref_m,ref_n);
                if(check_ii && prev_batch_cycle>=0 && cycles-prev_batch_cycle!=1) $fatal(1,"batch II not one");
                prev_batch_cycle=cycles; batches=batches+1; total_batches=total_batches+1;
                ref_n=ref_n+step_n;
                if(ref_n>=d_n) begin ref_n=0; ref_m=ref_m+step_m; end
            end
            if(job_complete_ready_o && !schedule_finished_o) $fatal(1,"completion accepted before schedule ends");
            if(job_complete_valid_i && job_complete_ready_o && job_complete_tag_i==ctx_tag_o) completed=completed+1;
            if(buffer_release_valid_o && buffer_release_ready_i) begin
                releases=releases+1;
                if(!buffers_owned_o || acquires!=1) $fatal(1,"release without acquire");
                if(starts!=0 && completed!=1) $fatal(1,"release before safe completion");
            end
            if(exec_done_valid_o) begin
                if(buffers_owned_o || tile_batch_valid_o) $fatal(1,"done while resources active");
                if(exec_done_tag_o!==TAG_W'(d_tag)) $fatal(1,"wrong done tag");
                if(exec_done_ready_i) begin returned=returned+1; expect_ctx_valid=0; end
            end
        end
        if(cycles>300000) $fatal(1,"TB_TIMEOUT");
    end
    task automatic reset_all;
        begin
            @(negedge clk); resetn=0; exec_cmd_valid_i=0; exec_done_ready_i=0;
            buffer_acquire_ready_i=0; buffer_acquire_error_i=0;
            backend_prepare_ready_i=0; backend_prepare_error_i=0;
            buffer_release_ready_i=0; tile_batch_ready_i=0; job_complete_valid_i=0;
            job_complete_error_i=0;
            repeat(3) @(negedge clk);
            if(exec_cmd_ready_o || exec_done_valid_o || buffer_acquire_valid_o || buffer_release_valid_o ||
               backend_prepare_valid_o || job_start_o || tile_batch_valid_o || job_complete_ready_o || busy_o)
                $fatal(1,"reset exposed transaction");
            resetn=1; @(negedge clk);
        end
    endtask
    task automatic submit(input integer op,md,lay,m,n,k,tag);
        begin
            @(negedge clk);
            exec_cmd_opcode_i=op; exec_cmd_cluster_mode_i=md; exec_cmd_layout_i=lay;
            exec_cmd_m_i=m; exec_cmd_n_i=n; exec_cmd_k_i=k; exec_cmd_tag_i=tag;
            exec_cmd_a_base_i=$random; exec_cmd_b_base_i=$random; exec_cmd_c_base_i=$random;
            exec_cmd_a_bank_i=tag; exec_cmd_b_bank_i=tag+1; exec_cmd_c_bank_i=tag+2; exec_cmd_op_cfg_i=$random;
            exec_cmd_valid_i=1;
            do @(posedge clk); while(!exec_cmd_ready_o);
            @(negedge clk); exec_cmd_valid_i=0;
            // 握手后立即破坏输入，确保执行不再偷读 FIFO 头。
            exec_cmd_m_i=0; exec_cmd_a_base_i=32'hdeadbeef; exec_cmd_tag_i=~tag;
        end
    endtask
    task automatic acquire(input integer reject);
        begin
            while(!buffer_acquire_valid_o) @(negedge clk);
            repeat(check_ii ? 0 : 3) @(negedge clk);
            if(buffers_owned_o || job_start_o) $fatal(1,"started before atomic grant");
            buffer_acquire_error_i=reject; buffer_acquire_ready_i=1;
            @(negedge clk); buffer_acquire_ready_i=0; buffer_acquire_error_i=0;
        end
    endtask
    task automatic prepare(input integer reject);
        begin
            while(!backend_prepare_valid_o) @(negedge clk);
            repeat(check_ii ? 0 : 2) @(negedge clk);
            backend_prepare_error_i=reject; backend_prepare_ready_i=1;
            @(negedge clk); backend_prepare_ready_i=0; backend_prepare_error_i=0;
        end
    endtask
    task automatic release_and_response(input integer err,has_bank);
        begin
            if(has_bank) begin
                while(!buffer_release_valid_o) @(negedge clk);
                repeat(4) begin
                    @(negedge clk);
                    if(exec_done_valid_o || !buffers_owned_o || buffer_release_error_o!==1'(err)) $fatal(1,"release stall unsafe");
                end
                buffer_release_ready_i=1; @(negedge clk); buffer_release_ready_i=0;
            end
            while(!exec_done_valid_o) @(negedge clk);
            repeat(4) begin
                @(negedge clk);
                if(!exec_done_valid_o || exec_done_error_o!==1'(err) || exec_cmd_ready_o) $fatal(1,"unstable/wrong done");
            end
            exec_done_ready_i=1; @(negedge clk); exec_done_ready_i=0;
            repeat(2) @(negedge clk);
            if(busy_o || exec_done_valid_o || releases!=has_bank) $fatal(1,"command failed to retire once");
            cases=cases+1;
        end
    endtask
    // variant: 0=无气泡描述符；1=随机反压；2=过早的完成通知被阻塞；3=错误 tag；4=执行错误。
    task automatic execute_case(input integer op,md,lay,m,n,k,variant);
        begin
            check_ii=(variant==0);
            submit(op,md,lay,m,n,k,cases);
            acquire(0); prepare(0);
            while(!job_start_o) @(negedge clk);
            job_complete_tag_i=ctx_tag_o; job_complete_error_i=(variant==4);
            if(variant==2) begin
                job_complete_valid_i=1;
                repeat(3) begin
                    @(negedge clk);
                    if(job_complete_ready_o || buffer_release_valid_o) $fatal(1,"early done bypassed pending batches");
                end
            end
            while(!schedule_finished_o) begin
                tile_batch_ready_i=(variant==1) ? ($urandom_range(0,3)!=0) : 1;
                @(negedge clk);
            end
            tile_batch_ready_i=0;
            if(batches!=expected_batches) $fatal(1,"missing batches");
            if(variant!=2) begin
                repeat(6) begin
                    @(negedge clk);
                    if(exec_done_valid_o || buffer_release_valid_o || !buffers_owned_o) $fatal(1,"schedule_done became exec_done");
                end
                if(variant==3) begin
                    job_complete_tag_i=ctx_tag_o+1; job_complete_valid_i=1;
                    @(negedge clk); job_complete_valid_i=0;
                    if(buffer_release_valid_o || !buffers_owned_o) $fatal(1,"wrong-tag completion released banks");
                end
                job_complete_tag_i=ctx_tag_o; job_complete_valid_i=1;
            end
            do @(posedge clk); while(!job_complete_ready_o);
            @(negedge clk); job_complete_valid_i=0;
            release_and_response(variant==3 || variant==4,1);
        end
    endtask
    integer md,lay,j;
    initial begin
        reset_all();
        for(md=0;md<3;md=md+1) for(lay=0;lay<=2*md;lay=lay+1) begin
            execute_case(0,md,lay,37,71,1,0);
            execute_case(0,md,lay,19,33,65535,1);
        end
        execute_case(0,0,0,1,1,1,2);
        execute_case(0,2,4,131,9,17,3);
        execute_case(0,1,1,33,21,9,4);
        // CONV 等效维度控制握手可复用；此项不验证窗口/算术。
        execute_case(1,0,0,17,19,27,1);
        for(j=0;j<30;j=j+1) begin
            md=$urandom_range(0,2); lay=$urandom_range(0,2*md);
            execute_case(0,md,lay,$urandom_range(1,180),$urandom_range(1,180),$urandom_range(1,65535),j%2);
        end
        submit(2,0,0,16,16,16,cases); release_and_response(1,0);
        submit(0,3,0,16,16,16,cases); release_and_response(1,0);
        submit(0,0,1,16,16,16,cases); release_and_response(1,0);
        submit(0,1,3,16,16,16,cases); release_and_response(1,0);
        submit(0,2,5,16,16,16,cases); release_and_response(1,0);
        submit(0,0,0,0,16,16,cases); release_and_response(1,0);
        submit(0,0,0,16,0,16,cases); release_and_response(1,0);
        submit(0,0,0,16,16,0,cases); release_and_response(1,0);
        submit(0,0,0,16,16,16,cases); acquire(1); release_and_response(1,0);
        submit(1,0,0,16,16,27,cases); acquire(0); prepare(1); release_and_response(1,1);
        // 同步整个子系统的 reset：覆盖等待 bank、后端、运行反压、释放、响应。
        submit(0,0,0,17,17,7,200); while(!buffer_acquire_valid_o) @(negedge clk); reset_all();
        submit(0,0,0,17,17,7,201); acquire(0); reset_all();
        submit(0,0,0,17,17,7,202); acquire(0); prepare(0);
        while(!tile_batch_valid_o) @(negedge clk); repeat(3) @(negedge clk); reset_all();
        submit(1,0,0,17,17,7,203); acquire(0); prepare(1);
        while(!buffer_release_valid_o) @(negedge clk); reset_all();
        submit(0,0,0,0,1,1,204); while(!exec_done_valid_o) @(negedge clk); reset_all();
        execute_case(0,0,0,17,19,5,0);
        if(accepted!=returned+5) $fatal(1,"lost/duplicate completion beyond 5 reset-aborted commands");
        if(minimum_launches==0) $fatal(1,"minimum four-cycle launch was not exercised");
        $display("NPU_V13_JOB_EXECUTOR_TB_PASS cases=%0d batches=%0d accepted=%0d returned=%0d reset_aborted=5 no_stall_batch_ii=1",cases,total_batches,accepted,returned);
        $finish;
    end
endmodule
