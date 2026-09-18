$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$base=Join-Path $root 'Vivado/qr_video30_stage4/qr_video30_stage4'
$new=Join-Path $root 'Vivado/qr_candidate_address_fix/qr_candidate_address_fix'
$oldBd=Get-Content "$base.srcs/sources_1/bd/vivado/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
$newBd=Get-Content "$new.srcs/sources_1/bd/vivado/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
function Parameters($c) {
    $p=[ordered]@{}
    foreach($e in ($c.parameters.PSObject.Properties | Sort-Object Name)) {$p[$e.Name]=$e.Value}
    $p | ConvertTo-Json -Depth 40 -Compress
}
foreach($e in $oldBd.design.components.PSObject.Properties) {
    if($e.Name -eq 'blk_mem_gen_0') {continue}
    if((Parameters $e.Value) -cne (Parameters $newBd.design.components.($e.Name))) {throw "Unexpected IP parameter change: $($e.Name)"}
}
if(($oldBd.design.addressing | ConvertTo-Json -Depth 60 -Compress) -cne ($newBd.design.addressing | ConvertTo-Json -Depth 60 -Compress)) {throw 'PS address map changed'}
$oldXci=Get-Content "$base.srcs/sources_1/bd/vivado/ip/qr_ip1_bd_blk_mem_gen_0_0/qr_ip1_bd_blk_mem_gen_0_0.xci" -Raw | ConvertFrom-Json
$newXci=Get-Content "$new.srcs/sources_1/bd/vivado/ip/qr_ip1_bd_blk_mem_gen_0_0/qr_ip1_bd_blk_mem_gen_0_0.xci" -Raw | ConvertFrom-Json
foreach($p in @('use_bram_block','Enable_32bit_Address','Write_Width_A','Read_Width_A','Write_Width_B','Read_Width_B','Write_Depth_A','READ_LATENCY_A','READ_LATENCY_B','Use_Byte_Write_Enable','Byte_Size','Register_PortA_Output_of_Memory_Primitives','Register_PortB_Output_of_Memory_Primitives','Register_PortA_Output_of_Memory_Core','Register_PortB_Output_of_Memory_Core')) {
    if($oldXci.ip_inst.parameters.component_parameters.$p[0].value -ne $newXci.ip_inst.parameters.component_parameters.$p[0].value) {throw "BMG contract changed: $p"}
}
$rtl=Get-Content "$new.gen/sources_1/bd/vivado/synth/qr_ip1_bd.v" -Raw
function Wire([string]$instance,[string]$pin) {
    $body=[regex]::Match($rtl,"(?s)\b$instance\s*\((.*?)\);").Groups[1].Value
    $wire=[regex]::Match($body,"\.$pin\(([^()]+)\)").Groups[1].Value
    if(!$wire -or $wire -match "'") {throw "Missing/constant/truncated pin: $instance/$pin"}
    return $wire
}
$reader=($newBd.design.components.PSObject.Properties | Where-Object {$_.Value.vlnv -match ':qr_vcc_frontend_ip_top:'}).Name
foreach($pair in @(@('write_byte','addra'),@('read_byte','addrb'),@('write_lanes','wea'),@('read_write_lanes','web'))) {
    if((Wire 'binary_address_adapter' $pair[0]) -ne (Wire 'blk_mem_gen_0' $pair[1])) {throw "Address adapter disconnected: $($pair[0])"}
}
if((Wire 'binary_address_adapter' 'write_word') -ne (Wire 'vision_frontend_ip_0' 'wr_addr') -or
   (Wire 'binary_address_adapter' 'read_word') -ne (Wire $reader 'bram_addr')) {throw 'Word addresses disconnected'}
foreach($pair in @(@('bram_clk','clkb'),@('bram_rst','rstb'),@('bram_en','enb'),@('bram_din','dinb'),@('bram_dout','doutb'))) {
    if((Wire $reader $pair[0]) -ne (Wire 'blk_mem_gen_0' $pair[1])) {throw "Reader memory connection changed: $($pair[0])"}
}
foreach($signal in @('tdata','tvalid','tready','tuser','tlast','tstrb')) {
    if((Wire 'ov7670_axis_0' "m_axis_$signal") -ne (Wire 'axis_broadcaster_0' "s_axis_$signal")) {throw "Camera AXIS disconnected: $signal"}
}
foreach($signal in @('pclk','href','vsync','data','xclk')) {
    if((Wire 'ov7670_axis_0' "cam_$signal") -ne "cam_${signal}_0") {throw "Camera port changed: $signal"}
}
foreach($row in @(@('tvalid','camera_valid'),@('tready','camera_ready'),@('tuser','camera_sof'))) {
    $net=Wire 'axis_subset_converter_rgb565' "m_axis_$($row[0])"
    if($net -ne (Wire 'axi_vdma_0' "s_axis_s2mm_$($row[0])") -or $net -ne (Wire 'video_preview_overlay_0' $row[1])) {throw 'Common video path disconnected'}
}
if((Wire 'ov7670_axis_0' 'aclk') -ne (Wire 'processing_system7_0' 'FCLK_CLK0') -or
   (Wire 'ov7670_axis_0' 'refclk100') -ne (Wire 'processing_system7_0' 'FCLK_CLK1')) {throw 'Camera clock source changed'}
Write-Output 'PASS: unchanged Stage4 IP parameters/address map and BMG geometry/latency; both generated address ports and byte lanes use explicit adapter.'
