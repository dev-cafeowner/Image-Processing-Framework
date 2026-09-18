$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/version_benchmark_parser'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$path=Join-Path $out 'fixture_raw.json'
function Write-Fixture($samples,$outcome='measured') {
    [ordered]@{profile=@{id='baseline_o0';label='synthetic fixture';group='test'};outcome=$outcome;failure='synthetic failure'
        requested_measurement_seconds=5;measurement_start_ms=1000;measurement_end_ms=6000;started='2026-09-17T00:00:00+09:00';duration_s=6;samples=$samples
    } | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $path -Encoding UTF8
}
$rows=@(0..6 | ForEach-Object {
    @{ms=$_*1000;text="[PERF] n=$_ ok=1 cycle_us=1000000 qr_us=100000 display_us=1000 status=00001240 err=00000000 cam=021E0280 vdma=00011000"}
})
Write-Fixture $rows
& "$PSScriptRoot/summarize_version_profile.ps1" -Path $path | Out-Null
$got=Get-Content (Join-Path $out 'fixture_summary.json') -Raw | ConvertFrom-Json
if($got.qr_count -ne 4 -or $got.qr_per_s -ne 1 -or $got.qr_pass_percent -ne 100 -or $got.frame_stuck_samples -ne 4 -or $got.error_samples -ne 0) {throw 'PERF fixed-boundary fixture failed'}
$earlyStage1=@($rows)+@(@{ms=2500;text='[SUMMARY] window_us=1000000 qr=1 pass=1 preview=2'},@{ms=2510;text='[DECODE] qr=1 scans=1'})
Write-Fixture $earlyStage1
& "$PSScriptRoot/summarize_version_profile.ps1" -Path $path | Out-Null
$got=Get-Content (Join-Path $out 'fixture_summary.json') -Raw | ConvertFrom-Json
if($got.qr_count -ne 4 -or $got.qr_per_s -ne 1){throw 'Early Stage1 without RENDER did not use complete PERF intervals'}
$bad=@($rows | Where-Object {$_.ms -ne 3000})
Write-Fixture $bad
$rejected=$false
try {& "$PSScriptRoot/summarize_version_profile.ps1" -Path $path | Out-Null} catch {$rejected=$true}
if(!$rejected){throw 'Dropped PERF frame accepted'}
Write-Fixture @() 'firmware_failed'
& "$PSScriptRoot/summarize_version_profile.ps1" -Path $path | Out-Null
$got=Get-Content (Join-Path $out 'fixture_summary.json') -Raw | ConvertFrom-Json
if($got.outcome -ne 'firmware_failed' -or $null -ne $got.qr_per_s -or $null -ne $got.qr_pass_percent){throw 'Failure represented as measured zero'}
$events=@(@{ms=500;text='[QR PASS] outside'},@{ms=1500;text='[QR PASS] inside'},@{ms=2500;text='[QR MISS] NO REGION'},@{ms=6500;text='[QR PASS] outside'})
Write-Fixture $events
& "$PSScriptRoot/summarize_version_profile.ps1" -Path $path | Out-Null
$got=Get-Content (Join-Path $out 'fixture_summary.json') -Raw | ConvertFrom-Json
if($got.qr_count -ne 2 -or $got.qr_pass_percent -ne 50 -or $got.qr_per_s -ne 0.4 -or $null -ne $got.error_samples){throw 'Uninstrumented boundary/unknown-counter fixture failed'}
'PASS: fixed observation boundary, device rates, FRAME_STUCK separation, sequence gaps, failed runs and unknown legacy counters'
