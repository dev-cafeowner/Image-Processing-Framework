param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$lines=@($capture.samples | Where-Object {$_.text -match '^\[RXCLK\]'})
if (!$lines.Count) { throw 'No returned-clock telemetry; clock integrity is unverified' }
$rows=@(foreach($line in $lines) {
    if ($line.text -notmatch '^\[RXCLK\] status=([0-9a-fA-F]{8}) losses=(\d+)\s*$') {
        throw 'Malformed returned-clock telemetry'
    }
    [pscustomobject]@{status=[Convert]::ToUInt32($Matches[1],16);losses=[long]$Matches[2]}
})
$camCount=@($capture.samples | Where-Object {$_.text -match '^\[CAM3\]'}).Count
if ($camCount -ne $rows.Count) { throw 'CAM3/RXCLK telemetry mismatch: use a single post-BUILD capture' }
$result=[ordered]@{
    source=$Path;windows=$rows.Count
    invalid_clock_windows=@($rows | Where-Object {$_.status -ne 3 -or $_.losses -ne 0}).Count
    lock_losses_max=($rows | Measure-Object losses -Maximum).Maximum
    note='MMCM status, not analog signal-integrity proof. CAM3 pclk_edges in this build counts conditioned clock cycles, not raw input transitions.'
}
$result | ConvertTo-Json | Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
if ($result.invalid_clock_windows) { throw 'Returned clock was not continuously valid' }
