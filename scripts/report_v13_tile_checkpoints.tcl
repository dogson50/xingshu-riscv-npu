# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file dirname $script_dir]
set checkpoint [file join $root_dir reports v13_systolic_tile_stream_300m \
    npu_v13_systolic_tile_4x4_stream_synth.dcp]
if {![file exists $checkpoint]} { error "Checkpoint is missing: $checkpoint" }
open_checkpoint $checkpoint
report_utilization
report_timing_summary -delay_type min_max -max_paths 10
close_design
