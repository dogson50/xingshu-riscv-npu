# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set project_file [file join $root_dir vivado_project npu_mydesign.xpr]

set rtl_files [list \
    [file normalize [file join $root_dir rtl v13 compute npu_v13_dsp48e1_macc.v]] \
    [file normalize [file join $root_dir rtl v13 compute npu_v13_systolic_pe_stream.v]] \
    [file normalize [file join $root_dir rtl v13 compute npu_v13_systolic_result_delay.v]] \
    [file normalize [file join $root_dir rtl v13 compute npu_v13_systolic_tile_4x4_stream.v]] \
    [file normalize [file join $root_dir rtl v13 compute npu_v13_systolic_cluster_16x4x4_stream.v]] \
    [file normalize [file join $root_dir rtl v13 compute npu_v13_systolic_cluster_runtime_stream.v]] \
    [file normalize [file join $root_dir rtl v13 control npu_v13_cluster_mode_ctrl.v]] \
    [file normalize [file join $root_dir rtl v13 control npu_v13_command_fifo.sv]] \
    [file normalize [file join $root_dir rtl v13 control npu_v13_command_queue_dispatcher.sv]] \
    [file normalize [file join $root_dir rtl v13 control npu_v13_job_executor.sv]] \
    [file normalize [file join $root_dir rtl v13 scheduler npu_v13_gemm_tile_scheduler.sv]] \
    [file normalize [file join $root_dir rtl v13 memory npu_v13_buffer_manager.sv]] \
    [file normalize [file join $root_dir rtl v13 memory npu_v13_bram_bank.sv]]]
set sim_files [list \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_systolic_tile_4x4_stream.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_systolic_cluster_16x4x4_stream.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_systolic_cluster_runtime_stream.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_cluster_mode_ctrl.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_cluster_mode_ctrl_runtime_joint.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_gemm_tile_scheduler.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_command_fifo.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_command_queue_dispatcher.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_command_dispatcher_runtime_joint.sv]] \
    [file normalize [file join $root_dir tb v13 npu_v13_command_executor_timing_top.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_job_executor.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_job_executor_runtime_joint.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_bram_bank.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_buffer_manager.sv]] \
    [file normalize [file join $root_dir tb v13 tb_npu_v13_buffer_bram_runtime_joint.sv]] \
    [file normalize [file join $root_dir tb v13 npu_v13_memory_timing_top.sv]]]

if {![file exists $project_file]} { error "Vivado project is missing: $project_file" }
foreach f [concat $rtl_files $sim_files] {
    if {![file exists $f]} { error "Required runtime source is missing: $f" }
}

open_project $project_file
foreach f $rtl_files {
    if {[llength [get_files -quiet $f]] == 0} {
        add_files -norecurse -fileset sources_1 $f
    }
}
foreach f $sim_files {
    if {[llength [get_files -quiet $f]] == 0} {
        add_files -norecurse -fileset sim_1 $f
    }
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
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set registered 1
foreach f [concat $rtl_files $sim_files] {
    if {[llength [get_files -quiet $f]] != 1} { set registered 0 }
}

set summary [open [file join $root_dir vivado_project PROJECT_INFO.txt] w]
puts $summary "project=npu_mydesign"
puts $summary "part=[get_property PART [current_project]]"
puts $summary "synth_top=[get_property TOP [get_filesets sources_1]]"
puts $summary "sim_top=[get_property TOP [get_filesets sim_1]]"
puts $summary "clock_target_mhz=300"
puts $summary "rtl_files=[llength $rtl_files]"
puts $summary "sim_files=[llength $sim_files]"
close $summary

close_project
if {!$registered} { error "Runtime project source registration failed" }
puts "NPU_MYDESIGN_RUNTIME_PROJECT_SYNC_PASS rtl=[llength $rtl_files] tb=[llength $sim_files]"
