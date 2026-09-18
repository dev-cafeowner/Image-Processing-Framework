$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$old = Get-Content "$root/hardware/vivado/baselines/qr_perf_stage1.bd" -Raw | ConvertFrom-Json
$new = Get-Content "$root/Vivado/qr_video30_stage2/qr_video30_stage2.srcs/sources_1/bd/vivado/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
function Parameters($component, [string]$exclude = '') {
    $p = [ordered]@{}
    foreach ($entry in ($component.parameters.PSObject.Properties | Sort-Object Name)) {
        if ($entry.Name -ne $exclude) { $p[$entry.Name] = $entry.Value }
    }
    $p | ConvertTo-Json -Depth 30 -Compress
}
foreach ($entry in $old.design.components.PSObject.Properties) {
    $except = if ($entry.Name -eq 'axi_smc') { 'NUM_MI' } else { '' }
    if ((Parameters $entry.Value $except) -cne (Parameters $new.design.components.($entry.Name) $except)) {
        throw "Unexpected component parameter drift: $($entry.Name)"
    }
}
if ($new.design.components.axi_smc.parameters.NUM_MI.value -ne '9') { throw 'Expected nine control ports' }
$segments = $new.design.addressing.'/processing_system7_0'.address_spaces.Data.segments
$overlay = $segments.SEG_video_preview_overlay_0_reg0
if ($overlay.offset -ne '0x43C30000' -or $overlay.range -ne '32K') { throw 'Unexpected overlay address map' }
$segments.PSObject.Properties.Remove('SEG_video_preview_overlay_0_reg0')
if (($old.design.addressing | ConvertTo-Json -Depth 40 -Compress) -cne ($new.design.addressing | ConvertTo-Json -Depth 40 -Compress)) {
    throw 'Existing address map changed; do not reuse BSP'
}
$netlist = Get-ChildItem "$root/Vivado/qr_video30_stage2/qr_video30_stage2.gen" -Filter '*axi_vdma*sim_netlist.v' -Recurse | Select-Object -First 1
if (!$netlist) { throw 'Missing generated VDMA netlist' }
foreach ($expect in @('C_INCLUDE_INTERNAL_GENLOCK = "1"','C_MM2S_GENLOCK_MODE = "3"','C_S2MM_GENLOCK_MODE = "2"')) {
    if (!(Select-String -LiteralPath $netlist.FullName -SimpleMatch $expect)) { throw "Missing $expect" }
}
$rtl = Get-Content "$root/Vivado/qr_video30_stage2/qr_video30_stage2.gen/sources_1/bd/vivado/synth/qr_ip1_bd.v" -Raw
function Wire([string]$instance, [string]$pin) {
    $body = [regex]::Match($rtl, "(?s)\b$instance\s*\((.*?)\);").Groups[1].Value
    $wire = [regex]::Match($body, "\.$pin\(([^()]+)\)").Groups[1].Value
    if (!$wire -or $wire -match "'") { throw "Missing/constant pin: $instance/$pin" }
    return $wire
}
foreach ($row in @(@('tvalid','camera_valid'),@('tready','camera_ready'),@('tuser','camera_sof'))) {
    $a = Wire 'axis_subset_converter_rgb565' "m_axis_$($row[0])"
    $b = Wire 'axi_vdma_0' "s_axis_s2mm_$($row[0])"
    $c = Wire 'video_preview_overlay_0' $row[1]
    if ($a -ne $b -or $a -ne $c) { throw "Monitor disconnected original AXIS $($row[0])" }
}
foreach ($signal in @('tdata','tvalid','tready','tuser','tlast')) {
    if ((Wire 'axis_subset_converter_0' "m_axis_$signal") -ne (Wire 'video_preview_overlay_0' "s_axis_$signal")) {
        throw "Overlay input disconnected: $signal"
    }
    if ((Wire 'video_preview_overlay_0' "m_axis_$signal") -ne (Wire 'v_axi4s_vid_out_0' "s_axis_video_$signal")) {
        throw "Overlay output disconnected: $signal"
    }
}
Write-Output 'PASS: existing IP parameters, PS clocks/DDR and address mappings unchanged; only control port + overlay added. Internal VDMA dynamic genlock confirmed. Existing BSP and ps7_init apply; new overlay uses explicit PRV1 ABI.'
