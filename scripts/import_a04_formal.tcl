# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

# Import P89-A04 as the active formal v13 architecture while preserving the old files on disk.
# May be sourced in the already-open GUI, or executed in batch with the XPR path as argv[0].
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set default_xpr [file join $project_root vivado_project npu_mydesign.xpr]
set xpr [expr {[llength $argv] >= 1 ? [file normalize [lindex $argv 0]] : $default_xpr}]
set opened_here 0
if {[llength [get_projects -quiet]] == 0} {
    open_project $xpr
    set opened_here 1
} else {
    set active_dir [file normalize [get_property DIRECTORY [current_project]]]
    set active_name [get_property NAME [current_project]]
    set active_xpr [file normalize [file join $active_dir "${active_name}.xpr"]]
    if {$active_xpr ne [file normalize $default_xpr] && $active_xpr ne $xpr} {
        error "A04 import refused: another project is open: $active_xpr"
    }
}
source [file join $script_dir a04_formal_sources.tcl]
foreach f [concat $a04_design_sources $a04_sim_sources [list $a04_xdc_200 $a04_xdc_300]] {
    if {![file exists $f]} {error "A04 import missing file: $f"}
}
set src_fs [get_filesets sources_1]
# Remove the old implementations that share module names with the frozen A04 source set.
set old_conflicts [list \
    [file join $project_root rtl/npu/v13/compute/npu_v13_dsp48e1_macc.v] \
    [file join $project_root rtl/npu/v13/compute/npu_v13_systolic_pe_stream.v] \
    [file join $project_root rtl/npu/v13/compute/npu_v13_systolic_result_delay.v] \
    [file join $project_root rtl/npu/v13/compute/npu_v13_systolic_tile_4x4_stream.v] \
    [file join $project_root rtl/npu/v13/compute/npu_v13_systolic_cluster_16x4x4_stream.v] \
    [file join $project_root rtl/npu/v13/compute/npu_v13_systolic_cluster_runtime_stream.v] \
    [file join $project_root rtl/npu/v13/control/npu_v13_cluster_mode_ctrl.v] \
    [file join $project_root rtl/npu/v13/control/npu_v13_command_fifo.sv] \
    [file join $project_root rtl/npu/v13/control/npu_v13_command_queue_dispatcher.sv] \
    [file join $project_root rtl/npu/v13/control/npu_v13_job_executor.sv] \
    [file join $project_root rtl/npu/v13/scheduler/npu_v13_gemm_tile_scheduler.sv]]
foreach f $old_conflicts {
    set obj [get_files -quiet -of_objects $src_fs $f]
    if {[llength $obj]} {remove_files -fileset $src_fs $obj}
}
add_files -norecurse -fileset $src_fs $a04_design_sources
set_property top npu_v13_gemm_feature_transport $src_fs
set_property top_auto_set 0 $src_fs

if {![llength [get_filesets -quiet sim_a04]]} {create_fileset -simset sim_a04}
set sim_fs [get_filesets sim_a04]
add_files -norecurse -fileset $sim_fs $a04_sim_sources
set_property source_set sources_1 $sim_fs
set_property top tb_gemm_feature_transport $sim_fs
set_property top_auto_set 0 $sim_fs
set_property xsim.simulate.runtime all $sim_fs
set_property xsim.simulate.log_all_signals false $sim_fs
current_fileset -simset $sim_fs

foreach pair [list [list constrs_a04_200m $a04_xdc_200] [list constrs_a04_300m $a04_xdc_300]] {
    lassign $pair cs_name xdc
    if {![llength [get_filesets -quiet $cs_name]]} {create_fileset -constrset $cs_name}
    add_files -norecurse -fileset [get_filesets $cs_name] $xdc
    set_property target_constrs_file $xdc [get_filesets $cs_name]
}

set part [get_property PART [current_project]]
set synth_flow [get_property FLOW [get_runs synth_1]]
set synth_strategy [get_property STRATEGY [get_runs synth_1]]
set impl_flow [get_property FLOW [get_runs impl_1]]
set impl_strategy [get_property STRATEGY [get_runs impl_1]]
foreach mhz {200 300} {
    set sr synth_a04_${mhz}m
    set ir impl_a04_${mhz}m
    set cs constrs_a04_${mhz}m
    if {![llength [get_runs -quiet $sr]]} {
        create_run $sr -part $part -flow $synth_flow -strategy $synth_strategy -constrset $cs
    }
    if {![llength [get_runs -quiet $ir]]} {
        create_run $ir -part $part -flow $impl_flow -strategy $impl_strategy -constrset $cs -parent_run $sr
    }
}
current_run -synthesis [get_runs synth_a04_200m]
current_run -implementation [get_runs impl_a04_200m]
update_compile_order -fileset $src_fs
update_compile_order -fileset $sim_fs
puts "A04_FORMAL_IMPORT_PASS design_files=[llength [get_files -of_objects $src_fs]] sim_files=[llength [get_files -of_objects $sim_fs]] top=[get_property TOP $src_fs] sim_top=[get_property TOP $sim_fs]"
puts "A04_RUNS [join [get_runs -quiet *a04*] { }]"
if {$opened_here} {close_project}

