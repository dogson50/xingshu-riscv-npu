# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set project_file [file join $root_dir vivado_project npu_mydesign.xpr]

if {![file exists $project_file]} { error "Vivado project is missing: $project_file" }
open_project $project_file
set_property top tb_npu_v13_cluster_mode_ctrl_runtime_joint [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -mode behavioral
close_sim

# 保持 runtime cluster 为工程默认交互仿真顶层。
set_property top tb_npu_v13_systolic_cluster_runtime_stream [get_filesets sim_1]
update_compile_order -fileset sim_1
close_project
puts "NPU_MYDESIGN_MODE_CTRL_JOINT_PROJECT_XSIM_PASS"
