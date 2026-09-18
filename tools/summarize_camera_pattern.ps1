param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$rows=@(foreach($sample in $capture.samples) {
    if ($sample.text -notmatch '^\[PATTERN\]') {continue}
    if ($sample.text -notmatch '^\[PATTERN\] n=(\d+) hash=([0-9a-fA-F]{8}) row_mismatch_pixels=(\d+) samples=(\d+(?:,\d+){7})\s*$') {
        throw 'Malformed PATTERN telemetry'
    }
    [pscustomobject]@{frame=[long]$Matches[1];hash=$Matches[2].ToLower();row_mismatches=[long]$Matches[3];samples=$Matches[4]}
})
if (!$rows.Count) {throw 'No sampled colorbar frames'}
for($i=1; $i -lt $rows.Count; ++$i) {
    if ($rows[$i].frame -le $rows[$i-1].frame) {throw 'Pattern frame IDs restarted or duplicated'}
}
$result=[ordered]@{
    source=$Path;sampled_frames=$rows.Count
    distinct_hashes=@($rows.hash | Sort-Object -Unique)
    mismatch_frames=@($rows | Where-Object {
        $_.hash -ne 'b1b9fd05' -or $_.row_mismatches -ne 0 -or $_.samples -ne '255,226,176,145,105,76,27,0'
    }).Count
    max_row_mismatch_pixels=($rows | Measure-Object row_mismatches -Maximum).Maximum
    note='Compares sampled Gray8 snapshots against the preserved stage3 colorbar result. Not all sensor frames and not real-scene quality or QR recognition.'
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
if ($result.mismatch_frames) {throw 'Colorbar samples differ from the preserved expected pattern'}
