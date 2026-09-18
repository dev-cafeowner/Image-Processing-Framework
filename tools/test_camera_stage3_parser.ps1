$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/camera_stage3_parser'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$path=Join-Path $out 'fixture.json'
$summary=Join-Path $out 'summary.json'
$rows=@(1..3 | ForEach-Object {
    @{text="[CAM3] window_us=1000000 pclk_edges=24000000 sensor_frames=30 pixels=9216000 total_frames=$($_*30) lost_tokens=0 bad_lines=0 fifo_peak=16 status=021e0280 period_cycles=2082500 max_period_cycles=2082500 clock=1"}
})
@{samples=$rows} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
& "$PSScriptRoot/summarize_camera_stage3.ps1" -Path $path -Output $summary -SkipFirstWindow | Out-Null
$got=Get-Content -Raw -LiteralPath $summary | ConvertFrom-Json
if($got.windows -ne 2 -or $got.sensor_fps -ne 30 -or $got.pclk_hz -ne 24000000 -or $got.invalid_status_windows -ne 0 -or $got.last_frame_period_us -ne 33320) {throw 'Good camera fixture failed'}
@{samples=@($rows[0],$rows[2])} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
$rejected=$false
try {& "$PSScriptRoot/summarize_camera_stage3.ps1" -Path $path -Output $summary | Out-Null} catch {$rejected=$true}
if(!$rejected) {throw 'Dropped window was accepted'}
$rows[1].text=$rows[1].text.Replace(' pclk_edges=24000000','')
@{samples=$rows} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
$rejected=$false
try {& "$PSScriptRoot/summarize_camera_stage3.ps1" -Path $path -Output $summary | Out-Null} catch {$rejected=$true}
if(!$rejected) {throw 'Incomplete window was accepted'}
'PASS: CAM3 rates, period units, explicit startup exclusion, lost windows and missing fields'
