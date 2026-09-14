# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set root_dir [file dirname [file dirname [file normalize [info script]]]]
set integrated [expr {[llength $argv] > 0 && [lindex $argv 0] eq "integrated"}]
set top_name npu_v13_job_executor
set report_name v13_job_executor_300m
if {$integrated} {
    set top_name npu_v13_command_executor_timing_top
    set report_name v13_command_executor_300m
}
if {[llength $argv] > 1} {
    set report_variant [lindex $argv 1]
    if {![regexp {^[a-z0-9_]+$} $report_variant]} {error "Invalid report variant"}
    append report_name _$report_variant
}
set report_dir [file join $root_dir reports $report_name]
file mkdir $report_dir
read_verilog -sv [file join $root_dir rtl v13 scheduler npu_v13_gemm_tile_scheduler.sv]
read_verilog -sv [file join $root_dir rtl v13 control npu_v13_job_executor.sv]
if {$integrated} {
    read_verilog -sv [file join $root_dir rtl v13 control npu_v13_command_fifo.sv]
    read_verilog [file join $root_dir rtl v13 control npu_v13_cluster_mode_ctrl.v]
    read_verilog -sv [file join $root_dir rtl v13 control npu_v13_command_queue_dispatcher.sv]
    read_verilog -sv [file join $root_dir tb v13 npu_v13_command_executor_timing_top.sv]
    set_msg_config -id {Synth 8-7052} -new_severity ERROR
}
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]
synth_design -mode out_of_context -top $top_name -part xc7a200tfbg484-2 \
    -flatten_hierarchy rebuilt -directive PerformanceOptimized
set_msg_config -id {Designutils 20-1307} -new_severity ERROR
if {$integrated} {
    read_xdc -ref npu_v13_job_executor [file join $root_dir constraints npu_v13_job_executor_context.xdc]
} else {
    read_xdc [file join $root_dir constraints npu_v13_job_executor_context.xdc]
}
set executor_context_regs [get_cells -quiet -hierarchical -filter {IS_SEQUENTIAL == 1 && NAME =~ *ctx_*_o_reg*}]
set executor_scheduler_regs [get_cells -quiet -hierarchical -filter {IS_SEQUENTIAL == 1 && NAME =~ *u_scheduler/*}]
if {[llength $executor_context_regs] == 0 || [llength $executor_scheduler_regs] == 0} {
    error "Context load constraint did not match actual registers"
}
# 不虚构外部 manager/feeder 的物理位置。ctx 寄存器到真实 scheduler 的路径在门禁内。
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [all_outputs]
proc count_cells {pattern} {
    return [llength [get_cells -quiet -hierarchical -filter "REF_NAME =~ $pattern"]]
}
if {[count_cells DSP*] != 0 || [count_cells LD*] != 0} {
    error "Executor must use zero DSP and latch primitives"
}
if {!$integrated && [count_cells RAM*] != 0} {error "Standalone executor must not use RAM"}
if {$integrated} {
    if {[count_cells RAMB36*] != 3 || [count_cells RAM*] != 3} {error "Integrated FIFO must use three RAMB36"}
    foreach cell [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}] {
        if {[get_property DOA_REG $cell] != 1} {error "FIFO output register not absorbed into BRAM"}
    }
}
report_utilization -hierarchical -file [file join $report_dir utilization_synth.rpt]
write_checkpoint -force [file join $report_dir executor_synth.dcp]
opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
# 完整连接后仍检查真实控制路径；布线后优化可修正放置/时钟偏斜产生的小裕量。
# 不放宽周期、不增加例外；下面照常硬性检查 setup、hold 和 route status。
phys_opt_design -directive AggressiveExplore
report_utilization -hierarchical -file [file join $report_dir utilization_hier.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $report_dir timing_setup.rpt]
report_timing -delay_type min -max_paths 20 -file [file join $report_dir timing_hold.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
report_exceptions -file [file join $report_dir exceptions.rpt]
set exception_text [report_exceptions -return_string]
if {![regexp {cycles=2} $exception_text] || ![regexp {cycles=1} $exception_text]} {
    error "Context multicycle constraints are absent from the actual exceptions report"
}
write_checkpoint -force [file join $report_dir executor_routed.dcp]
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -sort_by slack]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1 -sort_by slack]]
set util [report_utilization -return_string]
if {![regexp {\|[ \t]*Slice LUTs\*?[ \t]*\|[ \t]*([0-9]+)[ \t]*\|} $util _ lut]} {
    error "Cannot parse physical Slice LUTs"
}
set route_status [report_route_status -return_string]
if {![regexp {# of nets with routing errors\.*[ \t]*:[ \t]*([0-9]+)} $route_status _ route_errors]} {
    error "Cannot parse routing status"
}
set f [open [file join $report_dir summary.txt] w]
puts $f "top=$top_name"
puts $f "includes_dispatcher=$integrated"
puts $f "includes_real_gemm_tile_scheduler=1"
puts $f "part=xc7a200tfbg484-2"
puts $f "clock_period_ns=3.333"
puts $f "target_mhz=300"
puts $f "routed_slice_lut=$lut"
puts $f "routed_ff=[count_cells FD*]"
puts $f "dsp=[count_cells DSP*]"
puts $f "ram=[count_cells RAM*]"
puts $f "latch=[count_cells LD*]"
puts $f "internal_reg2reg_wns_ns=$wns"
puts $f "internal_reg2reg_whs_ns=$whs"
puts $f "route_error_nets=$route_errors"
puts $f "ooc_boundary_timing=excluded_no_external_manager_or_feeder_placement"
puts $f "context_to_scheduler_load=setup_2_cycles_hold_1_cycle"
puts $f "context_stable_before_scheduler_load_min_cycles=4"
puts $f "tile_batch_steady_state_ii_cycles=1"
puts $f "outstanding_commands=1"
close $f
if {$wns < 0 || $whs < 0 || $route_errors != 0} {error "Executor timing/route failed: $wns/$whs errors=$route_errors"}
puts "NPU_V13_JOB_EXECUTOR_300M_PASS lut=$lut ff=[count_cells FD*] wns=$wns whs=$whs"
