# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "build\rtl_tests"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$iverilog = if ($env:IVERILOG_BIN) { $env:IVERILOG_BIN } else { (Get-Command iverilog -ErrorAction Stop).Source }
$vvp = if ($env:VVP_BIN) { $env:VVP_BIN } else { (Get-Command vvp -ErrorAction Stop).Source }

function Invoke-RtlCheck {
    param(
        [string]$Name,
        [string]$Top,
        [string[]]$Sources
    )

    $image = Join-Path $out ($Name + ".vvp")
    $resolved = $Sources | ForEach-Object { Join-Path $root $_ }
    & $iverilog -g2012 -s $Top -o $image $resolved
    if ($LASTEXITCODE -ne 0) { throw "$Name compile failed" }

    $simOutput = @(& $vvp $image 2>&1)
    $simExitCode = $LASTEXITCODE
    $simOutput | ForEach-Object { Write-Output $_ }
    $reportedFailure = $simOutput | Select-String -Quiet `
        -Pattern '(^|\s)ERROR\b|(^|\s)FAIL\b|_FAIL\b|TB_TIMEOUT\b|FATAL:'
    if (($simExitCode -ne 0) -or $reportedFailure) {
        throw "$Name simulation failed"
    }
    Write-Output "PASS $Name"
}

$tileCore = @(
    "rtl\npu\v13\compute\npu_v13_dsp48e1_macc.v",
    "rtl\npu\v13\compute\npu_v13_systolic_pe_stream.v",
    "rtl\npu\v13\compute\npu_v13_systolic_result_delay.v",
    "rtl\npu\v13\compute\npu_v13_systolic_tile_4x4_stream.v"
)

Invoke-RtlCheck -Name "v13_tile_stream" `
    -Top "tb_npu_v13_systolic_tile_4x4_stream" -Sources (
        $tileCore + "tb\unit\npu\v13\tb_npu_v13_systolic_tile_4x4_stream.sv")

$fixedClusterCore = $tileCore +
    "rtl\npu\v13\compute\npu_v13_systolic_cluster_16x4x4_stream.v"
Invoke-RtlCheck -Name "v13_cluster_16x4x4_stream" `
    -Top "tb_npu_v13_systolic_cluster_16x4x4_stream" -Sources (
        $fixedClusterCore + "tb\unit\npu\v13\tb_npu_v13_systolic_cluster_16x4x4_stream.sv")

$runtimeCore = $fixedClusterCore +
    "rtl\npu\v13\compute\npu_v13_systolic_cluster_runtime_stream.v"
Invoke-RtlCheck -Name "v13_cluster_runtime_stream" `
    -Top "tb_npu_v13_systolic_cluster_runtime_stream" -Sources (
        $runtimeCore + "tb\unit\npu\v13\tb_npu_v13_systolic_cluster_runtime_stream.sv")

Invoke-RtlCheck -Name "v13_cluster_mode_ctrl" `
    -Top "tb_npu_v13_cluster_mode_ctrl" -Sources @(
        "rtl\npu\v13\control\npu_v13_cluster_mode_ctrl.v",
        "tb\unit\npu\v13\tb_npu_v13_cluster_mode_ctrl.sv")

Invoke-RtlCheck -Name "v13_cluster_mode_ctrl_runtime_joint" `
    -Top "tb_npu_v13_cluster_mode_ctrl_runtime_joint" -Sources (
        $runtimeCore +
        "rtl\npu\v13\control\npu_v13_cluster_mode_ctrl.v" +
        "tb\unit\npu\v13\tb_npu_v13_cluster_mode_ctrl_runtime_joint.sv")

Invoke-RtlCheck -Name "v13_gemm_tile_scheduler" `
    -Top "tb_npu_v13_gemm_tile_scheduler" -Sources @(
        "rtl\npu\v13\scheduler\npu_v13_gemm_tile_scheduler.sv",
        "tb\unit\npu\v13\tb_npu_v13_gemm_tile_scheduler.sv")

Invoke-RtlCheck -Name "v13_command_fifo" `
    -Top "tb_npu_v13_command_fifo" -Sources @(
        "rtl\npu\v13\control\npu_v13_command_fifo.sv",
        "tb\unit\npu\v13\tb_npu_v13_command_fifo.sv")

$commandDispatcherCore = @(
    "rtl\npu\v13\control\npu_v13_command_fifo.sv",
    "rtl\npu\v13\control\npu_v13_cluster_mode_ctrl.v",
    "rtl\npu\v13\control\npu_v13_command_queue_dispatcher.sv"
)
Invoke-RtlCheck -Name "v13_command_queue_dispatcher" `
    -Top "tb_npu_v13_command_queue_dispatcher" -Sources (
        $commandDispatcherCore +
        "tb\unit\npu\v13\tb_npu_v13_command_queue_dispatcher.sv")

Invoke-RtlCheck -Name "v13_command_dispatcher_runtime_joint" `
    -Top "tb_npu_v13_command_dispatcher_runtime_joint" -Sources (
        $runtimeCore + $commandDispatcherCore +
        "tb\unit\npu\v13\tb_npu_v13_command_dispatcher_runtime_joint.sv")

$executorCore = @(
    "rtl\npu\v13\control\npu_v13_job_executor.sv",
    "rtl\npu\v13\scheduler\npu_v13_gemm_tile_scheduler.sv"
)
Invoke-RtlCheck -Name "v13_job_executor" `
    -Top "tb_npu_v13_job_executor" -Sources (
        $executorCore + "tb\unit\npu\v13\tb_npu_v13_job_executor.sv")

Invoke-RtlCheck -Name "v13_job_executor_runtime_joint" `
    -Top "tb_npu_v13_job_executor_runtime_joint" -Sources (
        $runtimeCore + $commandDispatcherCore + $executorCore +
        "tb\unit\npu\v13\npu_v13_command_executor_timing_top.sv" +
        "tb\unit\npu\v13\tb_npu_v13_job_executor_runtime_joint.sv")

$memoryCore = @(
    "rtl\npu\v13\memory\npu_v13_buffer_manager.sv",
    "rtl\npu\v13\memory\npu_v13_bram_bank.sv"
)
Invoke-RtlCheck -Name "v13_bram_bank" -Top "tb_npu_v13_bram_bank" -Sources (
    $memoryCore + "tb\unit\npu\v13\tb_npu_v13_bram_bank.sv")
Invoke-RtlCheck -Name "v13_buffer_manager" -Top "tb_npu_v13_buffer_manager" -Sources (
    $memoryCore + "tb\unit\npu\v13\tb_npu_v13_buffer_manager.sv")
Invoke-RtlCheck -Name "v13_buffer_bram_runtime_joint" -Top "tb_npu_v13_buffer_bram_runtime_joint" -Sources (
    $runtimeCore + $commandDispatcherCore + $executorCore + $memoryCore +
    "tb\unit\npu\v13\npu_v13_command_executor_timing_top.sv" + "tb\unit\npu\v13\tb_npu_v13_buffer_bram_runtime_joint.sv")
Write-Output "NPU_MYDESIGN_RUNTIME_RTL_TESTS_PASS checks=14"
