param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
function Rows($tag) {
    @($capture.samples | Where-Object {$_.text -match "^\[$tag\]"} | ForEach-Object {
        $row=[ordered]@{}
        foreach($m in [regex]::Matches($_.text,'(\w+)=([0-9]+)')) {$row[$m.Groups[1].Value]=[long]$m.Groups[2].Value}
        [pscustomobject]$row
    })
}
$p=@(Rows 'PIPE');$m=@(Rows 'PIPEMAX');$o=@(Rows 'PIPEOBS');$s=@(Rows 'SUMMARY')
if(!$p.Count -or $p.Count -ne $m.Count -or $p.Count -ne $o.Count -or $p.Count -ne $s.Count) {throw 'Need common complete PIPE/PIPEMAX/PIPEOBS/SUMMARY windows'}
$keys=@('arm_sof_us','capture_us','pl_us','dma_setup_us','result_wait_us','image_tail_us','cache_us','validate_us','ack_us','rearm_us')
$sum=[ordered]@{};$max=[ordered]@{}
foreach($key in $keys) {$sum[$key]=0.0;$max[$key]=0L}
$n=0L;$bad=0L;$periods=0L;$periodSum=0.0;$imageN=0L;$imageSum=0.0;$busyN=0L;$busySum=0.0
for($i=0;$i -lt $p.Count;++$i) {
    foreach($key in @('n','periods','period_us','image_n','image_done_us','busy_n','busy_delay_us','sof_gap_us','fe_gap_us','result_gap_us','poll_gap_us')) {
        if($null -eq $o[$i].PSObject.Properties[$key]) {throw "Missing observation field $key"}
    }
    if($p[$i].n+$p[$i].bad -ne $s[$i].qr -or $m[$i].n -ne $p[$i].n -or $o[$i].n -ne $p[$i].n) {throw 'Trace frame accounting mismatch; remove initial partial/startup block'}
    foreach($key in $keys) {
        if($null -eq $p[$i].PSObject.Properties[$key] -or $null -eq $m[$i].PSObject.Properties[$key]) {throw "Missing phase $key"}
        if($p[$i].$key -gt $m[$i].$key) {throw "Average exceeds maximum for $key"}
        $sum[$key]+=$p[$i].$key*$p[$i].n
        $max[$key]=[math]::Max($max[$key],$m[$i].$key)
    }
    $n+=$p[$i].n;$bad+=$p[$i].bad
    $periods+=$o[$i].periods;$periodSum+=$o[$i].period_us*$o[$i].periods
    $imageN+=$o[$i].image_n;$imageSum+=$o[$i].image_done_us*$o[$i].image_n
    $busyN+=$o[$i].busy_n;$busySum+=$o[$i].busy_delay_us*$o[$i].busy_n
}
if(!$n){throw 'No valid pipeline observations'}
$average=[ordered]@{};$total=0.0
foreach($key in $keys) {$average[$key]=$sum[$key]/$n;$total+=$average[$key]}
$result=[ordered]@{source=$Path;windows=$p.Count;valid_frames=$n;bad_frames=$bad;
 phase_average_us=$average;phase_max_us=$max;sum_phase_average_us=$total;
 accepted_sof_period_average_us=$(if($periods){$periodSum/$periods}else{$null});
 sof_to_image_done_average_us=$(if($imageN){$imageSum/$imageN}else{$null});
 fe_to_busy_observed_average_us=$(if($busyN){$busySum/$busyN}else{$null});
 sof_observation_gap_max_us=($o|Measure-Object sof_gap_us -Maximum).Maximum;
 fe_observation_gap_max_us=($o|Measure-Object fe_gap_us -Maximum).Maximum;
 result_observation_gap_max_us=($o|Measure-Object result_gap_us -Maximum).Maximum;
 any_poll_gap_max_us=($o|Measure-Object poll_gap_us -Maximum).Maximum;
 note='PS first-observed timestamps. Result wait includes polling latency, not pure DMA transfer. Capture/PL split uncertainty is bounded by adjacent event observation gaps. Arm-to-arm partition overlaps previous-frame PS decode: do not add QR decode time to this sum.'}
$result|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
