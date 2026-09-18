param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Output,
    [string]$BuildPattern = '^\[BUILD\] video30_stage2 '
)
$ErrorActionPreference = 'Stop'
$capture = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$indices = @(for ($i=0; $i -lt $capture.samples.Count; ++$i) {
    if ($capture.samples[$i].text -match $BuildPattern) { $i }
})
if ($indices.Count -ne 1) { throw "Expected exactly one matching build marker, got $($indices.Count)" }
$start = $indices[0]
$selected = @($capture.samples | Select-Object -Skip $start)
if (@($selected | Select-Object -Skip 1 | Where-Object {$_.text -match '^\[BUILD\]'}).Count) { throw 'Another restart follows selected marker' }
[ordered]@{
    source=$Path; started=$capture.started; duration_s=$capture.duration_s
    selected_start_ms=$capture.samples[$start].ms; selected_build=$capture.samples[$start].text
    port=$capture.port; baud=$capture.baud; samples=$selected
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Output -Encoding UTF8
Write-Output "Selected $($selected.Count) records after unique build marker; original capture unchanged."
