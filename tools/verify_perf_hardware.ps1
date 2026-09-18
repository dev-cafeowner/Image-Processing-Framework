$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$old = Get-Content "$root/Vivado/qr_perf_backup/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
$new = Get-Content "$root/Vivado/qr_perf/qr_perf.srcs/sources_1/bd/vivado/qr_ip1_bd.bd" -Raw | ConvertFrom-Json
$oldPs = $old.design.components.processing_system7_0.parameters | ConvertTo-Json -Depth 12
$newPs = $new.design.components.processing_system7_0.parameters | ConvertTo-Json -Depth 12
if ($oldPs -cne $newPs) { throw 'PS configuration changed: regenerate platform/PS init' }
$oldAddresses = $old.design.addressing | ConvertTo-Json -Depth 30
$newAddresses = $new.design.addressing | ConvertTo-Json -Depth 30
if (!$oldAddresses -or !$newAddresses -or $oldAddresses -cne $newAddresses) {
    throw 'Address map changed or absent: regenerate BSP'
}
if ($new.design.components.ov7670_axis_0.parameters.C_XCLK_DIV.value -ne '2') {
    throw 'Unexpected XCLK divisor'
}
# Only this camera parameter is deliberately changed; check the remaining
# camera parameters too, rather than excluding the entire component.
function Get-ComparableParameters($component, [bool]$ignoreCameraClock) {
    $parameters = [ordered]@{}
    if ($component.parameters) {
        foreach ($parameter in ($component.parameters.PSObject.Properties | Sort-Object Name)) {
            if ($ignoreCameraClock -and $parameter.Name -eq 'C_XCLK_DIV') { continue }
            $parameters[$parameter.Name] = $parameter.Value
        }
    }
    $parameters | ConvertTo-Json -Depth 20
}
foreach ($component in $old.design.components.PSObject.Properties) {
    $ignoreClock = $component.Name -eq 'ov7670_axis_0'
    $a = Get-ComparableParameters $component.Value $ignoreClock
    $b = Get-ComparableParameters $new.design.components.($component.Name) $ignoreClock
    if ($a -cne $b) { throw "Unexpected parameter drift: $($component.Name)" }
}
Write-Output 'PASS: PS configuration and address map unchanged; existing BSP/ps7_init remain applicable. XCLK divisor is 2.'
