# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set report_dir [file join $root_dir reports \
    v13_systolic_cluster_16x4x4_stream_300m]
file mkdir $report_dir

read_verilog [file join $root_dir rtl v13 compute npu_v13_dsp48e1_macc.v]
read_verilog [file join $root_dir rtl v13 compute npu_v13_systolic_pe_stream.v]
read_verilog [file join $root_dir rtl v13 compute npu_v13_systolic_result_delay.v]
read_verilog [file join $root_dir rtl v13 compute npu_v13_systolic_tile_4x4_stream.v]
read_verilog [file join $root_dir rtl v13 compute \
    npu_v13_systolic_cluster_16x4x4_stream.v]
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]

# 固定 4×4 tile 网格、16 个独立 4×4 核，共 256 个 DSP48E1。
synth_design -mode out_of_context \
    -top npu_v13_systolic_cluster_16x4x4_stream \
    -part xc7a200tfbg484-2 -flatten_hierarchy rebuilt \
    -directive PerformanceOptimized

# OOC 顶层端口没有真实封装位置；只排除端口边界，保留每个局部输入
# 寄存器、tile 内部寄存器之间的真实 reg-to-reg 300 MHz 路径。
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [all_outputs]

set dsp_count [llength [get_cells -hierarchical -filter {REF_NAME == DSP48E1}]]
set opmode_reg_count 0
set b_cascade_count 0
foreach dsp [get_cells -hierarchical -filter {REF_NAME == DSP48E1}] {
    if {[get_property OPMODEREG $dsp] == 1} {incr opmode_reg_count}
    if {[get_property B_INPUT $dsp] eq "CASCADE"} {incr b_cascade_count}
}
set logic_lut_count [llength [get_cells -hierarchical -filter {REF_NAME =~ LUT*}]]
set srl_count [llength [get_cells -hierarchical -filter {REF_NAME == SRL16E}]]
set ff_count [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier_synth.rpt]
report_utilization -file [file join $report_dir utilization_synth.rpt]
write_checkpoint -force \
    [file join $report_dir npu_v13_systolic_cluster_16x4x4_stream_synth.dcp]

if {$dsp_count != 256} {
    error "Expected 256 DSP48E1 cells, got $dsp_count"
}
if {$opmode_reg_count != 256} {
    error "Expected 256 registered DSP OPMODEs, got $opmode_reg_count"
}
if {$b_cascade_count != 192} {
    error "Expected 192 DSP B cascade inputs, got $b_cascade_count"
}

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
write_checkpoint -force \
    [file join $report_dir npu_v13_systolic_cluster_16x4x4_stream_routed.dcp]

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
puts $summary "top=npu_v13_systolic_cluster_16x4x4_stream"
puts $summary "part=xc7a200tfbg484-2"
puts $summary "physical_tile_grid=4x4"
puts $summary "tile_count=16"
puts $summary "tile_shape=4x4"
puts $summary "macro_rows=16"
puts $summary "macro_cols=16"
puts $summary "shape_encoding=count_minus_one_2bit"
puts $summary "output_shape_sideband_bits=64"
puts $summary "inactive_result_elements=dont_care"
puts $summary "result_alignment=srl_with_auto_output_ff"
puts $summary "fixed_result_latency_cycles=10"
puts $summary "initiation_interval_cycles=1"
puts $summary "ready_port=absent"
puts $summary "clear_port=absent"
puts $summary "clock_period_ns=3.333"
puts $summary "target_mhz=300"
puts $summary "peak_macs_per_cycle=256"
puts $summary "peak_gmac_300m=76.80"
puts $summary "dsp48e1=$dsp_count"
puts $summary "opmodereg_1=$opmode_reg_count"
puts $summary "b_input_cascade=$b_cascade_count"
puts $summary "lut_total=[expr {$logic_lut_count + $srl_count}]"
puts $summary "lut_logic=$logic_lut_count"
puts $summary "srl16e=$srl_count"
puts $summary "ff=$ff_count"
puts $summary "ooc_boundary_timing=excluded_no_partpin_locs"
puts $summary "internal_reg2reg_wns_ns=$internal_wns"
puts $summary "internal_reg2reg_whs_ns=$internal_whs"
close $summary

if {$internal_wns < 0.0} {
    error "300 MHz fixed 16x4x4 cluster setup failed: WNS=$internal_wns ns"
}
if {$internal_whs < 0.0} {
    error "300 MHz fixed 16x4x4 cluster hold failed: WHS=$internal_whs ns"
}

puts "NPU_MYDESIGN_V13_FIXED_16X4X4_CLUSTER_300M_IMPL_PASS dsp48e1=$dsp_count b_input_cascade=$b_cascade_count lut_total=[expr {$logic_lut_count + $srl_count}] ff=$ff_count internal_wns_ns=$internal_wns internal_whs_ns=$internal_whs"
