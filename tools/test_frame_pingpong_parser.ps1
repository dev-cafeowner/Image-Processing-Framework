$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$dir=Join-Path $root 'Vivado/frame_pingpong_parser_test'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
function Fixture($mode) {
 $samples=@()
 foreach($i in 1..3){
  $n=$i*30; $a=$n+1; $err=if($mode -eq 'error' -and $i -eq 2){1}else{0}
  $t=if($mode -eq 'repeat' -and $i -eq 2){$n-1}else{$n}
  $r=if($mode -eq 'overwrite' -and $i -eq 2){$t+3}else{$n}
  $samples+=@{text="[SUMMARY] window_us=1000000 qr=30 pass=30 total_qr=$n"}
  $samples+=@{text="[QUEUE] accepted=$a image_done=$n received=$r taken=$t released=$t pl_err=0000000$err ps_err=0 no_slot_polls=0 rearm_max_us=950 next_id=$a capture_skips_total=0"}
 }
 if($mode -eq 'missing'){$samples[1].text=$samples[1].text.Replace(' received=30','')}
 @{samples=$samples} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$dir/$mode.json"
}
Fixture valid
& "$PSScriptRoot/summarize_frame_pingpong.ps1" -Path "$dir/valid.json" -Output "$dir/summary.json" | Out-Null
$v=Get-Content "$dir/summary.json" -Raw | ConvertFrom-Json
if($v.paired_qr_per_second -ne 30 -or $v.ownership_errors -ne 0){throw 'Valid fixture'}
foreach($mode in @('error','repeat','overwrite','missing')) {
 Fixture $mode
 $rejected=$false
 try { & "$PSScriptRoot/summarize_frame_pingpong.ps1" -Path "$dir/$mode.json" | Out-Null } catch {$rejected=$true}
 if(!$rejected){throw "Parser accepted $mode"}
}
'PASS: QUEUE rate/count validation and error/repeat/overwrite/missing-field rejection'
