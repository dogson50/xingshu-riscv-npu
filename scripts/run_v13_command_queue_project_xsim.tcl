# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set project_file [file join $root_dir vivado_project npu_mydesign.xpr]
set report_dir [file join $root_dir reports v13_command_queue_xsim]
file mkdir $report_dir

if {![file exists $project_file]} {
    error "Vivado project is missing: $project_file"
}

open_project $project_file
set_property xsim.simulate.runtime all [get_filesets sim_1]

# 每个层次都使用 Vivado 工程中的同一份 RTL/TB：先验证纯 FIFO，再验证统一
# dispatcher，最后验证 dispatcher 的 cfg 端口与真实 runtime cluster 逐线连接。
set tests [list \
    [list tb_npu_v13_command_fifo \
          NPU_V13_COMMAND_FIFO_TB_PASS command_fifo.log] \
    [list tb_npu_v13_command_queue_dispatcher \
          NPU_V13_COMMAND_QUEUE_DISPATCHER_TB_PASS command_dispatcher.log] \
    [list tb_npu_v13_command_dispatcher_runtime_joint \
          NPU_V13_COMMAND_DISPATCHER_RUNTIME_JOINT_TB_PASS \
          command_dispatcher_runtime_joint.log]]

foreach test $tests {
    lassign $test top_name pass_marker saved_log_name
    set_property top $top_name [get_filesets sim_1]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
    launch_simulation -mode behavioral
    close_sim

    set sim_log [file join $root_dir vivado_project npu_mydesign.sim \
        sim_1 behav xsim simulate.log]
    if {![file exists $sim_log]} {
        error "XSim log is missing for $top_name: $sim_log"
    }
    set log_file [open $sim_log r]
    set log_text [read $log_file]
    close $log_file
    file copy -force $sim_log [file join $report_dir $saved_log_name]

    if {[string first $pass_marker $log_text] < 0} {
        error "$top_name did not emit PASS marker $pass_marker"
    }
    if {[regexp {(^|[[:space:]])(ERROR|FAIL)([[:space:]:]|$)|_FAIL|TB_TIMEOUT|FATAL:} \
                $log_text]} {
        error "$top_name XSim log contains a failure marker"
    }
}

# 恢复工程平时打开时使用的 runtime cluster 仿真顶层。
set_property top tb_npu_v13_systolic_cluster_runtime_stream \
    [get_filesets sim_1]
update_compile_order -fileset sim_1
close_project
puts "NPU_MYDESIGN_COMMAND_QUEUE_PROJECT_XSIM_PASS checks=3"
