$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vivado/camera_stage4_parser'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$path=Join-Path $out 'fixture.json'
$summary=Join-Path $out 'summary.json'
function Check-Case([string]$Script,[string[]]$Lines,[bool]$Reject) {
    @{samples=@($Lines | ForEach-Object {@{text=$_}})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
    $failed=$false
    try {& (Join-Path $PSScriptRoot $Script) -Path $path -Output $summary | Out-Null} catch {$failed=$true}
    if($failed -ne $Reject) {throw "Unexpected acceptance for $Script : $($Lines -join '; ')"}
}
Check-Case 'summarize_rxclk_stage4.ps1' @('[CAM3] test','[RXCLK] status=00000003 losses=0') $false
$got=Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
if($got.windows -ne 1 -or $got.invalid_clock_windows -ne 0) {throw 'RXCLK good fixture failed'}
Check-Case 'summarize_rxclk_stage4.ps1' @('[CAM3] test','[RXCLK] status=00000007 losses=1') $true
Check-Case 'summarize_rxclk_stage4.ps1' @('[CAM3] test','[RXCLK] status=00000003 losses=1') $true
Check-Case 'summarize_rxclk_stage4.ps1' @('[RXCLK] status=00000003 losses=0') $true
Check-Case 'summarize_rxclk_stage4.ps1' @('[CAM3] test') $true
Check-Case 'summarize_rxclk_stage4.ps1' @('[CAM3] test','[RXCLK] status=3 losses=0') $true
$good='[PATTERN] n=1 hash=b1b9fd05 row_mismatch_pixels=0 samples=255,226,176,145,105,76,27,0'
Check-Case 'summarize_camera_pattern.ps1' @($good,$good.Replace('n=1','n=30')) $false
$got=Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
if($got.sampled_frames -ne 2 -or $got.mismatch_frames -ne 0) {throw 'Pattern good fixture failed'}
Check-Case 'summarize_camera_pattern.ps1' @($good,$good) $true
Check-Case 'summarize_camera_pattern.ps1' @($good.Replace('b1b9fd05','b1b9fd04')) $true
Check-Case 'summarize_camera_pattern.ps1' @($good.Replace('pixels=0','pixels=1')) $true
Check-Case 'summarize_camera_pattern.ps1' @($good.Replace('255,226','254,226')) $true
Check-Case 'summarize_camera_pattern.ps1' @('[PATTERN] incomplete') $true
Check-Case 'summarize_camera_pattern.ps1' @('[CAM3] no pattern') $true
'PASS: RXCLK and pattern telemetry, sticky losses, missing/malformed records, incorrect pixel hashes and restarted frame IDs'
