$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/pipeline_trace_20260917'
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath "$out.zip")) {throw 'Checkpoint exists; do not overwrite'}
$prefix=Join-Path $root 'Docs/performance/pipeline_100us_120s_20260917'
$qr=Get-Content "${prefix}_runtime.json" -Raw|ConvertFrom-Json
$phases=Get-Content "${prefix}_phases.json" -Raw|ConvertFrom-Json
$video=Get-Content "${prefix}_video.json" -Raw|ConvertFrom-Json
$camera=Get-Content "${prefix}_camera.json" -Raw|ConvertFrom-Json
$clock=Get-Content "${prefix}_rxclk.json" -Raw|ConvertFrom-Json
$restored=Get-Content (Join-Path $root 'Docs/performance/pipeline_restored_20260917_runtime.json') -Raw|ConvertFrom-Json
if($qr.device_window_seconds -lt 118 -or !$qr.counters_contiguous -or $qr.qr_pass -ne $qr.analyzed_frames -or
   $phases.valid_frames -ne $qr.analyzed_frames -or $phases.bad_frames -ne 0 -or
   $qr.runtime_error_samples -ne 0 -or $qr.nonzero_error_windows -ne 0 -or $qr.log_drops_max -ne 0 -or
   $video.error_windows -ne 0 -or $camera.lost_tokens_max -ne 0 -or $camera.bad_lines_max -ne 0 -or
   $camera.invalid_status_windows -ne 0 -or $clock.invalid_clock_windows -ne 0 -or $clock.lock_losses_max -ne 0 -or
   !$restored.counters_contiguous -or $restored.qr_pass -ne $restored.analyzed_frames -or
   $restored.runtime_error_samples -ne 0 -or $restored.nonzero_error_windows -ne 0) {throw 'Trace/restore validation failed'}
$hashes=@{
 'Vitis_video30_stage4/candidate_geometry_fast/Qr_barcode_working_ver0_app.elf'='B13E378CF0E52DE33B4A5D6736A8E8AC66B11431334F2727EC24AD688865886C'
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.bit'='E79E2C7044F1FA8D246C829134E4144782A12234F0807C9A58649C2F0C0B2916'
 'Vivado/releases/candidate_geometry_20260917.zip'='AD975D872519666B486D8B225477CF399BB2A43E01FE4E5DD37BC0D1BA4A6414'
 'Vitis_video30_stage4/pipeline_trace_1ms/Qr_barcode_working_ver0_app.elf'='AE1494D9EC9B8DF23772D42D0313C89BC630C956651CFD9B6000BA083D476F27'
 'Vitis_video30_stage4/pipeline_trace_100us/Qr_barcode_working_ver0_app.elf'='2030B3ECF87D4266932DAF2DD770E4D92ABD53F8C2A593664CDE4C72DAD430B8'
}
foreach($p in $hashes.Keys) {if((Get-FileHash -LiteralPath (Join-Path $root $p)).Hash -ne $hashes[$p]) {throw "Artifact changed: $p"}}
$inputs=@('software/vitis/Qr_barcode_working_ver0_app/src','software/tests',
 'Vitis_video30_stage4/pipeline_trace_1ms/source_snapshot',
 'Docs/QR_PIPELINE_BOTTLENECK_20260917.md','tools/build_software_perf.ps1',
 'tools/test_pipeline_trace.ps1','tools/test_pipeline_parser.ps1','tools/summarize_pipeline_trace.ps1',
 'tools/run_candidate_address_fix.tcl','tools/run_candidate_geometry.tcl',
 'tools/select_candidate_measurement_windows.ps1','tools/capture_uart_perf.ps1',
 'tools/summarize_runtime_windows.ps1','tools/summarize_geometry_routes.ps1',
 'tools/summarize_video_windows.ps1','tools/summarize_camera_stage3.ps1','tools/summarize_rxclk_stage4.ps1',
 'tools/archive_pipeline_trace.ps1')
foreach($profile in @('pipeline_trace_1ms','pipeline_trace_100us')) {
    foreach($file in @('Qr_barcode_working_ver0_app.elf','CMakeCache.txt','compile_commands.json')) {$inputs+="Vitis_video30_stage4/$profile/$file"}
}
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Docs/performance') -File -Filter 'pipeline_*20260917*.json' | ForEach-Object {$_.FullName.Substring($root.Length+1)})
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
[ordered]@{version='pipeline_trace_20260917';created=(Get-Date).ToString('o');
 baseline_dependency='candidate_geometry_20260917.zip';verified_hashes=$hashes;
 restored_elf='Vitis_video30_stage4/candidate_geometry_fast/Qr_barcode_working_ver0_app.elf';
 note='Diagnostic software delta; no PL changes. PS first-observed event timestamps with recorded uncertainty. 100us polling does not improve actual QR throughput. Production remains the previously verified trace-off ELF. Local Xilinx/BSP dependencies required.';
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
