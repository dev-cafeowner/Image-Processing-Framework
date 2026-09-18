$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'Vitis_video30_stage1/parser_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$base = '[SUMMARY] window_us=1000000 qr=5 pass=4 preview=10 cycle_avg_us=200000 cycle_max_us=250000 qr_avg_us=60000 qr_preview_avg_us=5000 copy_avg_us=6000 copy_max_us=6500 preview_gap_max_us=101000 drops=0 display_errors=0 pl_frames=0 pl_candidates=0 runtime_errors=0 camera_overflows=0 err=00000000 vdma_err=00000000 '
$capture = [ordered]@{samples=@(
    @{ms=1000;text=($base+'total_qr=5 total_pass=4 total_preview=10')},
    @{ms=2000;text=($base+'total_qr=10 total_pass=8 total_preview=20')},
    @{ms=2010;text='[DECODE] qr=5 scans=5 log_drops=0'}
)}
$inputPath = Join-Path $out 'valid.json'
$resultPath = Join-Path $out 'summary.json'
$capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $inputPath -Encoding UTF8
& "$PSScriptRoot/summarize_runtime_windows.ps1" -Path $inputPath -Output $resultPath | Out-Null
$result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
if ($result.analyzed_frames -ne 10 -or $result.qr_pass -ne 8 -or
    $result.qr_per_second -ne 5 -or $result.submitted_preview_per_second -ne 10 -or
    $result.qr_nonpreview_wall_average_us -ne 55000 -or $result.log_drops_max -ne 0) {
    throw 'Valid window arithmetic failed'
}
$capture.samples[1].text = $capture.samples[1].text.Replace('total_qr=10','total_qr=15')
$capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $inputPath -Encoding UTF8
$rejected = $false
try { & "$PSScriptRoot/summarize_runtime_windows.ps1" -Path $inputPath -Output $resultPath | Out-Null }
catch { if ($_.Exception.Message -match 'gap or restart') {$rejected=$true} else {throw} }
if (!$rejected) {throw 'Missing UART windows were not detected'}
$capture.samples[1].text = '[SUMMARY] window_us=1000000 qr=5'
$capture | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $inputPath -Encoding UTF8
$rejected = $false
try { & "$PSScriptRoot/summarize_runtime_windows.ps1" -Path $inputPath -Output $resultPath | Out-Null }
catch { if ($_.Exception.Message -match 'Incomplete SUMMARY') {$rejected=$true} else {throw} }
if (!$rejected) {throw 'Partial record was not rejected'}
Write-Output 'PASS: runtime window arithmetic, UART gaps and incomplete records'
