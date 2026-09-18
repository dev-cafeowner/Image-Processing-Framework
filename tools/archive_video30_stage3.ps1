$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/video30_stage3_20260917'
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath "$out.zip")) {throw 'Checkpoint exists; do not overwrite it'}
$inputs=@(
    'hardware/rtl/camera/ov7670_camera_clock.v',
    'hardware/rtl/camera/ov7670_pclk_rx.v',
    'hardware/rtl/camera/ov7670_source_sync_axis.v',
    'hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v',
    'hardware/rtl/video/video_preview_overlay.v',
    'hardware/tb/ov7670_pclk_rx_tb.sv',
    'hardware/tb/ov7670_source_sync_axis_tb.sv',
    'hardware/constraints/zybo_z7_20_ov7670_stage3.xdc',
    'hardware/vivado/baselines/qr_video30_stage2.bd',
    'hardware/vivado/README.md',
    'software/vitis/Qr_barcode_working_ver0_app/src',
    'software/tests',
    'tools',
    'Vivado/qr_video30_stage3/qr_video30_stage3.bit',
    'Vivado/qr_video30_stage3/qr_video30_stage3.xsa',
    'Vivado/qr_video30_stage3/design.tcl',
    'Vivado/qr_video30_stage3/timing_summary.rpt',
    'Vivado/qr_video30_stage3/utilization.rpt',
    'Vivado/qr_video30_stage3/cdc.rpt',
    'Vivado/qr_video30_stage3/bus_skew_verified.rpt',
    'Vivado/qr_video30_stage3/io.rpt',
    'Vivado/qr_video30_stage3/clocks.rpt',
    'Vivado/qr_video30_stage3/camera_input_timing.rpt',
    'Vivado/video30_stage3_build4.log',
    'Vivado/video30_stage3_physical_verify_final.log',
    'Vivado/camera_stage3_sim/camera_small.log',
    'Vivado/camera_stage3_sim/camera_vga.log',
    'Vivado/camera_stage3_sim/camera_control.log',
    'Vitis_video30_stage3/build/Qr_barcode_working_ver0_app.elf',
    'Vitis_video30_stage3/build/CMakeCache.txt',
    'Vitis_video30_stage3/build/compile_commands.json',
    'Vitis_video30_stage3/colorbars/Qr_barcode_working_ver0_app.elf',
    'Vitis_video30_stage3/rejected_30fps_initial.elf',
    'Vitis_video30_stage3/half/Qr_barcode_working_ver0_app.elf',
    'Vitis_video30_stage3/drive1x/Qr_barcode_working_ver0_app.elf',
    'Vitis_video30_stage3/drive3x/Qr_barcode_working_ver0_app.elf',
    'Docs/VIDEO_30FPS_STAGE3_20260917.md'
)
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Docs/performance') -File -Filter 'video30_stage3_*' | ForEach-Object {$_.FullName.Substring($root.Length+1)})
foreach($relative in $inputs) {
    if(!(Test-Path -LiteralPath (Join-Path $root $relative))) {throw "Missing checkpoint input $relative"}
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
    version='video30_stage3_20260917'; created=(Get-Date).ToString('o')
    baseline_dependency='video30_stage2_20260917.zip'
    baseline_sha256='0D22DCF53172602D115EF50B69B4D7F5D095B08063DE9B27283E07D2AC2B0FAD'
    full_baseline_dependency='qr_perf_stable_20260917.zip'
    full_baseline_sha256='B1CBF10272A277E1FAF67890EC8E4ACB62EE2BC859DE31861BB86BA46E265A8E'
    note='Delta over stage2/full stable. Requires local Xilinx/Digilent/BSP dependencies. Restore files to workspace paths before running tools, not inside this checkpoint. Normal and diagnostic firmware are separate.'
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
        finally {$stream.Dispose(); $sha.Dispose()}
        if($hash -ne $file.sha256) {throw "ZIP SHA256 mismatch: $($file.path)"}
    }
} finally {$zip.Dispose()}
Write-Output "Verified $($manifest.Count) checkpoint payloads against manifest."
Get-FileHash -LiteralPath "$out.zip"
