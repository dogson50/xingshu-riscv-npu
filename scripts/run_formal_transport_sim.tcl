# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

# Run one current-formal 64-bit GEMM feature-transport case from the explicit source manifest.
# Usage: vivado -mode batch -source run_formal_transport_sim.tcl -tclargs STALL RESET_ABORT TAG
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
set stall [lindex $argv 0]
set reset_abort [lindex $argv 1]
set tag [lindex $argv 2]
if {$stall ni {0 1} || $reset_abort ni {0 1}} {
    error "usage: run_formal_transport_sim.tcl 0|1 0|1 ?tag?"
}
if {$tag eq ""} {set tag [clock format [clock seconds] -format %Y%m%d_%H%M%S]}
if {![regexp {^[A-Za-z0-9_-]+$} $tag]} {error "invalid tag"}
source [file join $script_dir a04_formal_sources.tcl]
set tb ""
foreach f $a04_sim_sources {
    if {[file tail $f] eq "tb_gemm_feature_transport.sv"} {set tb $f}
}
if {$tb eq "" || ![file exists $tb]} {error "formal transport TB missing"}
foreach f [concat $a04_design_sources [list $tb]] {
    if {![file exists $f]} {error "formal transport source missing: $f"}
}
set run_name formal_transport_${stall}_${reset_abort}_${tag}
set build [file join $project_root build formal_transport $run_name]
if {[file exists $build]} {error "refuse overwrite: $build"}
create_project $run_name $build -part xc7a200tfbg484-2
add_files -norecurse $a04_design_sources
add_files -norecurse -fileset sim_1 $tb
set_property top tb_gemm_feature_transport [get_filesets sim_1]
set_property generic "TRANSPORT_W=64 STALL=$stall RESET_ABORT=$reset_abort" [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
set_property xsim.elaborate.debug_level typical [get_filesets sim_1]
launch_simulation
close_sim
close_project
puts "FORMAL_TRANSPORT_SIM_DONE stall=$stall reset_abort=$reset_abort build=$build"
