param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$frames=[ordered]@{}
foreach($sample in $capture.samples) {
    if($sample.text -notmatch '^\[(PLAUDIT|PLCAND|PSAUDIT|PSCAP)\]') {continue}
    $kind=$Matches[1]
    $fields=[ordered]@{}
    foreach($m in [regex]::Matches($sample.text,'(\w+)=(-?\d+)')) {$fields[$m.Groups[1].Value]=[long]$m.Groups[2].Value}
    $item=[pscustomobject]$fields
    $key=[string]$item.frame
    if(!$frames.Contains($key)) {$frames[$key]=@{pl=$null;ps=$null;pl_items=@();ps_items=@()}}
    switch($kind) {
        PLAUDIT {$frames[$key].pl=$item}
        PSAUDIT {$frames[$key].ps=$item}
        PLCAND {$frames[$key].pl_items+=@($item)}
        PSCAP {$frames[$key].ps_items+=@($item)}
    }
}
$result=@()
foreach($key in $frames.Keys) {
    $f=$frames[$key]
    if(!$f.pl -or !$f.ps) {continue}
    if($f.pl.check -eq 0 -and $f.pl_items.Count -ne $f.pl.count) {throw "Incomplete PL records for frame $key"}
    if($f.ps_items.Count -ne $f.ps.last_scan_caps) {throw "Incomplete PS records for frame $key"}
    $distances=@()
    foreach($c in $f.pl_items) {
        $d=@($f.ps_items | ForEach-Object {[math]::Sqrt([math]::Pow($c.cx-$_.cx,2)+[math]::Pow($c.cy-$_.cy,2))})
        if($d.Count) {$distances+=@(($d | Measure-Object -Minimum).Minimum)}
    }
    $result+=@([pscustomobject]@{frame=[long]$key;count=$f.pl.count;check=$f.pl.check;checked=$f.pl.checked;invalid=$f.pl.invalid;ps_caps=$f.ps.last_scan_caps;ps_status=$f.ps.status;pl_nearest_ps_distances=$distances;pl_items=$f.pl_items;ps_items=$f.ps_items})
}
if(!$result.Count) {throw 'No paired PL/PS audit frames'}
$nonzero=@($result | Where-Object {$_.count -gt 0})
$three=@($result | Where-Object {$_.count -ge 3})
$allDistances=@($result | ForEach-Object {$_.pl_nearest_ps_distances})
$summary=[ordered]@{source=$Path;paired_samples=$result.Count;nonzero_samples=$nonzero.Count;three_or_more_samples=$three.Count;sampled_candidates=($result | Measure-Object count -Sum).Sum;cumulative_checked=$result[-1].checked;cumulative_invalid=$result[-1].invalid;sampled_check_failures=@($result | Where-Object {$_.check -ne 0}).Count;nearest_ps_distances=$allDistances;frames=$result;note='Sampled diagnostic only. Nearest PS center distance is not ground-truth precision/recall; PS caps belong to the final threshold scan. UART output affects timing.'}
$output=$Path -replace '\.json$','_summary.json'
if($output -eq $Path) {throw 'Expected JSON input'}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $output -Encoding UTF8
[pscustomobject]$summary | Select-Object source,paired_samples,nonzero_samples,three_or_more_samples,sampled_candidates,cumulative_checked,cumulative_invalid,sampled_check_failures | Format-List
$result | Select-Object frame,count,check,ps_caps,ps_status,@{n='nearest_ps_px';e={$_.pl_nearest_ps_distances -join ','}} | Format-Table
