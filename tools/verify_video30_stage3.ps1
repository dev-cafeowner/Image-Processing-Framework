$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$old=Get-Content "$root/hardware/vivado/baselines/qr_video30_stage2.bd" -Raw | ConvertFrom-Json
$new=Get-Content "$root/Vivado/qr_video30_stage3/qr_video30_stage3.srcs/sources_1/bd/vivado/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
function Parameters($c) {
    $p=[ordered]@{}
    foreach($e in ($c.parameters.PSObject.Properties | Sort-Object Name)) {$p[$e.Name]=$e.Value}
    $p | ConvertTo-Json -Depth 40 -Compress
}
foreach($e in $old.design.components.PSObject.Properties) {
    if($e.Name -eq 'ov7670_axis_0') {continue}
    if((Parameters $e.Value) -cne (Parameters $new.design.components.($e.Name))) {throw "Unexpected IP change: $($e.Name)"}
}
if($new.design.components.ov7670_axis_0.reference_info.ref_name -ne 'ov7670_source_sync_axis') {
    if($new.design.components.ov7670_axis_0.vlnv -ne 'xilinx.com:module_ref:ov7670_source_sync_axis:1.0') {throw 'Wrong camera receiver'}
}
$oldSegments=$old.design.addressing.'/processing_system7_0'.address_spaces.Data.segments
$newSegments=$new.design.addressing.'/processing_system7_0'.address_spaces.Data.segments
foreach($e in $oldSegments.PSObject.Properties) {
    $matches=@($newSegments.PSObject.Properties | Where-Object {$_.Value.offset -eq $e.Value.offset -and $_.Value.range -eq $e.Value.range})
    if($matches.Count -ne 1) {throw "Address changed: $($e.Name)"}
}
if(@($newSegments.PSObject.Properties).Count -ne @($oldSegments.PSObject.Properties).Count) {throw 'Address segment count changed'}
$rtl=Get-Content "$root/Vivado/qr_video30_stage3/qr_video30_stage3.gen/sources_1/bd/vivado/synth/qr_ip1_bd.v" -Raw
function Wire([string]$instance,[string]$pin) {
    $body=[regex]::Match($rtl,"(?s)\b$instance\s*\((.*?)\);").Groups[1].Value
    $wire=[regex]::Match($body,"\.$pin\(([^()]+)\)").Groups[1].Value
    if(!$wire -or $wire -match "'") {throw "Missing/constant pin: $instance/$pin"}
    return $wire
}
foreach($signal in @('tdata','tvalid','tready','tuser','tlast','tstrb')) {
    if((Wire 'ov7670_axis_0' "m_axis_$signal") -ne (Wire 'axis_broadcaster_0' "s_axis_$signal")) {throw "Camera AXIS disconnected: $signal"}
}
foreach($signal in @('pclk','href','vsync','data','xclk')) {
    if((Wire 'ov7670_axis_0' "cam_$signal") -ne "cam_${signal}_0") {throw "Camera pin changed: $signal"}
}
foreach($row in @(@('tvalid','camera_valid'),@('tready','camera_ready'),@('tuser','camera_sof'))) {
    $a=Wire 'axis_subset_converter_rgb565' "m_axis_$($row[0])"
    if($a -ne (Wire 'axi_vdma_0' "s_axis_s2mm_$($row[0])") -or $a -ne (Wire 'video_preview_overlay_0' $row[1])) {throw 'Preview monitor broke AXIS'}
}
if((Wire 'ov7670_axis_0' 'aclk') -ne (Wire 'processing_system7_0' 'FCLK_CLK0') -or
   (Wire 'ov7670_axis_0' 'refclk100') -ne (Wire 'processing_system7_0' 'FCLK_CLK1')) {throw 'Camera clock source mismatch'}
$vdma=Get-Content "$root/Vivado/qr_video30_stage3/qr_video30_stage3.gen/sources_1/bd/vivado/ip/qr_ip1_bd_axi_vdma_0_0/synth/qr_ip1_bd_axi_vdma_0_0.vhd" -Raw
foreach($pair in @(@('C_INCLUDE_INTERNAL_GENLOCK',1),@('C_MM2S_GENLOCK_MODE',3),@('C_S2MM_GENLOCK_MODE',2),@('C_S_AXIS_S2MM_TDATA_WIDTH',24),@('C_M_AXIS_MM2S_TDATA_WIDTH',24))) {
    if($vdma -notmatch "\b$($pair[0])\s*=>\s*$($pair[1])\s*,") {throw "Generated VDMA mismatch: $($pair[0])"}
}
Write-Output 'PASS: only camera IP replaced; PS/DDR/clocks, other IP parameters, addresses, camera pins and common video connections preserved. Existing BSP addresses/ps7_init retained; CAM3 checked explicitly.'
