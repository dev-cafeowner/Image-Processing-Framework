$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root 'Vitis_video30_stage4/pipeline_host_tests'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$phase='arm_sof_us=28000 capture_us=31400 pl_us=5800 dma_setup_us=10 result_wait_us=100 image_tail_us=1 cache_us=461 validate_us=4 ack_us=1 rearm_us=1055'
$lines=@("[SUMMARY] qr=2 pass=2","[PIPE] n=2 bad=0 $phase","[PIPEMAX] n=2 $phase",'[PIPEOBS] n=2 periods=2 period_us=66640 image_n=2 image_done_us=31400 busy_n=2 busy_delay_us=0 sof_gap_us=100 fe_gap_us=100 result_gap_us=100 poll_gap_us=11000')
function Fixture($items) {
    @{samples=@($items|ForEach-Object {@{text=$_}})}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath "$out/parser_input.json"
}
Fixture $lines
& "$PSScriptRoot/summarize_pipeline_trace.ps1" -Path "$out/parser_input.json" -Output "$out/parser_output.json" | Out-Null
$r=Get-Content "$out/parser_output.json" -Raw|ConvertFrom-Json
if($r.valid_frames -ne 2 -or $r.sum_phase_average_us -ne 66832 -or $r.sof_to_image_done_average_us -ne 31400) {throw 'Weighted phase parsing failed'}
foreach($mutated in @(
    @($lines[0],$lines[1].Replace('n=2','n=1'),$lines[2],$lines[3]),
    @($lines[0],$lines[1].Replace('pl_us=5800',''),$lines[2],$lines[3]),
    @($lines[0],$lines[1],$lines[2],$lines[3].Replace('sof_gap_us=100','')),
    @($lines[0],$lines[1].Replace('pl_us=5800','pl_us=6000'),$lines[2],$lines[3])
)) {
    Fixture $mutated
    $rejected=$false
    try {& "$PSScriptRoot/summarize_pipeline_trace.ps1" -Path "$out/parser_input.json" -Output "$out/parser_rejected.json" | Out-Null}
    catch {$rejected=$true}
    if(!$rejected){throw 'Invalid trace accepted'}
}
'PASS: pipeline phase weighted averages, frame accounting, missing-field and maximum guards'
