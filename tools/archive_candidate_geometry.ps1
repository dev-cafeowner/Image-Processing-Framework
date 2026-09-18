$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/candidate_geometry_20260917'
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath "$out.zip")) {throw 'Checkpoint exists; do not overwrite'}
$prefix=Join-Path $root 'Docs/performance/geometry_roi_fast_120s_20260917'
$qr=Get-Content "${prefix}_runtime.json" -Raw | ConvertFrom-Json
$route=Get-Content "${prefix}_routes.json" -Raw | ConvertFrom-Json
$video=Get-Content "${prefix}_video.json" -Raw | ConvertFrom-Json
$camera=Get-Content "${prefix}_camera.json" -Raw | ConvertFrom-Json
$clock=Get-Content "${prefix}_rxclk.json" -Raw | ConvertFrom-Json
if($qr.device_window_seconds -lt 118 -or !$qr.counters_contiguous -or $qr.qr_pass -ne $qr.analyzed_frames -or
   !$route.accounting_valid -or $route.guided_pass -ne $qr.qr_pass -or $route.fallback_attempts -ne 0 -or
   $qr.runtime_error_samples -ne 0 -or $qr.camera_overflow_samples -ne 0 -or $qr.nonzero_error_windows -ne 0 -or
   $qr.log_drops_max -ne 0 -or $video.error_windows -ne 0 -or $camera.lost_tokens_max -ne 0 -or
   $camera.bad_lines_max -ne 0 -or $camera.invalid_status_windows -ne 0 -or
   $clock.invalid_clock_windows -ne 0 -or $clock.lock_losses_max -ne 0) {throw 'Current-scene validation did not pass'}
$hashes=@{
 'Vitis_video30_stage4/candidate_global/Qr_barcode_working_ver0_app.elf'='C31895A8429672E28FF809ACC56F4EB17083C2A3C3898427ECD818691F6E69F0'
 'Vitis_video30_stage4/candidate_geometry/Qr_barcode_working_ver0_app.elf'='DD595783BFD1C5574A81C5C932C400CB510A98389CFAB6A6D608EF97A6C8E9D2'
 'Vitis_video30_stage4/candidate_geometry_fast/Qr_barcode_working_ver0_app.elf'='B13E378CF0E52DE33B4A5D6736A8E8AC66B11431334F2727EC24AD688865886C'
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.bit'='E79E2C7044F1FA8D246C829134E4144782A12234F0807C9A58649C2F0C0B2916'
 'Vivado/releases/candidate_address_fix_20260917.zip'='33DCC3D270B134C40D0959F49E996E7574E2C52E4C800D68C2B38E77BF7E5CA0'
}
foreach($p in $hashes.Keys) {if((Get-FileHash -LiteralPath (Join-Path $root $p)).Hash -ne $hashes[$p]) {throw "Artifact changed: $p"}}
$inputs=@('software/vitis/Qr_barcode_working_ver0_app/src','software/tests',
 'tools/build_software_perf.ps1','tools/run_candidate_address_fix.tcl','tools/run_candidate_geometry.tcl',
 'tools/test_candidate_packet.ps1','tools/test_candidate_geometry.ps1','tools/capture_uart_perf.ps1',
 'tools/select_candidate_measurement_windows.ps1','tools/summarize_geometry_routes.ps1',
 'tools/summarize_runtime_windows.ps1','tools/summarize_video_windows.ps1',
 'tools/summarize_camera_stage3.ps1','tools/summarize_rxclk_stage4.ps1','tools/archive_candidate_geometry.ps1',
 'Docs/PL_GUIDED_GEOMETRY_ROI_20260917.md')
foreach($profile in @('candidate_global','candidate_geometry','candidate_geometry_fast','candidate_geometry_blank')) {
    foreach($file in @('Qr_barcode_working_ver0_app.elf','CMakeCache.txt','compile_commands.json')) {$inputs+="Vitis_video30_stage4/$profile/$file"}
}
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Docs/performance') -File -Filter 'geometry_roi_*.json' | ForEach-Object {$_.FullName.Substring($root.Length+1)})
foreach($p in $inputs) {if(!(Test-Path -LiteralPath (Join-Path $root $p))) {throw "Missing input $p"}}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($p in $inputs) {
    $dest=Join-Path $out $p
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $p) -Destination $dest -Recurse
}
$manifest=@(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
[ordered]@{version='candidate_geometry_20260917';created=(Get-Date).ToString('o');
 baseline_dependency='candidate_address_fix_20260917.zip';verified_hashes=$hashes;
 selected_bit='Vivado/qr_candidate_address_fix/qr_candidate_address_fix.bit';
 selected_elf='Vitis_video30_stage4/candidate_geometry_fast/Qr_barcode_working_ver0_app.elf';
 note='Software delta over candidate-address-fix. Local Xilinx/BSP dependencies required. Fixed-scene validation only: video input 30fps, actual QR rate remains 15/s. No hardware changes; no flash/SD writes. Source comments updated after selected ELF build, no executable logic changed.';
 files=$manifest} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $out -DestinationPath "$out.zip"
$zip=[IO.Compression.ZipFile]::OpenRead("$out.zip")
try {
    $prefix=(Split-Path -Leaf $out)+'/'
    foreach($file in $manifest) {
        $entry=$zip.GetEntry($prefix+$file.path)
        if($null -eq $entry -or $entry.Length -ne $file.bytes) {throw "Missing ZIP payload $($file.path)"}
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
        finally {$stream.Dispose();$sha.Dispose()}
        if($hash -ne $file.sha256) {throw "ZIP hash mismatch $($file.path)"}
    }
} finally {$zip.Dispose()}
"Verified $($manifest.Count) archived payloads."
Get-FileHash -LiteralPath "$out.zip"
