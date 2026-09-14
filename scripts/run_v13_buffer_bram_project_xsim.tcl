# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set root_dir [file dirname [file dirname [file normalize [info script]]]]
set project_file [file join $root_dir vivado_project npu_mydesign.xpr]
set report_dir [file join $root_dir reports v13_buffer_bram_xsim]
file mkdir $report_dir
if {![file exists $project_file]} {error "Missing project: $project_file"}
open_project $project_file
set previous_sim_top [get_property TOP [get_filesets sim_1]]
set previous_runtime [get_property xsim.simulate.runtime [get_filesets sim_1]]
set tests [list \
    [list tb_npu_v13_bram_bank NPU_V13_BRAM_BANK_TB_PASS bram_bank.log] \
    [list tb_npu_v13_buffer_manager NPU_V13_BUFFER_MANAGER_TB_PASS buffer_manager.log] \
    [list tb_npu_v13_buffer_bram_runtime_joint NPU_V13_BUFFER_BRAM_RUNTIME_JOINT_TB_PASS buffer_bram_runtime_joint.log]]
# 出错时也恢复用户原仿真顶层。这里只运行行为仿真，不改变综合顶层。
set test_status [catch {
    set_property xsim.simulate.runtime all [get_filesets sim_1]
    foreach test $tests {
        lassign $test top_name pass_marker saved_log_name
        set_property TOP $top_name [get_filesets sim_1]
        update_compile_order -fileset sources_1
        update_compile_order -fileset sim_1
        launch_simulation -mode behavioral
        close_sim
        set sim_log [file join $root_dir vivado_project npu_mydesign.sim sim_1 behav xsim simulate.log]
        if {![file exists $sim_log]} {error "Missing XSim log for $top_name"}
        set f [open $sim_log r]
        set text [read $f]
        close $f
        file copy -force $sim_log [file join $report_dir $saved_log_name]
        if {[string first $pass_marker $text] < 0} {error "Missing PASS for $top_name"}
        if {[regexp {(^|[[:space:]])(ERROR|FAIL)([[:space:]:]|$)|_FAIL|TB_TIMEOUT|FATAL:} $text]} {
            error "Failure marker in $top_name log"
        }
    }
} test_error test_options]
catch {close_sim}
set_property TOP $previous_sim_top [get_filesets sim_1]
set_property xsim.simulate.runtime $previous_runtime [get_filesets sim_1]
update_compile_order -fileset sim_1
close_project
if {$test_status != 0} {return -options $test_options $test_error}
puts "NPU_MYDESIGN_BUFFER_BRAM_PROJECT_XSIM_PASS checks=3"


