# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

# Current v13 formal source manifest: S2-N1 native P4-striped full transport.
# The historical a04 filename is retained so existing project/reproduction scripts keep working.
# Explicit lists only; do not replace with globbing.
set a04_project_root [file normalize [file join [file dirname [info script]] ..]]
set a04_design_sources [list \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_v13_dsp48e1_macc.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_v13_systolic_cluster_16x4x4_stream.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_v13_systolic_cluster_runtime_stream.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_v13_systolic_pe_stream.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_v13_systolic_result_delay.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_v13_systolic_tile_4x4_stream.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_g1_tile4x4_capture.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/base_compute/npu_s2_n1_unified_p4_core.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/base_control/npu_v13_cluster_mode_ctrl.v] \
    [file join $a04_project_root rtl/npu/v13/a04/base_control/npu_v13_job_executor.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/compat_control/npu_v13_command_fifo.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/compat_control/npu_v13_command_queue_dispatcher.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/compat_control/npu_v13_gemm_tile_scheduler.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/io/npu_v13_tile_collector_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/island/npu_v24_local_result_psum_island.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/local_row/npu_v23_native_collector.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/local_row/npu_v23_row_elastic.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/native_result/npu_v22_native_collector.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/native_result/npu_v22_result_island.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/native_result/npu_v22_runtime_panel_bridge.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/native_result/npu_v22_systolic_cluster_p4.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/native_result/npu_v22_systolic_runtime_p4.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/native_result/npu_v22_systolic_tile_p4.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/panel_reuse/merge4_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/panel_reuse/panel_compute_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/panel_reuse/panel_feeder_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/panel_reuse/panel_lease_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/panel_reuse/panel_ram_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/panel_reuse/panel_scheduler_exp.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_feature_store.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_feature_transport_pack.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_gemm_feature_backend.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_gemm_feature_transport.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_kchunk_ctrl.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_multik_backend.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_panel_load_narrow.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_panel_load_transport.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_postprocess_engine.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_psum_p4.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_psum_panel.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_quant_params.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_requant_p4.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/postprocess/npu_v13_stream_slice2.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_command_backend_joint.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_completion_event_slice.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_completion_tracker.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_exec_panel_adapter.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_managed_panel_store.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_packet_backend.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_packet_issue_ctrl.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_panel_ram_local.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_result_backend_joint.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_result_bram_fifo.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_result_island.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_retained_buffer_manager.sv] \
    [file join $a04_project_root rtl/npu/v13/a04/result_backend/npu_v13_runtime_panel_bridge.sv]
]
set a04_sim_sources [list \
    [file join $a04_project_root tb/unit/npu/v13/gemm_feature_timing.sv] \
    [file join $a04_project_root tb/unit/npu/v13/gemm_feature_transport_timing.sv] \
    [file join $a04_project_root tb/unit/npu/v13/multik_timing.sv] \
    [file join $a04_project_root tb/unit/npu/v13/npu_v13_psum_predecode_reference.sv] \
    [file join $a04_project_root tb/unit/npu/v13/psum_timing.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_feature_count_fence.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_feature_read_pipeline.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_feature_store_capacity.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_feature_store_validation.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_feature_store.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_feature_transport_pack.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_gemm_feature_backend.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_gemm_feature_capacity.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_gemm_feature_transport.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_kchunk_ctrl.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_load_validated_beat.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_multik_backend.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_npu_v13_psum_p4.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_panel_bank_local.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_panel_load_transport.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_post_config_fence.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_psum_panel.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_psum_predecode_equiv.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_psum_read_pipeline.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_quant_cfg_commit.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_quant_params_capacity.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_quant_params.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_requant_credit.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_requant_p4.sv] \
    [file join $a04_project_root tb/unit/npu/v13/tb_requant_product_exact.sv]
]
set a04_xdc_200 [file join $a04_project_root constraints/xilinx/npu_v13_a04_200m.xdc]
set a04_xdc_300 [file join $a04_project_root constraints/xilinx/npu_v13_a04_300m.xdc]
set a04_ppa_xdc_200 [file join $a04_project_root constraints/xilinx/npu_v13_a04_ppa_200m.xdc]
set a04_ppa_xdc_300 [file join $a04_project_root constraints/xilinx/npu_v13_a04_ppa_300m.xdc]

