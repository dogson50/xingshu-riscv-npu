# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set report_dir [file join $root_dir reports v13_gemm_tile_scheduler_300m]
file mkdir $report_dir

read_verilog -sv [file join $root_dir rtl v13 scheduler \
    npu_v13_gemm_tile_scheduler.sv]
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]

synth_design -mode out_of_context \
    -top npu_v13_gemm_tile_scheduler \
    -part xc7a200tfbg484-2 \
    -flatten_hierarchy rebuilt \
    -directive PerformanceOptimized

# The standalone scheduler has no physical producer or consumer placement.
# Exclude only OOC boundary paths; command/state to registered tile-batch generation
# remains covered by the internal register-to-register timing gate.
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [all_outputs]

set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]]
set bram_count [llength [get_cells -hierarchical -filter {REF_NAME =~ RAMB*}]]
set latch_count [llength [get_cells -hierarchical -filter {REF_NAME =~ LD*}]]
set logic_lut_count [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
set srl_count [llength [get_cells -hierarchical -filter {REF_NAME =~ SRL*}]]
set ff_count [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier_synth.rpt]
report_utilization -file [file join $report_dir utilization_synth.rpt]
write_checkpoint -force [file join $report_dir scheduler_synth.dcp]

if {$dsp_count != 0} { error "Scheduler must use 0 DSP48E1 cells, got $dsp_count" }
if {$bram_count != 0} { error "Scheduler must use 0 BRAM cells, got $bram_count" }
if {$latch_count != 0} { error "Scheduler inferred $latch_count latches" }

opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 50 \
    -file [file join $report_dir timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
write_checkpoint -force [file join $report_dir scheduler_routed.dcp]

set all_regs [all_registers]
set setup_path [get_timing_paths -setup -max_paths 1 -nworst 1 \
    -from $all_regs -to $all_regs]
set hold_path [get_timing_paths -hold -max_paths 1 -nworst 1 \
    -from $all_regs -to $all_regs]
set internal_wns [get_property SLACK $setup_path]
set internal_whs [get_property SLACK $hold_path]

report_timing -delay_type max -max_paths 50 -nworst 1 \
    -from $all_regs -to $all_regs \
    -file [file join $report_dir timing_internal_setup.rpt]
report_timing -delay_type min -max_paths 50 -nworst 1 \
    -from $all_regs -to $all_regs \
    -file [file join $report_dir timing_internal_hold.rpt]

set summary [open [file join $report_dir summary.txt] w]
puts $summary "top=npu_v13_gemm_tile_scheduler"
puts $summary "part=xc7a200tfbg484-2"
puts $summary "clock_period_ns=3.333"
puts $summary "target_mhz=300"
puts $summary "dimension_width=16"
puts $summary "tag_width=8"
puts $summary "runtime_modes=one_16x16,four_8x8,sixteen_4x4"
puts $summary "layout_count=9"
puts $summary "tile_batch_initiation_interval_cycles=1"
puts $summary "back_to_back_command_interval_cycles=1"
puts $summary "runtime_dividers=0"
puts $summary "runtime_multipliers=0"
puts $summary "dsp48e1=$dsp_count"
puts $summary "bram=$bram_count"
puts $summary "latches=$latch_count"
puts $summary "lut_total=[expr {$logic_lut_count + $srl_count}]"
puts $summary "lut_logic=$logic_lut_count"
puts $summary "srl=$srl_count"
puts $summary "ff=$ff_count"
puts $summary "ooc_boundary_timing=excluded_no_producer_consumer_placement"
puts $summary "internal_reg2reg_wns_ns=$internal_wns"
puts $summary "internal_reg2reg_whs_ns=$internal_whs"
close $summary

if {$internal_wns < 0.0} {
    error "300 MHz scheduler setup failed: WNS=$internal_wns ns"
}
if {$internal_whs < 0.0} {
    error "300 MHz scheduler hold failed: WHS=$internal_whs ns"
}

puts "NPU_MYDESIGN_V13_GEMM_TILE_SCHEDULER_300M_IMPL_PASS lut_total=[expr {$logic_lut_count + $srl_count}] ff=$ff_count internal_wns_ns=$internal_wns internal_whs_ns=$internal_whs"
