# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set report_dir [file join $root_dir reports v13_systolic_tile_stream_300m]
file mkdir $report_dir

read_verilog [file join $root_dir rtl v13 compute npu_v13_dsp48e1_macc.v]
read_verilog [file join $root_dir rtl v13 compute npu_v13_systolic_pe_stream.v]
read_verilog [file join $root_dir rtl v13 compute npu_v13_systolic_result_delay.v]
read_verilog [file join $root_dir rtl v13 compute npu_v13_systolic_tile_4x4_stream.v]
read_xdc [file join $root_dir constraints npu_v13_300m.xdc]

synth_design -mode out_of_context -top npu_v13_systolic_tile_4x4_stream \
    -part xc7a200tfbg484-2 -flatten_hierarchy rebuilt

report_utilization -hierarchical -file [file join $report_dir utilization_hier.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $report_dir timing_summary.rpt]
write_checkpoint -force [file join $report_dir npu_v13_systolic_tile_4x4_stream_synth.dcp]

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
set setup_path [get_timing_paths -setup -max_paths 1 -nworst 1]
set hold_path [get_timing_paths -hold -max_paths 1 -nworst 1]
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]

set summary [open [file join $report_dir summary.txt] w]
puts $summary "top=npu_v13_systolic_tile_4x4_stream"
puts $summary "part=xc7a200tfbg484-2"
puts $summary "clock_period_ns=3.333"
puts $summary "target_mhz=300"
puts $summary "output_shape_sideband_bits=4"
puts $summary "inactive_result_elements=dont_care"
puts $summary "result_alignment=srl_with_auto_output_ff"
puts $summary "dsp48e1=$dsp_count"
puts $summary "opmodereg_1=$opmode_reg_count"
puts $summary "b_input_cascade=$b_cascade_count"
puts $summary "lut_total=[expr {$logic_lut_count + $srl_count}]"
puts $summary "lut_logic=$logic_lut_count"
puts $summary "srl16e=$srl_count"
puts $summary "ff=$ff_count"
puts $summary "synth_wns_ns=$wns"
puts $summary "synth_whs_ns=$whs"
close $summary

if {$dsp_count != 16} {error "Expected 16 DSP48E1 cells, got $dsp_count"}
if {$opmode_reg_count != 16} {error "Expected 16 registered DSP OPMODEs, got $opmode_reg_count"}
if {$b_cascade_count != 12} {error "Expected 12 DSP B cascade inputs, got $b_cascade_count"}
if {$wns < 0.0} {error "300 MHz stream tile setup timing failed: WNS=$wns ns"}
if {$whs < 0.0} {error "300 MHz stream tile hold timing failed: WHS=$whs ns"}
puts "NPU_MYDESIGN_V13_STREAM_TILE_300M_SYNTH_PASS dsp48e1=$dsp_count b_input_cascade=$b_cascade_count lut_total=[expr {$logic_lut_count + $srl_count}] ff=$ff_count wns_ns=$wns whs_ns=$whs"
