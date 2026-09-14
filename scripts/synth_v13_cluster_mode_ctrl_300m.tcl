# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set report_dir [file join $root_dir reports v13_cluster_mode_ctrl_300m]
file mkdir $report_dir

read_verilog [file join $root_dir rtl v13 control npu_v13_cluster_mode_ctrl.v]
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]

synth_design -mode out_of_context \
    -top npu_v13_cluster_mode_ctrl \
    -part xc7a200tfbg484-2 \
    -flatten_hierarchy rebuilt \
    -directive PerformanceOptimized

# 独立控制器没有真实的 dispatcher/cluster 物理位置，只把 OOC 端口路径排除；
# 请求保存、状态转换和 response 保持等内部寄存器路径仍受 300 MHz 约束。
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [all_outputs]

set dsp_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME == DSP48E1}]]
set bram_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB*}]]
set latch_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ LD*}]]
set synth_logic_lut_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ LUT*}]]
set synth_srl_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ SRL*}]]
set synth_ff_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ FD*}]]

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier_synth.rpt]
report_utilization -file [file join $report_dir utilization_synth.rpt]
write_checkpoint -force [file join $report_dir mode_ctrl_synth.dcp]

if {$dsp_count != 0} { error "Mode controller must use 0 DSP48E1 cells" }
if {$bram_count != 0} { error "Mode controller must use 0 BRAM cells" }
if {$latch_count != 0} { error "Mode controller inferred $latch_count latches" }

opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

# opt/place/phys_opt 可能合并 LUT。重新从 routed netlist 统计最终物理原语，
# 避免把综合后的 LUT 数误写成最终 Slice LUT 占用。
set routed_logic_lut_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ LUT*}]]
set routed_srl_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ SRL*}]]
set routed_ff_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ FD*}]]

# get_cells 统计网表 primitive；双输出 LUT 可以共享一个物理 LUT site，因而
# primitive 数可能高于 report_utilization 的 Slice LUT 数。后者才是最终资源占用。
set routed_utilization_text [report_utilization -return_string]
if {![regexp {\|[ \t]*Slice LUTs\*?[ \t]*\|[ \t]*([0-9]+)[ \t]*\|} \
      $routed_utilization_text _ routed_slice_lut_count]} {
    error "Unable to parse routed Slice LUT count from report_utilization"
}

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 50 \
    -file [file join $report_dir timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
write_checkpoint -force [file join $report_dir mode_ctrl_routed.dcp]

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
puts $summary "top=npu_v13_cluster_mode_ctrl"
puts $summary "part=xc7a200tfbg484-2"
puts $summary "clock_period_ns=3.333"
puts $summary "target_mhz=300"
puts $summary "outstanding_requests=1"
puts $summary "request_interface=ready_valid"
puts $summary "response_interface=ready_valid"
puts $summary "illegal_mode_filtered_locally=1"
puts $summary "dsp48e1=$dsp_count"
puts $summary "bram=$bram_count"
puts $summary "latches=$latch_count"
puts $summary "synth_lut_total=[expr {$synth_logic_lut_count + $synth_srl_count}]"
puts $summary "synth_lut_logic=$synth_logic_lut_count"
puts $summary "synth_srl=$synth_srl_count"
puts $summary "synth_ff=$synth_ff_count"
puts $summary "routed_slice_lut=$routed_slice_lut_count"
puts $summary "routed_lut_primitives=[expr {$routed_logic_lut_count + $routed_srl_count}]"
puts $summary "routed_lut_logic_primitives=$routed_logic_lut_count"
puts $summary "routed_srl=$routed_srl_count"
puts $summary "routed_ff=$routed_ff_count"
puts $summary "ooc_boundary_timing=excluded_no_producer_consumer_placement"
puts $summary "internal_reg2reg_wns_ns=$internal_wns"
puts $summary "internal_reg2reg_whs_ns=$internal_whs"
close $summary

if {$internal_wns < 0.0} {
    error "300 MHz mode controller setup failed: WNS=$internal_wns ns"
}
if {$internal_whs < 0.0} {
    error "300 MHz mode controller hold failed: WHS=$internal_whs ns"
}

puts "NPU_MYDESIGN_V13_CLUSTER_MODE_CTRL_300M_IMPL_PASS synth_lut_total=[expr {$synth_logic_lut_count + $synth_srl_count}] routed_slice_lut=$routed_slice_lut_count routed_lut_primitives=[expr {$routed_logic_lut_count + $routed_srl_count}] routed_ff=$routed_ff_count internal_wns_ns=$internal_wns internal_whs_ns=$internal_whs"
