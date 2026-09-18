$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/candidate_address_fix_20260917'
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath "$out.zip")) {throw 'Checkpoint exists; do not overwrite'}
$qr=Get-Content (Join-Path $root 'Docs/performance/pl_candidates_global_final_20260917_summary.json') -Raw | ConvertFrom-Json
$video=Get-Content (Join-Path $root 'Docs/performance/pl_candidates_global_final_20260917_video.json') -Raw | ConvertFrom-Json
$camera=Get-Content (Join-Path $root 'Docs/performance/pl_candidates_global_final_20260917_camera.json') -Raw | ConvertFrom-Json
$rxclk=Get-Content (Join-Path $root 'Docs/performance/pl_candidates_global_final_20260917_rxclk.json') -Raw | ConvertFrom-Json
if($qr.device_window_seconds -lt 118 -or !$qr.counters_contiguous -or $qr.analyzed_frames -lt 1700 -or
   $qr.qr_pass -ne $qr.analyzed_frames -or $qr.pl_candidate_frames -ne $qr.analyzed_frames -or
   $qr.pl_candidates -ne 3*$qr.analyzed_frames -or $qr.runtime_error_samples -ne 0 -or
   $qr.camera_overflow_samples -ne 0 -or $qr.nonzero_error_windows -ne 0 -or
   $qr.failure_or_warning_lines -ne 0 -or $qr.log_drops_max -ne 0 -or
   $video.accepted_camera_sof_per_second -lt 29.5 -or $video.accepted_camera_sof_per_second -gt 30.5 -or
   $video.error_windows -ne 0 -or $camera.lost_tokens_max -ne 0 -or $camera.bad_lines_max -ne 0 -or
   $camera.invalid_status_windows -ne 0 -or $rxclk.invalid_clock_windows -ne 0 -or $rxclk.lock_losses_max -ne 0) {throw 'Current-scene candidate benchmark did not pass'}
$originals=@{
 'Vivado/qr_video30_stage4/qr_video30_stage4.bit'='3B0F7C5B32AA1FC338966D557785D682FE03AF530DFD79B994C4B406BD2D031F'
 'Vivado/qr_video30_stage4/qr_video30_stage4.xsa'='3F0072BC7E9EFC9EFEFA246DCD68F9795FEB2770DF3848FF29603B6B7576320F'
 'Vitis_video30_stage4/drive1x/Qr_barcode_working_ver0_app.elf'='0CCDC6E22B92E9170334181DA7A0E7DFF31B8EBE050C5A635D091744927C274E'
}
foreach($p in $originals.Keys) {if((Get-FileHash -LiteralPath (Join-Path $root $p)).Hash -ne $originals[$p]) {throw "Original changed: $p"}}
$inputs=@(
 'hardware/rtl/bridge/qr_binary_bram_address_adapter.v',
 'hardware/tb/qr_candidate_bram_address_tb.sv',
 'software/vitis/Qr_barcode_working_ver0_app/src','software/tests/qr_candidate_packet_test.c',
 'tools/build_candidate_address_fix.tcl','tools/verify_candidate_address_fix.ps1',
 'tools/verify_candidate_physical.tcl','tools/run_candidate_address_fix.tcl',
 'tools/test_candidate_bram_address.ps1','tools/test_candidate_packet.ps1',
 'tools/summarize_candidate_audit.ps1','tools/build_software_perf.ps1',
 'tools/select_candidate_measurement_windows.ps1','hardware/vivado/README.md',
 'tools/archive_candidate_address_fix.ps1',
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.bit',
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.xsa',
 'Vivado/qr_candidate_address_fix/design.tcl','Vivado/qr_candidate_address_fix/timing_summary.rpt',
 'Vivado/qr_candidate_address_fix/utilization.rpt','Vivado/qr_candidate_address_fix/cdc.rpt',
 'Vivado/qr_candidate_address_fix/bus_skew.rpt','Vivado/qr_candidate_address_fix/camera_input_timing.rpt',
 'Vivado/qr_candidate_address_fix/clock_interaction.rpt',
 'Vivado/candidate_bram_address_sim/candidate_address.log','Vivado/candidate_physical.log',
 'Docs/PL_CANDIDATE_ADDRESS_FIX_20260917.md'
)
foreach($profile in @('candidate_global','candidate_audit','candidate_no_morph_audit','candidate_adaptive_audit','candidate_global_audit')) {
    foreach($file in @('Qr_barcode_working_ver0_app.elf','CMakeCache.txt','compile_commands.json')) {$inputs+="Vitis_video30_stage4/$profile/$file"}
}
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Docs/performance') -File -Filter 'pl_candidates_*.json' | ForEach-Object {$_.FullName.Substring($root.Length+1)})
foreach($p in $inputs) {if(!(Test-Path -LiteralPath (Join-Path $root $p))) {throw "Missing archive input: $p"}}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($p in $inputs) {
    $destination=Join-Path $out $p
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $p) -Destination $destination -Recurse
}
$manifest=@(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
    [ordered]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
[ordered]@{version='candidate_address_fix_20260917';created=(Get-Date).ToString('o');baseline_dependency='video30_stage4_20260917.zip';baseline_sha256='AC4B27FAE437D578E1D9E89DD0609429D13071A0A7653A4D2451F543F5A5C4B3';selected_bit='Vivado/qr_candidate_address_fix/qr_candidate_address_fix.bit';selected_elf='Vitis_video30_stage4/candidate_global/Qr_barcode_working_ver0_app.elf';note='Delta over preserved Stage4. Current-scene global threshold=128 only, not general illumination qualification. Decode remains full-frame PS quirc, not PL-guided Geometry/ROI. Requires local Xilinx/Digilent/BSP dependencies.';original_hashes=$originals;files=$manifest} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $out -DestinationPath "$out.zip"
$zip=[IO.Compression.ZipFile]::OpenRead("$out.zip")
try {
    $prefix=(Split-Path -Leaf $out)+'/'
    foreach($file in $manifest) {
        $entry=$zip.GetEntry($prefix+$file.path)
        if($null -eq $entry -or $entry.Length -ne $file.bytes) {throw "ZIP payload missing: $($file.path)"}
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try {$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
        finally {$stream.Dispose();$sha.Dispose()}
        if($hash -ne $file.sha256) {throw "ZIP hash mismatch: $($file.path)"}
    }
} finally {$zip.Dispose()}
"Verified $($manifest.Count) archived payloads."
Get-FileHash -LiteralPath "$out.zip"
