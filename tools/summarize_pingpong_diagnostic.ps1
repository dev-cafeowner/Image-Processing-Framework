param(
 [Parameter(Mandatory=$true)][string]$Path,
 [Parameter(Mandatory=$true)][ValidateSet('Stall','Blank')][string]$Mode,
 [Parameter(Mandatory=$true)][string]$Output
)
$ErrorActionPreference='Stop'
$raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$lines=@($raw.samples | ForEach-Object {$_.text})
$boots=@(for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^\[BUILD QPP1\]'){$i}})
if(!$boots.Count){throw 'Missing diagnostic boot; cannot separate previous firmware logs'}
$lines=@($lines | Select-Object -Skip $boots[-1])
function Field([string]$line,[string]$name) {
 if($line -notmatch "(?:^| )${name}=(\d+)(?: |$)"){throw "Missing $name in $line"}
 return [long]$Matches[1]
}
$summaries=@($lines | Where-Object {$_ -match '^\[SUMMARY\]'})
$queues=@($lines | Where-Object {$_ -match '^\[QUEUE\]'})
if($summaries.Count -lt 10 -or $queues.Count -lt 10){throw 'Insufficient post-boot recovery evidence'}
$expectedMisses=0
if($Mode -eq 'Stall'){
 $tests=@($lines | Where-Object {$_ -match '^\[TEST QPP1\]'})
 if($tests.Count -ne 3){throw 'Expected exactly three delayed frames'}
 for($i=0;$i -lt 3;$i++){
  if($tests[$i] -notmatch '^\[TEST QPP1\] id=(\d+) hold_us=120000 before=([0-9a-f]+) after=([0-9a-f]+) intact=1$') {throw 'Invalid preservation result'}
  if([int]$Matches[1] -ne 5+$i -or $Matches[2] -ne $Matches[3]){throw 'Delayed frame ID/digest mismatch'}
 }
} else {
 $expectedMisses=3
 $tests=@($lines | Where-Object {$_ -match '^\[TEST\] White QR snapshot'})
 if($tests.Count -ne 3){throw 'Expected exactly three injected white frames'}
 for($i=0;$i -lt 3;$i++){
  if($tests[$i] -ne "[TEST] White QR snapshot n=$($i+5); live preview unchanged"){throw 'Wrong white frame sequence'}
 }
}
foreach($line in $summaries){
 if((Field $line 'total_qr')-(Field $line 'total_pass') -ne $expectedMisses){throw 'Unexpected cumulative misses after diagnostic'}
 foreach($f in @('drops','display_errors','runtime_errors','camera_overflows')){if((Field $line $f) -ne 0){throw "Nonzero $f"}}
 if($line -notmatch ' err=00000000 vdma_err=00000000$'){throw 'Runtime/VDMA fault'}
}
foreach($line in $queues){if($line -notmatch ' pl_err=00000000 ps_err=0 '){throw 'Queue fault'}}
$last=$summaries[-1]
if((Field $summaries[0] 'total_qr') -ne (Field $summaries[0] 'qr')){throw 'Missing initial diagnostic SUMMARY'}
$recovery=@($summaries | Select-Object -Skip 1)
$frames=0L;$passes=0L;$us=0L
foreach($line in $recovery){$frames+=Field $line 'qr';$passes+=Field $line 'pass';$us+=Field $line 'window_us'}
if($frames -ne $passes -or $frames*1e6/$us -lt 29.8){throw 'Normal recognition did not recover'}
$skips=Field $queues[-1] 'capture_skips_total'
$initialSkips=Field $queues[0] 'capture_skips_total'
if($skips -ne $initialSkips){throw 'Additional capture skips during diagnostic recovery'}
[ordered]@{source=$Path;mode=$Mode;passed=$true;tested_frames=3;
 cumulative_qr=(Field $last 'total_qr');cumulative_pass=(Field $last 'total_pass');
 expected_misses=$expectedMisses;capture_skips_total=$skips;
 recovery_frames=$frames;recovery_passes=$passes;recovery_seconds=$us/1e6;
 recovery_qr_per_second=$frames*1e6/$us;
 note='Only the final QPP1 boot is analyzed. Diagnostic startup windows are not normal performance measurements; full-frame skips during overload are intentional.'} |
 ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding UTF8
Get-Content -LiteralPath $Output
