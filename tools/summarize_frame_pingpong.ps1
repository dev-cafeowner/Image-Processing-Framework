param([Parameter(Mandatory=$true)][string]$Path,[string]$Output)
$ErrorActionPreference='Stop'
$raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$rows=@(); $current=$null
foreach($s in $raw.samples) {
 $line=[string]$s.text
 if($line -match '^\[SUMMARY\]') {
  $current=@{}
  foreach($m in [regex]::Matches($line,'(\w+)=([0-9]+)')){$current[$m.Groups[1].Value]=[long]$m.Groups[2].Value}
 }
 if($line -match '^\[QUEUE\]' -and $current) {
  $q=@{}
  foreach($m in [regex]::Matches($line,'(\w+)=([0-9a-fA-F]+)')){
   $key=$m.Groups[1].Value; $value=$m.Groups[2].Value
   $q[$key]=if($key -eq 'pl_err'){[Convert]::ToInt64($value,16)}else{[long]$value}
  }
  foreach($key in @('accepted','image_done','received','taken','released','pl_err','ps_err','no_slot_polls','rearm_max_us','next_id','capture_skips_total')){if(!$q.ContainsKey($key)){throw "Missing QUEUE $key"}}
  if($q.pl_err -or $q.ps_err -or $q.released -ne $q.taken -or $q.received -lt $q.taken -or
     $q.received -gt $q.taken+1 -or $q.accepted -lt $q.received -or $q.accepted -gt $q.taken+2 -or
     $q.image_done -lt $q.received -or $q.image_done -gt $q.accepted -or $q.next_id -ne $q.accepted){throw "Queue ownership/counter failure: $line"}
  $rows+=,[pscustomobject]@{summary=$current;queue=$q}; $current=$null
 }
}
if($rows.Count -lt 2){throw 'At least two complete QUEUE windows required'}
$seconds=0.0; $accepted=0L; $received=0L; $taken=0L
for($i=1;$i -lt $rows.Count;$i++) {
 $a=$rows[$i-1].queue; $b=$rows[$i].queue
 if($b.taken-$a.taken -ne $rows[$i].summary.qr){throw 'Repeated/missing QR identity count'}
 foreach($k in @('accepted','received','taken','released')){if($b[$k] -lt $a[$k]){throw 'Counter reset in measurement'}}
 $seconds+=$rows[$i].summary.window_us/1e6
 $accepted+=$b.accepted-$a.accepted; $received+=$b.received-$a.received; $taken+=$b.taken-$a.taken
}
$result=[ordered]@{windows=$rows.Count;delta_seconds=$seconds;accepted_delta=$accepted;received_delta=$received;paired_qr_delta=$taken;
 accepted_per_second=$accepted/$seconds;paired_qr_per_second=$taken/$seconds;
 rearm_max_us=($rows.queue.rearm_max_us | Measure-Object -Maximum).Maximum;
 prepare_max_us=($rows.queue.prepare_max_us | Measure-Object -Maximum).Maximum;
 no_slot_polls=($rows.queue.no_slot_polls | Measure-Object -Sum).Sum;
 capture_skips_delta=$rows[-1].queue.capture_skips_total-$rows[0].queue.capture_skips_total;
 capture_skips_total=$rows[-1].queue.capture_skips_total;ownership_errors=0;frame_counts_contiguous=$true;
 note='Rates use cumulative QUEUE deltas after first row; SUMMARY/ROUTE full-window rates are reported separately. no_slot_polls are not dropped frames.'}
$result | ConvertTo-Json
if($Output){$result | ConvertTo-Json | Set-Content -LiteralPath $Output -Encoding UTF8}
