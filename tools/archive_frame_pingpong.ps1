$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/frame_pingpong_20260917'
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath "$out.zip")){throw 'Checkpoint exists; do not overwrite'}
$prefix=Join-Path $root 'Docs/performance/pingpong_seed8_120s_20260917'
$qr=Get-Content "${prefix}_runtime.json" -Raw | ConvertFrom-Json
$queue=Get-Content "${prefix}_queue.json" -Raw | ConvertFrom-Json
$video=Get-Content "${prefix}_video.json" -Raw | ConvertFrom-Json
$camera=Get-Content "${prefix}_camera.json" -Raw | ConvertFrom-Json
$clock=Get-Content "${prefix}_rxclk.json" -Raw | ConvertFrom-Json
$routes=Get-Content "${prefix}_routes.json" -Raw | ConvertFrom-Json
if($qr.device_window_seconds -lt 120 -or !$qr.counters_contiguous -or $qr.qr_pass -ne $qr.analyzed_frames -or
   $qr.qr_per_second -lt 29.8 -or $qr.runtime_error_samples -or $qr.nonzero_error_windows -or $qr.log_drops_max -or
   !$queue.frame_counts_contiguous -or $queue.ownership_errors -or $queue.capture_skips_delta -lt 0 -or $queue.capture_skips_total -ge 65535 -or
   $video.error_windows -or $camera.lost_tokens_max -or $camera.bad_lines_max -or $camera.invalid_status_windows -or
   $clock.invalid_clock_windows -or $clock.lock_losses_max -or !$routes.accounting_valid -or
   ($routes.guided_pass+$routes.fallback_pass) -ne $qr.analyzed_frames){throw 'Average-throughput qualification gate failed'}
# This checkpoint promises fixed-scene average throughput, not lossless capture
# or a per-frame deadline. All skips and successful fallbacks are recorded.
foreach($mode in @('Stall','Blank')){
 $stem=Join-Path $root ('Docs/performance/pingpong_'+$mode.ToLower()+'_20260917')
 & "$PSScriptRoot/summarize_pingpong_diagnostic.ps1" -Path "$stem.json" -Mode $mode -Output "${stem}_result.json"
 if(!$?){throw "$mode diagnostic failed"}
}
$restored=Get-Content (Join-Path $root 'Docs/performance/pingpong_restored_20260917_runtime.json') -Raw | ConvertFrom-Json
$restoredQueue=Get-Content (Join-Path $root 'Docs/performance/pingpong_restored_20260917_queue.json') -Raw | ConvertFrom-Json
if($restored.device_window_seconds -lt 20 -or !$restored.counters_contiguous -or
 $restored.qr_pass -ne $restored.analyzed_frames -or $restored.qr_per_second -lt 29.8 -or
 $restored.runtime_error_samples -or $restored.nonzero_error_windows -or $restored.log_drops_max -or
 !$restoredQueue.frame_counts_contiguous -or $restoredQueue.ownership_errors){throw 'Normal firmware recovery failed'}
$cache=Get-Content (Join-Path $root 'Vitis_video30_stage4/frame_pingpong_seed8/CMakeCache.txt')
foreach($setting in @('QR_GUIDED_SEED_RADIUS_MIN:STRING=8','QR_PINGPONG:BOOL=TRUE',
 'QR_PERF_BLANK_TEST:BOOL=FALSE','QR_PINGPONG_STALL_TEST:BOOL=FALSE','QR_PIPELINE_TRACE:BOOL=FALSE')){
 if($setting -notin $cache){throw "Selected firmware setting missing: $setting"}
}
$qualified=@{
 'Vivado/qr_frame_pingpong/qr_frame_pingpong.bit'='EEDCEC9813397BCFEFB89642B0CFFFC3EDA4B7751EE5310EA1E6BB006051D33B'
 'Vivado/qr_frame_pingpong/qr_frame_pingpong.xsa'='F8CD0CF1F19EF083B7F2D7CE66E4E5D659D92B61F1A67A1FE35949A1B3CB02B3'
 'Vitis_video30_stage4/frame_pingpong_seed8/Qr_barcode_working_ver0_app.elf'='293574139B3E1FD0C67C7A83F779D2EAFFACDB595E0FC577A453F973E16B638A'
}
foreach($p in $qualified.Keys){if((Get-FileHash -LiteralPath (Join-Path $root $p)).Hash -ne $qualified[$p]){throw "Qualified build changed: $p"}}
$baseline=@{
 'Vitis_video30_stage4/candidate_geometry_fast/Qr_barcode_working_ver0_app.elf'='B13E378CF0E52DE33B4A5D6736A8E8AC66B11431334F2727EC24AD688865886C'
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.bit'='E79E2C7044F1FA8D246C829134E4144782A12234F0807C9A58649C2F0C0B2916'
 'Vivado/releases/pipeline_trace_20260917.zip'='93C8E7B027E117242ED5BAF0BAA03DE069DFA4F42E41F9EA46C73C690C9F3EBD'
}
foreach($p in $baseline.Keys){if((Get-FileHash -LiteralPath (Join-Path $root $p)).Hash -ne $baseline[$p]){throw "Baseline changed: $p"}}
$inputs=@('software/vitis/Qr_barcode_working_ver0_app/src','software/tests','hardware/rtl','hardware/tb','hardware/constraints',
 'hardware/ip_repo/custom','hardware/ip_repo/runtime','Docs/QR_FRAME_PINGPONG_20260917.md',
 'Docs/QR_PIPELINE_BOTTLENECK_20260917.md','Vivado/qr_frame_pingpong/qr_frame_pingpong.bit',
 'Vivado/qr_frame_pingpong/qr_frame_pingpong.xsa','Vivado/qr_frame_pingpong/design.tcl',
 'Vivado/qr_frame_pingpong/timing_summary.rpt','Vivado/qr_frame_pingpong/utilization.rpt','Vivado/qr_frame_pingpong/cdc.rpt',
 'Vivado/qr_frame_pingpong/bus_skew.rpt','Vivado/build_frame_pingpong.log',
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.srcs/sources_1/bd/vivado/qr_ip1_bd.bd',
 'Vitis_run/Qr_barcode_working_ver0_app/_ide/psinit/ps7_init.tcl',
 'tools/build_frame_pingpong.tcl','tools/build_software_perf.ps1','tools/run_frame_pingpong.tcl',
 'tools/run_candidate_geometry.tcl','tools/run_candidate_address_fix.tcl','tools/verify_frame_pingpong.ps1',
 'tools/test_frame_pingpong.ps1','tools/test_gray_ring.ps1','tools/test_pingpong_receiver.ps1',
 'tools/tests/test_gray_ring.c','tools/test_frame_pingpong_parser.ps1','tools/test_candidate_bram_address.ps1',
 'tools/test_candidate_geometry.ps1','tools/test_candidate_packet.ps1','tools/summarize_frame_pingpong.ps1',
 'tools/capture_uart_perf.ps1','tools/select_candidate_measurement_windows.ps1','tools/summarize_runtime_windows.ps1',
 'tools/summarize_geometry_routes.ps1','tools/summarize_video_windows.ps1','tools/summarize_camera_stage3.ps1',
 'tools/summarize_rxclk_stage4.ps1','tools/summarize_pingpong_diagnostic.ps1','tools/archive_frame_pingpong.ps1',
 'Vivado/frame_pingpong_sim/frame_pingpong.log','Vivado/pingpong_candidate_bram_sim/candidate_address.log')
foreach($profile in @('frame_pingpong','frame_pingpong_seed8','frame_pingpong_stall','frame_pingpong_blank')){
 foreach($file in @('Qr_barcode_working_ver0_app.elf','CMakeCache.txt','compile_commands.json')){$inputs+="Vitis_video30_stage4/$profile/$file"}
}
$inputs+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Docs/performance') -File -Filter 'pingpong_*20260917*.json' | ForEach-Object {$_.FullName.Substring($root.Length+1)})
foreach($p in $inputs){if(!(Test-Path -LiteralPath (Join-Path $root $p))){throw "Missing $p"}}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($p in $inputs){
 $dest=Join-Path $out $p
 New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
 Copy-Item -LiteralPath (Join-Path $root $p) -Destination $dest -Recurse
}
$manifest=@(Get-ChildItem -LiteralPath $out -Recurse -File | ForEach-Object {
 [ordered]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}
})
[ordered]@{version='frame_pingpong_20260917';created=(Get-Date).ToString('o');baseline_hashes=$baseline;qualified_hashes=$qualified;
 selected='frame_pingpong_seed8/Qr_barcode_working_ver0_app.elf + qr_frame_pingpong.bit';
 qualification=[ordered]@{scope='Fixed-scene average throughput, not lossless or fixed latency';
 seconds=$qr.device_window_seconds;qr=$qr.analyzed_frames;pass=$qr.qr_pass;qr_per_second=$qr.qr_per_second;
 capture_skips=$queue.capture_skips_delta;guided_pass=$routes.guided_pass;fallback_pass=$routes.fallback_pass};
 note='Separate stall/blank diagnostics followed by normal firmware recovery. RAM/JTAG only. Local Xilinx/BSP and Digilent dependencies required. Camera conditions outside this scene remain unqualified.';files=$manifest} |
 ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$out/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $out -DestinationPath "$out.zip"
$zip=[IO.Compression.ZipFile]::OpenRead("$out.zip")
try {
 $zipPrefix=(Split-Path -Leaf $out)+'/'
 foreach($f in $manifest){
  $entry=$zip.GetEntry($zipPrefix+$f.path)
  if($null -eq $entry -or $entry.Length -ne $f.bytes){throw "ZIP missing $($f.path)"}
  $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
  try {$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
  finally {$stream.Dispose();$sha.Dispose()}
  if($hash -ne $f.sha256){throw "ZIP hash mismatch $($f.path)"}
 }
} finally {$zip.Dispose()}
"Verified $($manifest.Count) archived payloads."
Get-FileHash -LiteralPath "$out.zip"
