param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
function Row($text) {
 $r=@{};foreach($m in [regex]::Matches($text,'(\w+)=([0-9]+)')){$r[$m.Groups[1].Value]=[long]$m.Groups[2].Value};$r
}
$lat=@($capture.samples | Where-Object {$_.text -match '^\[LATENCY\]'} | ForEach-Object {Row $_.text})
$routes=@($capture.samples | Where-Object {$_.text -match '^\[ROUTE\]'} | ForEach-Object {Row $_.text})
if(!$lat.Count -or $lat.Count -ne $routes.Count){throw 'Incomplete latency/route windows'}
$early=0L;$refine=0L;$max=0L;$qrmax=0L;$attempts=0L;$pass=0L;$weighted=0L
for($i=0;$i -lt $lat.Count;$i++) {
 $l=$lat[$i];$r=$routes[$i]
 foreach($k in @('qr','qr_max_us','fallback_max_us','fallback_early_pass','fallback_refine_attempts','fallback_refine_avg_us')){if(!$l.ContainsKey($k)){throw "Missing $k"}}
 if($l.qr -ne $r.qr -or $l.fallback_early_pass -gt $r.fallback_pass -or
    $l.fallback_early_pass+$l.fallback_refine_attempts -gt $r.fallback_attempts){throw 'Fallback accounting mismatch'}
 $early+=$l.fallback_early_pass;$refine+=$l.fallback_refine_attempts
 $attempts+=$r.fallback_attempts;$pass+=$r.fallback_pass;$weighted+=$r.fallback_attempts*$r.fallback_avg_us
 $max=[math]::Max($max,$l.fallback_max_us);$qrmax=[math]::Max($qrmax,$l.qr_max_us)
}
[ordered]@{source=$Path;windows=$lat.Count;fallback_attempts=$attempts;fallback_pass=$pass;
 fallback_early_pass=$early;fallback_refine_attempts=$refine;
 fallback_average_us=$(if($attempts){$weighted/$attempts}else{0});
 fallback_max_us=$max;qr_max_us=$qrmax;
 injected_events=@($capture.samples | Where-Object {$_.text -match '^\[TEST FALLBACK\]'}).Count;
 slow_events=@($capture.samples | Where-Object {$_.text -match '^\[SLOW\]'} | ForEach-Object {Row $_.text});
 note='Measured maxima, not proven worst-case deadlines. Forced candidate shortage is a separate diagnostic workload.'} |
 ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Output -Encoding UTF8
Get-Content -LiteralPath $Output
