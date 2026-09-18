$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'Vitis_video30_stage2/parser_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$a = '[VIDEO] window_us=1000000 camera_sof=10 scan_sof=60 total_camera=10 total_scan=60 camera_gap_max_us=100000 scan_gap_max_us=17000 geometry_errors=0 rejected=0 mm2s_err=00000000 hud=10 hud_avg_us=400 hud_max_us=500'
$b = '[VIDEO] window_us=2000000 camera_sof=20 scan_sof=120 total_camera=30 total_scan=180 camera_gap_max_us=100000 scan_gap_max_us=17000 geometry_errors=0 rejected=0 mm2s_err=00000000 hud=20 hud_avg_us=700 hud_max_us=800'
function Fixture($lines) {
    @{ samples=@($lines | ForEach-Object { @{text=$_} }) } | ConvertTo-Json -Depth 5 | Set-Content "$out/input.json"
}
Fixture @($a,$b)
& "$PSScriptRoot/summarize_video_windows.ps1" -Path "$out/input.json" -Output "$out/output.json" | Out-Null
$r = Get-Content "$out/output.json" -Raw | ConvertFrom-Json
if ($r.accepted_camera_sof_per_second -ne 10 -or $r.scan_sof_including_repeats_per_second -ne 60 -or $r.hud_pack_and_write_average_us -ne 600) {throw 'Weighted counter/time calculation failed'}
& "$PSScriptRoot/summarize_video_windows.ps1" -Path "$out/input.json" -Output "$out/steady.json" -SkipFirstWindow | Out-Null
$steady = Get-Content "$out/steady.json" -Raw | ConvertFrom-Json
if ($steady.windows -ne 1 -or $steady.excluded_initial_windows -ne 1 -or $steady.accepted_camera_sof -ne 20 -or $steady.device_window_seconds -ne 2) {throw 'Explicit startup-window exclusion failed'}
foreach ($bad in @($b.Replace('total_scan=180','total_scan=181'), $b.Replace(' mm2s_err=00000000',''))) {
    Fixture @($a,$bad)
    $rejected=$false
    try { & "$PSScriptRoot/summarize_video_windows.ps1" -Path "$out/input.json" -Output "$out/rejected.json" | Out-Null }
    catch { $rejected=$true }
    if (!$rejected) {throw 'Malformed/gapped capture accepted'}
}
Write-Output 'PASS: weighted camera/scan counters kept separate; missing fields and gaps rejected'
