$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/video30_stage2_20260917'
if(Test-Path -LiteralPath $out) {throw 'Checkpoint exists; do not overwrite it'}
$inputs=@(
    'hardware/rtl/video/video_preview_overlay.v',
    'hardware/tb/video_preview_overlay_tb.sv',
    'hardware/vivado/baselines/qr_perf_stage1.bd',
    'software/vitis/Qr_barcode_working_ver0_app/src',
    'tools',
    'Vivado/qr_video30_stage2/qr_video30_stage2.bit',
    'Vivado/qr_video30_stage2/qr_video30_stage2.xsa',
    'Vivado/qr_video30_stage2/timing_summary.rpt',
    'Vivado/qr_video30_stage2/utilization.rpt',
    'Vivado/qr_video30_stage2/cdc.rpt',
    'Vivado/qr_video30_stage2/io.rpt',
    'Vitis_video30_stage2/build/Qr_barcode_working_ver0_app.elf',
    'Docs/VIDEO_30FPS_STAGE2_20260917.md',
    'Docs/performance/video30_stage2_final_uart_raw.json',
    'Docs/performance/video30_stage2_final_uart.json',
    'Docs/performance/video30_stage2_final_qr_summary.json',
    'Docs/performance/video30_stage2_final_video_summary.json',
    'Docs/performance/video30_stage2_final_steady_video_summary.json',
    'Docs/performance/video30_stage2_control_stage1_raw.json',
    'Docs/performance/video30_stage2_control_stage1_summary.json',
    'Docs/performance/video30_stage2_autonomy_verified.log',
    'Docs/performance/video30_stage2_blank_uart.json',
    'Docs/performance/video30_stage2_return_uart_raw.json',
    'Docs/performance/video30_stage2_return_program.log'
)
foreach($relative in $inputs) {
    $source=Join-Path $root $relative
    if(!(Test-Path -LiteralPath $source)) {throw "Missing checkpoint input $relative"}
}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($relative in $inputs) {
    $source=Join-Path $root $relative
    $destination=Join-Path $out $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse
}
$manifest=@(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
[ordered]@{
    version='video30_stage2_20260917'; created=(Get-Date).ToString('o')
    baseline_dependency='qr_perf_stable_20260917.zip'
    baseline_sha256='B1CBF10272A277E1FAF67890EC8E4ACB62EE2BC859DE31861BB86BA46E265A8E'
    note='Delta checkpoint over full stable archive. Source/tools/artifacts and principal UART evidence included. Requires local Xilinx/Digilent/BSP dependencies. Restore files to workspace layout before running tools; do not run copied tools directly from checkpoint.'
    files=$manifest
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $out -DestinationPath "$out.zip"
Get-FileHash -LiteralPath "$out.zip"
