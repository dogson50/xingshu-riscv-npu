# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

# 先期裸端口 OOC 实验保留作诊断，不是最终签核入口。
# 没有外部寄存器/HD.PARTPIN_LOCS 时端口布线计时不完整。
# 最终请运行 synth_v13_buffer_bram_300m.ps1（注册边界夹具）。
set root_dir [file dirname [file dirname [file normalize [info script]]]]
set which [lindex $argv 0]
if {$which ni {manager bram_l1 bram_l2}} {error "Use manager/bram_l1/bram_l2"}
set report_dir [file join $root_dir reports v13_${which}_300m]
file mkdir $report_dir
set top npu_v13_buffer_manager
set generics [list]
if {$which ne "manager"} {
    set top npu_v13_bram_bank
    set latency [expr {$which eq "bram_l1" ? 1 : 2}]
    set generics [list READ_LATENCY=$latency]
}
read_verilog -sv [file join $root_dir rtl v13 memory ${top}.sv]
# 保留全部非 reset 输入/输出时序预算，不以 false path 掩盖 BRAM 端口路径。
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]
synth_design -mode out_of_context -top $top -part xc7a200tfbg484-2 -generic $generics -flatten_hierarchy rebuilt -directive PerformanceOptimized
proc count_cells {pattern} {return [llength [get_cells -quiet -hierarchical -filter "REF_NAME =~ $pattern"]]}
if {[count_cells DSP*] || [count_cells LD*]} {error "Unexpected DSP or latch"}
if {$which eq "manager" && [count_cells RAM*]} {error "Manager must not infer RAM"}
if {$which ne "manager" && ([count_cells RAMB36*]!=1 || [count_cells RAM*]!=1)} {error "Expected exactly one RAMB36 for 32x1024"}
report_utilization -hierarchical -file [file join $report_dir utilization_synth.rpt]
write_checkpoint -force [file join $report_dir memory_synth.dcp]
opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
report_utilization -hierarchical -file [file join $report_dir utilization_hier.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $report_dir timing_setup.rpt]
report_timing -delay_type min -max_paths 20 -file [file join $report_dir timing_hold.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_exceptions -file [file join $report_dir exceptions.rpt]
write_checkpoint -force [file join $report_dir memory_routed.dcp]
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -sort_by slack]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1 -sort_by slack]]
set util [report_utilization -return_string]
if {![regexp {\|[ \t]*Slice LUTs\*?[ \t]*\|[ \t]*([0-9]+)[ \t]*\|} $util _ lut]} {error "Cannot parse LUT"}
set routes [report_route_status -return_string]
if {![regexp {# of nets with routing errors\.*[ \t]*:[ \t]*([0-9]+)} $routes _ route_errors]} {error "Cannot parse routing"}
set f [open [file join $report_dir summary.txt] w]
puts $f "top=$top"
puts $f "configuration=$which"
puts $f "part=xc7a200tfbg484-2"
puts $f "clock_period_ns=3.333"
puts $f "routed_slice_lut=$lut"
puts $f "routed_ff=[count_cells FD*]"
puts $f "dsp=[count_cells DSP*]"
puts $f "ramb36=[count_cells RAMB36*]"
puts $f "latch=[count_cells LD*]"
puts $f "wns_ns=$wns"
puts $f "whs_ns=$whs"
puts $f "route_error_nets=$route_errors"
puts $f "scope=standalone_OOC_including_nonreset_IO_paths"
puts $f "io_budget_max_ns=0.667"
puts $f "false_paths=reset_only"
if {$which ne "manager"} {
    puts $f "bram_data_width=32"
    puts $f "bram_depth=1024"
    puts $f "read_latency=$latency"
    foreach cell [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}] {
        puts $f "bram_cell=$cell DOA_REG=[get_property DOA_REG $cell] DOB_REG=[get_property DOB_REG $cell]"
    }
}
close $f
if {$wns<0 || $whs<0 || $route_errors!=0} {error "Memory timing failed: WNS=$wns WHS=$whs routes=$route_errors"}
puts "NPU_V13_BUFFER_BRAM_300M_PASS configuration=$which lut=$lut ff=[count_cells FD*] wns=$wns whs=$whs"
