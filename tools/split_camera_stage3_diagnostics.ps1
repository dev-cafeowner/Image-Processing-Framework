# Preserve all original records; split diagnostic boots at observed stage banner.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$source=Join-Path $root 'Docs/performance/video30_stage3_normal_raw.json'
$capture=Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
$starts=@(for($i=0;$i -lt $capture.samples.Count;++$i) {
    if($capture.samples[$i].text -match '^ Stage 6 Continuous QR Runtime$') {$i}
})
if($starts.Count -ne 3) {throw 'Expected exactly three diagnostic boots'}
$names=@('failed30','half_initial','drive1x')
for($run=0;$run -lt $starts.Count;++$run) {
    $end=if($run+1 -lt $starts.Count) {$starts[$run+1]} else {$capture.samples.Count}
    $rows=@($capture.samples | Select-Object -Skip $starts[$run] -First ($end-$starts[$run]))
    if(@($rows | Where-Object {$_.text -match '^\[BUILD\]'}).Count -ne 1) {throw 'Invalid diagnostic split'}
    [ordered]@{source=$source;started=$capture.started;duration_s=$capture.duration_s;
        note='Split by recorded Stage 6 boot banners; no original records modified.';
        samples=$rows} | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $root "Docs/performance/video30_stage3_$($names[$run])_uart.json") -Encoding UTF8
}
