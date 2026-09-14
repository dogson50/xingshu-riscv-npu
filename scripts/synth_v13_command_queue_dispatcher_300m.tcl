# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set report_dir [file join $root_dir reports v13_command_queue_dispatcher_300m]
file mkdir $report_dir

read_verilog -sv [file join $root_dir rtl v13 control \
    npu_v13_command_fifo.sv]
read_verilog [file join $root_dir rtl v13 control \
    npu_v13_cluster_mode_ctrl.v]
read_verilog -sv [file join $root_dir rtl v13 control \
    npu_v13_command_queue_dispatcher.sv]
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]

# 若推断模板退化、未把第二级读寄存器吸收到 RAMB36 输出级，立即失败。
# 仅依赖资源数量不足以发现这种时序退化。
set_msg_config -id {Synth 8-7052} -new_severity ERROR

synth_design -mode out_of_context \
    -top npu_v13_command_queue_dispatcher \
    -part xc7a200tfbg484-2 \
    -flatten_hierarchy rebuilt \
    -directive PerformanceOptimized

# 独立 OOC 没有真实的命令生产者、executor 和 runtime 物理位置，只排除
# 顶层端口路径。FIFO 预取、head 解码、FSM、response 等内部寄存器路径仍受
# 3.333 ns 时钟约束；真实模块连接关系另由 project XSim 联合测试覆盖。
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [all_outputs]

proc count_primitives {pattern} {
    return [llength [get_cells -quiet -hierarchical -filter \
        "REF_NAME =~ $pattern"]]
}

set dsp_count [count_primitives DSP48E1]
set bram36_count [count_primitives RAMB36*]
set bram18_count [count_primitives RAMB18*]
set latch_count [count_primitives LD*]
set synth_logic_lut_count [count_primitives LUT*]
set synth_srl_count [count_primitives SRL*]
set synth_ff_count [count_primitives FD*]

set bram36_doa_reg_count 0
foreach cell [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}] {
    if {[get_property DOA_REG $cell] == 1} {
        incr bram36_doa_reg_count
    }
}

# LUTRAM 的 primitive 名同样以 RAM 开头，但 block RAM 以 RAMB 开头。
set lutram_count 0
foreach cell [get_cells -quiet -hierarchical] {
    set ref_name [get_property REF_NAME $cell]
    if {[string match "RAM*" $ref_name] &&
        ![string match "RAMB*" $ref_name]} {
        incr lutram_count
    }
}

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier_synth.rpt]
report_utilization -file [file join $report_dir utilization_synth.rpt]
write_checkpoint -force [file join $report_dir command_dispatcher_synth.dcp]

# 默认完整命令为 194 bit，深度 512；最优映射占 6 个 RAMB18 等价单元，
# 即 3 个完整 BRAM tile。允许工具选择 3xRAMB36 或等价的 RAMB18 组合。
set bram18_equivalent [expr {2*$bram36_count + $bram18_count}]
if {$dsp_count != 0} {
    error "Command dispatcher must use 0 DSP48E1 cells, got $dsp_count"
}
if {$bram18_equivalent != 6} {
    error "194x512 command FIFO must use 6 RAMB18 equivalents, got $bram18_equivalent"
}
if {$bram36_count != 3 || $bram36_doa_reg_count != $bram36_count} {
    error "All three inferred RAMB36 cells must use DOA_REG=1; RAMB36=$bram36_count DOA_REG=$bram36_doa_reg_count"
}
if {$lutram_count != 0} {
    error "Command FIFO inferred $lutram_count LUTRAM primitives"
}
if {$latch_count != 0} {
    error "Command dispatcher inferred $latch_count latches"
}
if {$synth_srl_count != 0} {
    error "Command dispatcher unexpectedly inferred $synth_srl_count SRLs"
}

opt_design -directive ExploreWithRemap
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

set routed_logic_lut_count [count_primitives LUT*]
set routed_srl_count [count_primitives SRL*]
set routed_ff_count [count_primitives FD*]
set routed_bram36_count [count_primitives RAMB36*]
set routed_bram18_count [count_primitives RAMB18*]

set routed_utilization_text [report_utilization -return_string]
if {![regexp {\|[ \t]*Slice LUTs\*?[ \t]*\|[ \t]*([0-9]+)[ \t]*\|} \
      $routed_utilization_text _ routed_slice_lut_count]} {
    error "Unable to parse routed Slice LUT count from report_utilization"
}

set route_status_text [report_route_status -return_string]
if {![regexp {# of nets with routing errors\.*[ \t]*:[ \t]*([0-9]+)} \
      $route_status_text _ route_error_count]} {
    error "Unable to parse routing error count"
}
if {$route_error_count != 0} {
    error "Command dispatcher has $route_error_count nets with routing errors"
}

report_utilization -hierarchical \
    -file [file join $report_dir utilization_hier.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 50 \
    -file [file join $report_dir timing_summary.rpt]
report_route_status -file [file join $report_dir route_status.rpt]
write_checkpoint -force [file join $report_dir command_dispatcher_routed.dcp]

set setup_path [get_timing_paths -setup -max_paths 1 -nworst 1 \
    -sort_by slack]
set hold_path [get_timing_paths -hold -max_paths 1 -nworst 1 \
    -sort_by slack]
set internal_wns [get_property SLACK $setup_path]
set internal_whs [get_property SLACK $hold_path]

report_timing -delay_type max -max_paths 50 -nworst 1 \
    -sort_by slack \
    -file [file join $report_dir timing_internal_setup.rpt]
report_timing -delay_type min -max_paths 50 -nworst 1 \
    -sort_by slack \
    -file [file join $report_dir timing_internal_hold.rpt]

set summary [open [file join $report_dir summary.txt] w]
puts $summary "top=npu_v13_command_queue_dispatcher"
puts $summary "part=xc7a200tfbg484-2"
puts $summary "clock_period_ns=3.333"
puts $summary "target_mhz=300"
puts $summary "command_width=194"
puts $summary "fifo_depth=512"
puts $summary "fifo_storage_bits=99328"
puts $summary "fifo_output=registered_synchronous_prefetch"
puts $summary "steady_state_command_pop_ii_cycles=1"
puts $summary "outstanding_exec_commands=1"
puts $summary "dsp48e1=$dsp_count"
puts $summary "bram36_synth=$bram36_count"
puts $summary "bram36_doa_reg_synth=$bram36_doa_reg_count"
puts $summary "bram18_synth=$bram18_count"
puts $summary "bram18_equivalent_synth=$bram18_equivalent"
puts $summary "lutram_synth=$lutram_count"
puts $summary "latches_synth=$latch_count"
puts $summary "synth_lut_total=[expr {$synth_logic_lut_count + $synth_srl_count}]"
puts $summary "synth_lut_logic=$synth_logic_lut_count"
puts $summary "synth_srl=$synth_srl_count"
puts $summary "synth_ff=$synth_ff_count"
puts $summary "bram36_routed=$routed_bram36_count"
puts $summary "bram18_routed=$routed_bram18_count"
puts $summary "routed_slice_lut=$routed_slice_lut_count"
puts $summary "routed_lut_primitives=[expr {$routed_logic_lut_count + $routed_srl_count}]"
puts $summary "routed_srl=$routed_srl_count"
puts $summary "routed_ff=$routed_ff_count"
puts $summary "route_error_nets=$route_error_count"
puts $summary "ooc_boundary_timing=excluded_no_producer_consumer_placement"
puts $summary "internal_reg2reg_wns_ns=$internal_wns"
puts $summary "internal_reg2reg_whs_ns=$internal_whs"
close $summary

if {$internal_wns < 0.0} {
    error "300 MHz command dispatcher setup failed: WNS=$internal_wns ns"
}
if {$internal_whs < 0.0} {
    error "300 MHz command dispatcher hold failed: WHS=$internal_whs ns"
}

puts "NPU_MYDESIGN_V13_COMMAND_QUEUE_DISPATCHER_300M_IMPL_PASS bram18_equivalent=$bram18_equivalent routed_slice_lut=$routed_slice_lut_count routed_ff=$routed_ff_count internal_wns_ns=$internal_wns internal_whs_ns=$internal_whs"
