param(
    [Parameter(Mandatory=$true)][string[]]$Path,
    [Parameter(Mandatory=$true)][DateTimeOffset]$NotBefore,
    [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference = 'Stop'
# Measurement-only helper: preserve originals, normalize host timestamps and
# retain whole telemetry blocks. Call the counter-continuity summarizers after
# this selection; a host-file boundary alone does not prove an uninterrupted run.
$records = @(
    foreach ($inputPath in $Path) {
        $capture = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json
        $start = [DateTimeOffset]$capture.started
        foreach ($sample in $capture.samples) {
            [pscustomobject]@{
                stamp = $start.AddMilliseconds([double]$sample.ms)
                text = $sample.text
                source = $inputPath
            }
        }
    }
) | Sort-Object stamp

# Conservatively omit two seconds beyond the user's confirmation to avoid
# assigning the previous, approximately 1.1-second measurement window to the
# newly fixed scene. All three telemetry streams begin with the same VIDEO block.
$first = $null
for ($i = 0; $i -lt $records.Count; ++$i) {
    if ($records[$i].stamp -ge $NotBefore.AddSeconds(2) -and
        $records[$i].text -match '^\[VIDEO\]') { $first = $i; break }
}
if ($null -eq $first) { throw 'No complete telemetry block after the scene boundary' }
$last = $null
for ($i = $records.Count - 1; $i -ge $first; --$i) {
    if ($records[$i].text -match '^\[RENDER\]') { $last = $i; break }
}
if ($null -eq $last) { throw 'No completed telemetry block' }
$selected = @($records[$first..$last])
if (@($selected | Where-Object {$_.text -match '^\[BUILD\]'}).Count) {
    throw 'Board restart inside selected interval'
}
$counts = @{}
foreach ($tag in @('VIDEO','CAM3','SUMMARY','DECODE','RENDER')) {
    $counts[$tag] = @($selected | Where-Object {$_.text -match "^\[$tag\]"}).Count
}
if (@($counts.Values | Select-Object -Unique).Count -ne 1) {
    throw "Incomplete telemetry blocks: $($counts | ConvertTo-Json -Compress)"
}
$origin = $selected[0].stamp
[ordered]@{
    sources = $Path
    scene_fixed_boundary = $NotBefore.ToString('o')
    started = $origin.ToString('o')
    duration_s = ($selected[-1].stamp - $origin).TotalSeconds
    selection_note = 'Whole blocks after boundary + 2s. Counters must pass separate continuity checks; use device window durations for rates, not host duration_s.'
    telemetry_counts = $counts
    samples = @($selected | ForEach-Object {
        [pscustomobject]@{
            ms = [math]::Round(($_.stamp - $origin).TotalMilliseconds, 3)
            text = $_.text
        }
    })
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Output -Encoding UTF8
Write-Output "Selected $($counts['SUMMARY']) telemetry blocks; run all continuity validators before interpreting the result."
