# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set project_file [file join $root_dir vivado_project npu_mydesign.xpr]

if {![file exists $project_file]} { error "Vivado project is missing: $project_file" }
open_project $project_file
set_property top tb_npu_v13_systolic_cluster_runtime_stream [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -mode behavioral
close_sim
close_project
puts "NPU_MYDESIGN_RUNTIME_PROJECT_XSIM_PASS"
