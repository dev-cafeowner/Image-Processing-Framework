$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/releases/fallback_cadence_prevalidation_20260917'
if((Test-Path $out) -or (Test-Path "$out.zip")){throw 'Snapshot exists; do not overwrite'}
$old=Join-Path $root 'Vivado/releases/frame_pingpong_20260917.zip'
$oldHash='56D3F947A308502453C119D3C5C7D507ABE262A8E42B0228D9273CF956C6A509'
if((Get-FileHash $old).Hash -ne $oldHash){throw 'Qualified baseline archive changed'}
$inputs=@('software/vitis/Qr_barcode_working_ver0_app/src','software/tests',
 'hardware/rtl','hardware/tb','hardware/constraints','hardware/ip_repo/custom','hardware/ip_repo/runtime',
 'Docs/FALLBACK_HDMI_CADENCE_20260917.md','Docs/QR_FRAME_PINGPONG_20260917.md',
 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix.srcs/sources_1/bd/vivado/qr_ip1_bd.bd',
 'Vivado/qr_frame_pingpong/qr_frame_pingpong.bit','Vivado/qr_frame_pingpong/qr_frame_pingpong.xsa',
 'Vivado/qr_hdmi_cadence/qr_hdmi_cadence.bit','Vivado/qr_hdmi_cadence/qr_hdmi_cadence.xsa',
 'Vivado/qr_hdmi_cadence/timing_summary.rpt','Vivado/qr_hdmi_cadence/bus_skew.rpt',
 'Vivado/qr_hdmi_cadence/utilization.rpt','Vivado/qr_hdmi_cadence/cdc.rpt','Vivado/qr_hdmi_cadence/design.tcl',
 'Vivado/rebuild_hdmi_cadence_rtl.log','Vivado/frame_tag_sim/frame_tag.log',
 'Vitis_run/Qr_barcode_working_ver0_app/_ide/psinit/ps7_init.tcl')
foreach($name in @('build_software_perf.ps1','build_frame_pingpong.tcl','finish_frame_pingpong_build.tcl',
 'build_hdmi_cadence.tcl','add_hdmi_frame_tags.tcl','rebuild_hdmi_cadence.tcl',
 'run_frame_pingpong.tcl','run_hdmi_cadence.tcl','verify_frame_pingpong.ps1',
 'test_video_frame_tag.ps1','test_hdmi_cadence.py','hdmi_cadence.py','test_candidate_geometry.ps1',
 'capture_uart_perf.ps1','select_candidate_measurement_windows.ps1','summarize_fallback_latency.ps1',
 'summarize_geometry_routes.ps1','summarize_runtime_windows.ps1','summarize_frame_pingpong.ps1',
 'summarize_video_windows.ps1','summarize_camera_stage3.ps1','summarize_rxclk_stage4.ps1',
 'archive_fallback_cadence.ps1')){$inputs+="tools/$name"}
foreach($profile in @('frame_pingpong_seed8','fallback_control_test','fallback_fast_test','fallback_fast','fallback_fast_blank')){
 foreach($file in @('Qr_barcode_working_ver0_app.elf','CMakeCache.txt','compile_commands.json')){$inputs+="Vitis_video30_stage4/$profile/$file"}
}
$inputs+=@(Get-ChildItem (Join-Path $root 'Docs/performance') -File | Where-Object {$_.Name -match '^(fallback_|hdmi_)'} | ForEach-Object {$_.FullName.Substring($root.Length+1)})
foreach($p in $inputs){if(!(Test-Path -LiteralPath (Join-Path $root $p))){throw "Missing $p"}}
New-Item -ItemType Directory -Path $out | Out-Null
foreach($p in $inputs){
 $dest=Join-Path $out $p
 New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
 Copy-Item -LiteralPath (Join-Path $root $p) -Destination $dest -Recurse
}
$files=@(Get-ChildItem $out -File -Recurse | ForEach-Object {
 [ordered]@{path=$_.FullName.Substring($out.Length+1).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash $_.FullName).Hash}
})
[ordered]@{status='PREVALIDATION ONLY - no real-board performance improvement claimed';
 created=(Get-Date).ToString('o');baseline_archive_sha256=$oldHash;
 note='PS builds/host regressions and diagnostic PL implementation completed. Camera input became noise on both control and preserved baseline; those captures are excluded. Board/sensor power-cycle confirmation and valid input are required before comparative testing. Webcam observes a monitor, not HDMI directly. Xilinx/BSP/Digilent/FFmpeg runtime dependencies remain external.';files=$files} |
 ConvertTo-Json -Depth 6 | Set-Content "$out/manifest.json" -Encoding UTF8
Compress-Archive -LiteralPath $out -DestinationPath "$out.zip"
$zip=[IO.Compression.ZipFile]::OpenRead("$out.zip")
try {
 foreach($f in $files){
  $entry=$zip.GetEntry((Split-Path -Leaf $out)+'/'+$f.path)
  if(!$entry -or $entry.Length -ne $f.bytes){throw "Missing ZIP entry $($f.path)"}
  $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}
  finally{$stream.Dispose();$sha.Dispose()}
  if($hash -ne $f.sha256){throw "ZIP hash mismatch $($f.path)"}
 }
} finally {$zip.Dispose()}
"Verified $($files.Count) prevalidation payloads."
Get-FileHash "$out.zip"
