param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$Output = 'Docs/performance/video30_stage1_summary.json'
)
$ErrorActionPreference = 'Stop'
$capture = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$windows = @($capture.samples | Where-Object {$_.text -match '^\[SUMMARY\]'} | ForEach-Object {
    $item = [ordered]@{}
    foreach ($match in [regex]::Matches($_.text, '(\w+)=([0-9a-fA-F]+)')) {
        $name = $match.Groups[1].Value
        $value = $match.Groups[2].Value
        $item[$name] = if ($name -in @('err','vdma_err')) { [Convert]::ToUInt32($value,16) } else { [long]$value }
    }
    [pscustomobject]$item
})
if (!$windows.Count) { throw 'No complete SUMMARY windows; do not interpret event logs as frame counts.' }
foreach ($row in $windows) {
    foreach ($required in @('window_us','qr','pass','preview','total_qr','total_pass','total_preview','copy_avg_us','qr_avg_us','qr_preview_avg_us','runtime_errors','camera_overflows','err','vdma_err')) {
        if ($null -eq $row.PSObject.Properties[$required]) { throw "Incomplete SUMMARY: $required" }
    }
    if ($row.window_us -lt 1000000 -or $row.qr -lt 1 -or $row.pass -gt $row.qr) { throw 'Invalid SUMMARY counts' }
}
$consistent = $true
for ($i = 1; $i -lt $windows.Count; $i++) {
    $a = $windows[$i-1]; $b = $windows[$i]
    if ($b.total_qr -ne $a.total_qr + $b.qr -or
        $b.total_pass -ne $a.total_pass + $b.pass -or
        $b.total_preview -ne $a.total_preview + $b.preview) { $consistent = $false }
}
$elapsed = ($windows | Measure-Object window_us -Sum).Sum / 1e6
$qr = ($windows | Measure-Object qr -Sum).Sum
$pass = ($windows | Measure-Object pass -Sum).Sum
$preview = ($windows | Measure-Object preview -Sum).Sum
$logDrops = @($capture.samples | Where-Object {$_.text -match '^\[DECODE\].*log_drops=(\d+)'} | ForEach-Object {
    [void]($_.text -match 'log_drops=(\d+)'); [long]$Matches[1]
})
$copySum = 0.0; $qrSum = 0.0; $callbackSum = 0.0
foreach ($w in $windows) {
    $copySum += $w.copy_avg_us * $w.preview
    $qrSum += $w.qr_avg_us * $w.qr
    $callbackSum += $w.qr_preview_avg_us * $w.qr
}
$result = [ordered]@{
    source=$Path; complete_windows=$windows.Count; device_window_seconds=$elapsed
    counters_contiguous=$consistent; analyzed_frames=$qr; qr_pass=$pass; qr_miss=($qr-$pass)
    qr_per_second=($qr/$elapsed); submitted_preview_per_second=($preview/$elapsed)
    preview_copy_average_us=$(if ($preview) {$copySum/$preview} else {$null})
    preview_copy_max_us=($windows | Measure-Object copy_max_us -Maximum).Maximum
    preview_gap_max_us=($windows | Measure-Object preview_gap_max_us -Maximum).Maximum
    qr_inclusive_average_us=($qrSum/$qr); qr_preview_average_us=($callbackSum/$qr)
    qr_nonpreview_wall_average_us=(($qrSum-$callbackSum)/$qr)
    preview_copy_drops=$windows[-1].drops; preview_errors=$windows[-1].display_errors
    runtime_error_samples=($windows | Measure-Object runtime_errors -Sum).Sum
    camera_overflow_samples=($windows | Measure-Object camera_overflows -Sum).Sum
    nonzero_error_windows=@($windows | Where-Object {$_.err -ne 0 -or $_.vdma_err -ne 0}).Count
    pl_candidate_frames=($windows | Measure-Object pl_frames -Sum).Sum
    pl_candidates=($windows | Measure-Object pl_candidates -Sum).Sum
    log_drops_max=$(if ($logDrops.Count) {($logDrops | Measure-Object -Maximum).Maximum} else {$null})
    failure_or_warning_lines=@($capture.samples | Where-Object {$_.text -match '\[(FAIL|WARN)\]'}).Count
    note='Preview submissions are not direct HDMI scanout/sensor measurements. Window averages have integer-us rounding; nonpreview wall time is not pure CPU time. Camera errors may be sticky samples.'
}
$parent = Split-Path -Parent $Output
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
if (!$consistent) { throw 'UART SUMMARY gap or restart detected' }
