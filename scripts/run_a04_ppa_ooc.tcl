# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

# Reproduce the current S2-N1 formal OOC PPA run using the registered timing fixture.
# Usage: vivado -mode batch -source run_a04_ppa_ooc.tcl -tclargs 200|300 optional_tag
set mhz [lindex $argv 0]
set tag [lindex $argv 1]
if {$mhz ni {200 300}} {error "usage: run_a04_ppa_ooc.tcl 200|300 ?tag?"}
if {$tag eq ""} {set tag [clock format [clock seconds] -format %Y%m%d_%H%M%S]}
if {![regexp {^[A-Za-z0-9_-]+$} $tag]} {error "tag must contain only letters, digits, underscore, or hyphen"}
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ..]]
source [file join $script_dir a04_formal_sources.tcl]
set run_name a04_ppa_${mhz}m_${tag}
set build [file join $project_root vivado_project a04_ppa $run_name]
set reports [file join $project_root reports a04 $run_name]
if {[file exists $build] || [file exists $reports]} {error "refuse overwrite: $run_name"}
file mkdir $reports
set fixture [file join $project_root tb/unit/npu/v13/gemm_feature_transport_timing.sv]
set xdc [expr {$mhz == 200 ? $a04_ppa_xdc_200 : $a04_ppa_xdc_300}]
create_project $run_name $build -part xc7a200tfbg484-2
add_files -norecurse [concat $a04_design_sources [list $fixture]]
add_files -norecurse -fileset constrs_1 $xdc
set_property top gemm_feature_transport_timing [current_fileset]
set_param general.maxThreads 4
synth_design -generic {TRANSPORT_W=64} -mode out_of_context -top gemm_feature_transport_timing \
    -part xc7a200tfbg484-2 -flatten_hierarchy rebuilt -directive PerformanceOptimized
report_utilization -hierarchical -file [file join $reports utilization_synth.rpt]
write_checkpoint [file join $reports synth.dcp]
opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_utilization -hierarchical -file [file join $reports utilization_hier.rpt]
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained -file [file join $reports timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $reports timing_setup.rpt]
report_timing -delay_type min -max_paths 10 -file [file join $reports timing_hold.rpt]
report_route_status -file [file join $reports route_status.rpt]
check_timing -verbose -file [file join $reports check_timing.rpt]
report_drc -file [file join $reports drc.rpt]
write_checkpoint [file join $reports routed.dcp]
set setup_paths [get_timing_paths -setup -max_paths 1]
set hold_paths [get_timing_paths -hold -max_paths 1]
set wns [expr {[llength $setup_paths] ? [get_property SLACK $setup_paths] : "NA"}]
set whs [expr {[llength $hold_paths] ? [get_property SLACK $hold_paths] : "NA"}]
set dsps [llength [get_cells -hierarchical -filter {REF_NAME =~ DSP48*}]]
set r36 [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}]]
set r18 [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB18*}]]
set fh [open [file join $reports summary.txt] w]
puts $fh "architecture=S2-N1-native-P4-striped-full-transport-formal\ntop=gemm_feature_transport_timing\ntransport_w=64\ntarget_mhz=$mhz\nwns_ns=$wns\nwhs_ns=$whs\ndsp=$dsps\nramb36=$r36\nramb18=$r18\ncomparison_scope=registered_OOC_fixture_not_board_signoff"
close $fh
puts "A04_PPA_DONE mhz=$mhz WNS=$wns WHS=$whs DSP=$dsps RAMB36=$r36 RAMB18=$r18 reports=$reports"
close_project
