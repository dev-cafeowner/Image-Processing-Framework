param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
function Parse-Row($text) {
    $row=[ordered]@{}
    foreach($m in [regex]::Matches($text,'(\w+)=([0-9]+)')) {$row[$m.Groups[1].Value]=[long]$m.Groups[2].Value}
    [pscustomobject]$row
}
$routes=@($capture.samples | Where-Object {$_.text -match '^\[ROUTE\]'} | ForEach-Object {Parse-Row $_.text})
$summaries=@($capture.samples | Where-Object {$_.text -match '^\[SUMMARY\]'} | ForEach-Object {Parse-Row $_.text})
if(!$routes.Count -or $routes.Count -ne $summaries.Count) {throw 'Require matching complete ROUTE/SUMMARY windows'}
$sums=[ordered]@{}
foreach($key in @('qr','guided_attempts','guided_pass','geometry_reject','packet_reject','fallback_attempts','fallback_pass','fallback_skipped','early_pass','refine_attempts','refine_pass')) {$sums[$key]=0L}
$proposalUs=0.0;$guidedUs=0.0;$fallbackUs=0.0;$roiPixels=0.0;$refineUs=0.0
for($i=0;$i -lt $routes.Count;++$i) {
    $r=$routes[$i];$s=$summaries[$i]
    foreach($key in @('qr','guided_attempts','guided_pass','geometry_reject','packet_reject','fallback_attempts','fallback_pass','fallback_skipped','proposal_avg_us','guided_avg_us','fallback_avg_us','roi_avg_pixels')) {
        if($null -eq $r.PSObject.Properties[$key]) {throw "Incomplete route field $key"}
    }
    if($r.qr -ne $s.qr -or $r.guided_pass+$r.fallback_pass -ne $s.pass -or
       $r.guided_attempts -gt 2*$r.qr -or $r.guided_pass -gt $r.guided_attempts -or
       $r.fallback_pass -gt $r.fallback_attempts -or
       $r.fallback_attempts+$r.fallback_skipped+$r.guided_pass -ne $r.qr) {throw 'Route accounting mismatch'}
    foreach($key in @($sums.Keys)) {$sums[$key]+=[long]$r.$key}
    $proposalUs+=$r.proposal_avg_us*$r.qr
    $guidedUs+=$r.guided_avg_us*$r.guided_attempts
    $fallbackUs+=$r.fallback_avg_us*$r.fallback_attempts
    $roiPixels+=$r.roi_avg_pixels*$r.guided_attempts
    $refineUs+=$r.refine_avg_us*$r.refine_attempts
}
$result=[ordered]@{source=$Path;windows=$routes.Count;accounting_valid=$true}
foreach($key in $sums.Keys) {$result[$key]=$sums[$key]}
$result.proposal_average_us=$proposalUs/$sums.qr
$result.guided_average_us=if($sums.guided_attempts){$guidedUs/$sums.guided_attempts}else{0}
$result.fallback_average_us=if($sums.fallback_attempts){$fallbackUs/$sums.fallback_attempts}else{0}
$result.refine_average_us=if($sums.refine_attempts){$refineUs/$sums.refine_attempts}else{0}
$result.roi_average_pixels=if($sums.guided_attempts){$roiPixels/$sums.guided_attempts}else{0}
$result.note='Window averages have integer rounding. Bounds limit work count, not wall-clock deadlines; skipped fallbacks count as misses, never old successes.'
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
