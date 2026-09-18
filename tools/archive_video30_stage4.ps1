$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/video30_stage4_20260917'
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath "$out.zip")) {throw 'Checkpoint exists; do not overwrite'}
$qr=Get-Content (Join-Path $root 'Docs/performance/video30_stage4_final_qr.json') -Raw | ConvertFrom-Json
$video=Get-Content (Join-Path $root 'Docs/performance/video30_stage4_final_video_steady.json') -Raw | ConvertFrom-Json
$cam=Get-Content (Join-Path $root 'Docs/performance/video30_stage4_final_camera_steady.json') -Raw | ConvertFrom-Json
$rx=Get-Content (Join-Path $root 'Docs/performance/video30_stage4_final_rxclk.json') -Raw | ConvertFrom-Json
if($qr.device_window_seconds -lt 300 -or !$qr.counters_contiguous -or $qr.qr_pass -lt 1 -or
   $qr.runtime_error_samples -ne 0 -or $qr.camera_overflow_samples -ne 0 -or
   $qr.nonzero_error_windows -ne 0 -or $qr.failure_or_warning_lines -ne 0 -or $qr.log_drops_max -ne 0 -or
   $video.device_window_seconds -lt 300 -or !$video.counters_contiguous -or
   $video.accepted_camera_sof_per_second -lt 29.5 -or $video.accepted_camera_sof_per_second -gt 30.5 -or
   $video.error_windows -ne 0 -or $cam.lost_tokens_max -ne 0 -or $cam.bad_lines_max -ne 0 -or
   $cam.invalid_status_windows -ne 0 -or $rx.invalid_clock_windows -ne 0 -or $rx.lock_losses_max -ne 0) {
    throw 'Fixed-scene VGA30 benchmark did not pass'
}
$inputs=@(
    'hardware/rtl/camera', 'hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v',
    'hardware/rtl/video/video_preview_overlay.v',
    'hardware/tb/ov7670_clean_pclk_rx_tb.sv', 'hardware/tb/ov7670_clean_sync_axis_tb.sv',
    'hardware/constraints/zybo_z7_20_ov7670_stage4.xdc',
    'hardware/vivado/baselines/qr_video30_stage2.bd',
    'software/vitis/Qr_barcode_working_ver0_app/src', 'software/tests', 'tools',
    'Vivado/qr_video30_stage4/qr_video30_stage4.bit',
    'Vivado/qr_video30_stage4/qr_video30_stage4.xsa',
    'Vivado/qr_video30_stage4/qr_video30_stage4_xclk_slow4.bit',
    'Vivado/qr_video30_stage4/design.tcl', 'Vivado/qr_video30_stage4/timing_summary.rpt',
    'Vivado/qr_video30_stage4/utilization.rpt', 'Vivado/qr_video30_stage4/cdc.rpt',
    'Vivado/qr_video30_stage4/bus_skew_verified.rpt', 'Vivado/qr_video30_stage4/io.rpt',
    'Vivado/qr_video30_stage4/clocks.rpt', 'Vivado/qr_video30_stage4/camera_input_timing.rpt',
    'Vivado/video30_stage4_build_retry1.log', 'Vivado/video30_stage4_physical_verify.log',
    'Vivado/video30_stage4_slowclk_build.log',
    'Vivado/camera_stage4_sim/camera_small.log', 'Vivado/camera_stage4_sim/camera_vga.log',
    'Vivado/camera_stage4_sim/camera_control.log',
    'Vitis_video30_stage4/drive1x/Qr_barcode_working_ver0_app.elf',
    'Vitis_video30_stage4/drive1x/CMakeCache.txt', 'Vitis_video30_stage4/drive1x/compile_commands.json',
    'Vitis_video30_stage4/build/Qr_barcode_working_ver0_app.elf',
    'Vitis_video30_stage4/colorbars/Qr_barcode_working_ver0_app.elf',
    'Docs/VIDEO_30FPS_STAGE4_20260917.md'
)
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Docs/performance') -File -Filter 'video30_stage4_*' | ForEach-Object {$_.FullName.Substring($root.Length+1)})
foreach($relative in $inputs) {
    if(!(Test-Path -LiteralPath (Join-Path $root $relative))) {throw "Missing checkpoint input: $relative"}
}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($relative in $inputs) {
    $destination=Join-Path $out $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination -Recurse
}
$manifest=@(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
[ordered]@{
    version='video30_stage4_20260917';created=(Get-Date).ToString('o')
    baseline_dependency='video30_stage3_20260917.zip'
    baseline_sha256='A74467FD39DC0D4F637984AD36F95085C466DFE02DA16111D42E0505B511469E'
    selected_bit='Vivado/qr_video30_stage4/qr_video30_stage4.bit'
    selected_elf='Vitis_video30_stage4/drive1x/Qr_barcode_working_ver0_app.elf'
    note='Delta over stage3 and its baseline dependencies. Fixed-scene VGA30 functional benchmark only; edge halos and general image quality remain unqualified. Slow4 bit and build/ ELF are rejected diagnostics, not the selected profile. Restore workspace paths before running tools. Requires local Xilinx/Digilent/BSP dependencies.'
    files=$manifest
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$out/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $out -DestinationPath "$out.zip"
$zip=[IO.Compression.ZipFile]::OpenRead("$out.zip")
try {
    $prefix=(Split-Path -Leaf $out)+'/'
    foreach($file in $manifest) {
        $entry=$zip.GetEntry($prefix+$file.path)
        if($null -eq $entry -or $entry.Length -ne $file.bytes) {throw "ZIP length/missing mismatch: $($file.path)"}
        $stream=$entry.Open()
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
        finally {$stream.Dispose();$sha.Dispose()}
        if($hash -ne $file.sha256) {throw "ZIP SHA256 mismatch: $($file.path)"}
    }
} finally {$zip.Dispose()}
Write-Output "Verified $($manifest.Count) checkpoint payloads against manifest."
Get-FileHash -LiteralPath "$out.zip"
