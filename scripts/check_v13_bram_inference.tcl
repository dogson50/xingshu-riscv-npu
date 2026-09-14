# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set root [file dirname [file dirname [file normalize [info script]]]]
read_verilog -sv [file join $root rtl v13 memory npu_v13_bram_bank.sv]
synth_design -top npu_v13_bram_bank -part xc7a200tfbg484-2 -mode out_of_context -generic READ_LATENCY=2
report_utilization -file [file join $root reports v13_bram_inference.rpt]
foreach cell [get_cells -hierarchical -filter {REF_NAME =~ RAMB36*}] {puts "BRAM_INFERENCE $cell DOA_REG=[get_property DOA_REG $cell] DOB_REG=[get_property DOB_REG $cell]"}
puts "BRAM_FF [llength [get_cells -hierarchical -filter {REF_NAME =~ FD*}]]"

