param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
if (!(Test-Path -LiteralPath $Path) -or $Path -notmatch '\.json$') {throw 'Expected raw UART JSON'}
$stem=$Path -replace '\.json$',''
& "$PSScriptRoot/select_candidate_measurement_windows.ps1" -Path $Path | Out-Null
$selected="${stem}_selected.json"
$jobs=@(
 @('summarize_runtime_windows.ps1','summary'),
 @('summarize_geometry_routes.ps1','routes'),
 @('summarize_frame_pingpong.ps1','queue'),
 @('summarize_video_windows.ps1','video'),
 @('summarize_camera_stage3.ps1','camera'),
 @('summarize_rxclk_stage4.ps1','rxclk'),
 @('summarize_fallback_latency.ps1','latency')
)
$result=[ordered]@{source=$Path}
foreach($job in $jobs) {
 $output="${stem}_$($job[1]).json"
 & "$PSScriptRoot/$($job[0])" -Path $selected -Output $output | Out-Null
 $result[$job[1]]=Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
}
# Retain complete individual reports; keep console output small.
[pscustomobject]@{
 source=$Path;seconds=$result.summary.device_window_seconds
 frames=$result.summary.analyzed_frames;pass=$result.summary.qr_pass;miss=$result.summary.qr_miss
 qr_fps=$result.summary.qr_per_second
 fallback=$result.latency.fallback_attempts;fallback_pass=$result.latency.fallback_pass
 fallback_avg_us=$result.latency.fallback_average_us;fallback_max_us=$result.latency.fallback_max_us
 early=$result.latency.fallback_early_pass;refine=$result.latency.fallback_refine_attempts
 capture_skips=$result.queue.capture_skips_delta;ownership_errors=$result.queue.ownership_errors
 runtime_errors=$result.summary.runtime_error_samples;video_error_windows=$result.video.error_windows
} | ConvertTo-Json
