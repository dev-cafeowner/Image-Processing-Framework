param([string]$Directory='Docs/performance/version_matrix_20260917_1333')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root $Directory
$comparison=Get-Content -LiteralPath (Join-Path $out 'comparison.json') -Raw | ConvertFrom-Json
if($comparison.completed -ne $comparison.planned){throw 'Comparison is incomplete'}
$hashCache=@{}
$runs=@(foreach($file in Get-ChildItem -LiteralPath $out -Filter '*_raw.json' -Recurse) {
    $raw=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $summaryPath=$file.FullName -replace '_raw\.json$','_summary.json'
    $summary=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    if($raw.profile.id -ne $summary.id -or $raw.outcome -ne $summary.outcome){throw "Summary identity mismatch: $file"}
    foreach($artifact in $raw.identities) {
        if(!$hashCache.ContainsKey($artifact.path)) {
            $hashCache[$artifact.path]=(Get-FileHash -LiteralPath (Join-Path $root $artifact.path)).Hash
        }
        if($hashCache[$artifact.path] -ne $artifact.sha256){throw "Artifact modified: $($artifact.path)"}
    }
    $last=-1
    foreach($sample in $raw.samples) {
        if($sample.ms -lt $last){throw "Non-monotonic host samples: $file"}
        $last=$sample.ms
    }
    if($raw.outcome -eq 'measured') {
        if($raw.requested_measurement_seconds -ne 120 -or $raw.settle_seconds -ne 15 -or
           [math]::Abs($raw.measurement_end_ms-$raw.measurement_start_ms-120000) -gt 0.01 -or
           $raw.duration_s*1000 -lt $raw.measurement_end_ms -or $summary.metric_seconds -gt 120.1) {
            throw "Measurement boundary mismatch: $file"
        }
    } elseif($null -ne $summary.qr_per_s -or $null -ne $summary.qr_pass_percent) {
        throw "Failed execution represented as measured performance: $file"
    }
    [ordered]@{
        id=$raw.profile.id;raw=$file.FullName;started=$raw.started
        finished=([DateTimeOffset]::Parse($raw.started).AddSeconds($raw.duration_s)).ToString('o')
        outcome=$raw.outcome;requested_observation_s=$raw.requested_measurement_seconds
        effective_metric_s=$summary.metric_seconds;last_progress_age_s=$summary.details.last_progress_age_s
        progress_warning=$summary.details.progress_warning;artifacts_unchanged=$true
    }
})
$result=[ordered]@{
    checked=(Get-Date).ToString('o');complete_comparison_rows=$comparison.completed
    raw_run_count=$runs.Count;unique_hashed_artifacts=$hashCache.Count;all_artifacts_unchanged=$true
    progress_warnings=@($runs | Where-Object progress_warning).Count
    excluded_initial_run='stage1_legacy_raw.json: user-confirmed board/camera movement'
    superseded_reference='stage4_raw.json: preserved supplementary run; final_retests/stage4 is the end reference'
    runs=$runs
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'audit.json') -Encoding UTF8
[pscustomobject]$result | Select-Object checked,complete_comparison_rows,raw_run_count,unique_hashed_artifacts,all_artifacts_unchanged,progress_warnings | Format-List
if($result.progress_warnings){throw 'Review observation-end progress warnings before reporting sustained throughput'}
