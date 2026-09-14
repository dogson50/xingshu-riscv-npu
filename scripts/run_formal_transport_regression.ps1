# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 XingShu Project Contributors

param(
    [string]$VivadoPath = "vivado",
    [string]$Tag = (Get-Date -Format "yyyyMMdd_HHmmss")
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$cases = @(
    @{ Stall = 0; ResetAbort = 0; Cycles = 3417 },
    @{ Stall = 1; ResetAbort = 0; Cycles = 4280 },
    @{ Stall = 1; ResetAbort = 1; Cycles = 4540 }
)
foreach ($case in $cases) {
    $stall = $case.Stall
    $resetAbort = $case.ResetAbort
    & $VivadoPath -mode batch -source (Join-Path $PSScriptRoot "run_formal_transport_sim.tcl") `
        -tclargs $stall $resetAbort $Tag -notrace
    if ($LASTEXITCODE -ne 0) { throw "formal transport case $stall/$resetAbort failed" }
    $runName = "formal_transport_${stall}_${resetAbort}_${Tag}"
    $log = Join-Path $root "build\formal_transport\$runName\$runName.sim\sim_1\behav\xsim\simulate.log"
    if (!(Test-Path -LiteralPath $log)) { throw "simulation log missing: $log" }
    $text = Get-Content -LiteralPath $log -Raw
    $expected = "GEMM_TRANSPORT_PASS .*reset_abort=$resetAbort width=64 .*cycles=$($case.Cycles)"
    if (($text -notmatch $expected) -or ($text -match '(^|\s)(ERROR|FAIL)\b|_FAIL\b|TB_TIMEOUT\b|FATAL:')) {
        throw "formal transport PASS/cycle check failed for $stall/$resetAbort"
    }
    $pass = [regex]::Match($text, 'GEMM_TRANSPORT_PASS[^\r\n]+').Value
    Write-Output $pass
}
Write-Output "S2_N1_FORMAL_TRANSPORT_REGRESSION_PASS cases=3 width=64 tag=$Tag"
