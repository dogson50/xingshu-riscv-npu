# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set project_dir [file join $root_dir vivado_project]
set project_name npu_mydesign
set part_name xc7a200tfbg484-2

create_project -force $project_name $project_dir -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

set rtl_files [list \
    [file join $root_dir rtl v13 compute npu_v13_dsp48e1_macc.v] \
    [file join $root_dir rtl v13 compute npu_v13_systolic_pe_stream.v] \
    [file join $root_dir rtl v13 compute npu_v13_systolic_result_delay.v] \
    [file join $root_dir rtl v13 compute npu_v13_systolic_tile_4x4_stream.v] \
    [file join $root_dir rtl v13 compute npu_v13_systolic_cluster_16x4x4_stream.v] \
    [file join $root_dir rtl v13 compute npu_v13_systolic_cluster_runtime_stream.v] \
    [file join $root_dir rtl v13 control npu_v13_cluster_mode_ctrl.v] \
    [file join $root_dir rtl v13 control npu_v13_command_fifo.sv] \
    [file join $root_dir rtl v13 control npu_v13_command_queue_dispatcher.sv] \
    [file join $root_dir rtl v13 control npu_v13_job_executor.sv] \
    [file join $root_dir rtl v13 scheduler npu_v13_gemm_tile_scheduler.sv] \
    [file join $root_dir rtl v13 memory npu_v13_buffer_manager.sv] \
    [file join $root_dir rtl v13 memory npu_v13_bram_bank.sv]]

set sim_files [list \
    [file join $root_dir tb v13 tb_npu_v13_systolic_tile_4x4_stream.sv] \
    [file join $root_dir tb v13 tb_npu_v13_systolic_cluster_16x4x4_stream.sv] \
    [file join $root_dir tb v13 tb_npu_v13_systolic_cluster_runtime_stream.sv] \
    [file join $root_dir tb v13 tb_npu_v13_cluster_mode_ctrl.sv] \
    [file join $root_dir tb v13 tb_npu_v13_cluster_mode_ctrl_runtime_joint.sv] \
    [file join $root_dir tb v13 tb_npu_v13_gemm_tile_scheduler.sv] \
    [file join $root_dir tb v13 tb_npu_v13_command_fifo.sv] \
    [file join $root_dir tb v13 tb_npu_v13_command_queue_dispatcher.sv] \
    [file join $root_dir tb v13 tb_npu_v13_command_dispatcher_runtime_joint.sv] \
    [file join $root_dir tb v13 npu_v13_command_executor_timing_top.sv] \
    [file join $root_dir tb v13 tb_npu_v13_job_executor.sv] \
    [file join $root_dir tb v13 tb_npu_v13_job_executor_runtime_joint.sv] \
    [file join $root_dir tb v13 tb_npu_v13_bram_bank.sv] \
    [file join $root_dir tb v13 tb_npu_v13_buffer_manager.sv] \
    [file join $root_dir tb v13 tb_npu_v13_buffer_bram_runtime_joint.sv] \
    [file join $root_dir tb v13 npu_v13_memory_timing_top.sv]]

set constraint_file [file join $root_dir constraints npu_v13_300m.xdc]
foreach f [concat $rtl_files $sim_files [list $constraint_file]] {
    if {![file exists $f]} { error "Required project source is missing: $f" }
}

add_files -norecurse -fileset sources_1 $rtl_files
add_files -norecurse -fileset constrs_1 $constraint_file
add_files -norecurse -fileset sim_1 $sim_files
foreach f $sim_files {
    set_property file_type SystemVerilog [get_files $f]
}

# 命令装载路径约束：只对实际存在的 executor 实例生效，不影响 runtime 默认顶层。
# 仅实现阶段使用；SCOPED_TO_REF 防止未实例化该模块的工程出现空匹配约束。
set executor_xdc [file normalize [file join $root_dir constraints npu_v13_job_executor_context.xdc]]
if {![file exists $executor_xdc]} {error "Missing executor context constraint: $executor_xdc"}
if {[llength [get_files -quiet $executor_xdc]] == 0} {
    add_files -norecurse -fileset constrs_1 $executor_xdc
}
set_property SCOPED_TO_REF npu_v13_job_executor [get_files $executor_xdc]
set_property USED_IN_SYNTHESIS false [get_files $executor_xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $executor_xdc]
set_property PROCESSING_ORDER LATE [get_files $executor_xdc]

set_property top npu_v13_systolic_cluster_runtime_stream [get_filesets sources_1]
set_property top tb_npu_v13_systolic_cluster_runtime_stream [get_filesets sim_1]
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set summary [open [file join $project_dir PROJECT_INFO.txt] w]
puts $summary "project=$project_name"
puts $summary "part=$part_name"
puts $summary "synth_top=npu_v13_systolic_cluster_runtime_stream"
puts $summary "sim_top=tb_npu_v13_systolic_cluster_runtime_stream"
puts $summary "clock_target_mhz=300"
puts $summary "rtl_files=[llength $rtl_files]"
puts $summary "sim_files=[llength $sim_files]"
close $summary

close_project
puts "NPU_MYDESIGN_RUNTIME_PROJECT_PASS path=[file join $project_dir ${project_name}.xpr]"
