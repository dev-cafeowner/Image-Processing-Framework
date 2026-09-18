param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference='Stop'
$raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$prefix=$Path -replace '_raw\.json$',''
if($prefix -eq $Path){throw 'Expected *_raw.json path'}
$records=@($raw.samples | Where-Object {$_.ms -ge $raw.measurement_start_ms -and $_.ms -lt $raw.measurement_end_ms})
function Fields($text) {
    $result=[ordered]@{}
    foreach($m in [regex]::Matches($text,'(\w+)=([0-9A-Fa-f]+)')) {
        $key=$m.Groups[1].Value;$value=$m.Groups[2].Value
        $result[$key]=if($key -in @('status','err','cam','vdma','fe','vdma_err','mm2s_err')){[Convert]::ToUInt32($value,16)}else{[long]$value}
    }
    return [pscustomobject]$result
}
function Mean($rows,$field) {if($rows.Count){return ($rows | Measure-Object $field -Average).Average};return $null}
function Maximum($rows,$field) {if($rows.Count){return ($rows | Measure-Object $field -Maximum).Maximum};return $null}
$result=[ordered]@{
    id=$raw.profile.id;label=$raw.profile.label;group=$raw.profile.group;outcome=$raw.outcome
    host_observation_s=$raw.requested_measurement_seconds;rate_method=$null
    metric_seconds=$null;qr_count=$null;qr_pass=$null;qr_pass_percent=$null;qr_per_s=$null
    video_per_s=$null;video_metric=$null;qr_average_ms=$null;preview_work_average_ms=$null
    frame_stuck_samples=$null;error_samples=$null;warning_or_failure_lines=0
    raw=$Path;details=@{}
}
if($raw.outcome -ne 'measured') {
    $failureContext=@($raw.samples | Where-Object {$_.ms -ge $raw.program_done_ms -and $_.text -match '^\[(FAIL|CAM3[^\]]*|RXCLK[^\]]*)\]|Stage 6 result: FAIL'} | Select-Object -Last 8)
    $result.details=@{failure=$raw.failure;recorded_duration_s=$raw.duration_s;failure_context=$failureContext}
} elseif(@($records | Where-Object {$_.text -match '^\[SUMMARY\]'}).Count -and @($records | Where-Object {$_.text -match '^\[RENDER\]'}).Count) {
    # Each block ends in RENDER. Drop the first boundary-overlapping block
    # and any incomplete last block. Use only a common block set for all metrics.
    $blocks=New-Object 'System.Collections.Generic.List[object]'
    $current=New-Object 'System.Collections.Generic.List[object]'
    foreach($r in $records) {
        $current.Add($r)
        if($r.text -match '^\[RENDER\]') {
            if(@($current | Where-Object {$_.text -match '^\[SUMMARY\]'}).Count -eq 1) {
                $blocks.Add(@($current.ToArray()))
            }
            $current.Clear()
        }
    }
    if($blocks.Count -lt 3){throw 'Insufficient complete runtime blocks'}
    $selected=@($blocks | Select-Object -Skip 1 | ForEach-Object {$_})
    [ordered]@{started=$raw.started;duration_s=$raw.requested_measurement_seconds;samples=$selected} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "${prefix}_selected.json" -Encoding UTF8
    & "$PSScriptRoot/summarize_runtime_windows.ps1" -Path "${prefix}_selected.json" -Output "${prefix}_qr.json" | Out-Null
    $qr=Get-Content "${prefix}_qr.json" -Raw | ConvertFrom-Json
    $result.rate_method='complete device SUMMARY windows within fixed host observation; first/partial blocks excluded'
    $result.metric_seconds=$qr.device_window_seconds;$result.qr_count=$qr.analyzed_frames;$result.qr_pass=$qr.qr_pass
    $result.qr_per_s=$qr.qr_per_second;$result.qr_average_ms=$qr.qr_inclusive_average_us/1000
    $result.error_samples=$qr.runtime_error_samples+$qr.camera_overflow_samples+$qr.nonzero_error_windows+$qr.preview_errors
    $result.details.qr=$qr
    $result.video_metric='CPU preview submissions (not HDMI or sensor fps)'
    $result.video_per_s=$qr.submitted_preview_per_second
    if($null -ne $qr.preview_copy_average_us){$result.preview_work_average_ms=$qr.preview_copy_average_us/1000}
    if(@($selected | Where-Object {$_.text -match '^\[VIDEO\]'}).Count) {
        & "$PSScriptRoot/summarize_video_windows.ps1" -Path "${prefix}_selected.json" -Output "${prefix}_video.json" | Out-Null
        $video=Get-Content "${prefix}_video.json" -Raw | ConvertFrom-Json
        $result.video_metric='PL accepted camera SOFs (not repeated HDMI scanouts)'
        $result.video_per_s=$video.accepted_camera_sof_per_second
        $result.preview_work_average_ms=$video.hud_full_cpu_average_us/1000
        $result.error_samples+=$video.error_windows;$result.details.video=$video
    }
    if(@($selected | Where-Object {$_.text -match '^\[CAM3\]'}).Count) {
        & "$PSScriptRoot/summarize_camera_stage3.ps1" -Path "${prefix}_selected.json" -Output "${prefix}_camera.json" | Out-Null
        $cam=Get-Content "${prefix}_camera.json" -Raw | ConvertFrom-Json
        $result.error_samples+=$cam.invalid_status_windows+$cam.lost_tokens_max+$cam.bad_lines_max;$result.details.camera=$cam
    }
    if(@($selected | Where-Object {$_.text -match '^\[RXCLK\]'}).Count) {
        try {
            & "$PSScriptRoot/summarize_rxclk_stage4.ps1" -Path "${prefix}_selected.json" -Output "${prefix}_rxclk.json" | Out-Null
        } catch {
            # A measured clock defect is a result, not a malformed-log exception.
            if($_.Exception.Message -ne 'Returned clock was not continuously valid'){throw}
        }
        $result.details.rxclk=Get-Content "${prefix}_rxclk.json" -Raw | ConvertFrom-Json
        $result.error_samples+=$result.details.rxclk.invalid_clock_windows
    }
} elseif(@($records | Where-Object {$_.text -match '^\[PERF\]'}).Count) {
    # Early Stage1 emitted SUMMARY/DECODE but no RENDER terminator. Its complete
    # per-frame PERF stream is the compatible measurement source, as for older builds.
    $frames=@($records | Where-Object {$_.text -match '^\[PERF\]'} | Select-Object -Skip 1 | ForEach-Object {
        $f=Fields $_.text; $f | Add-Member host_ms $_.ms; $f
    })
    if(!$frames.Count){throw 'No complete PERF intervals'}
    for($i=1;$i -lt $frames.Count;++$i){if($frames[$i].n -ne $frames[$i-1].n+1){throw 'PERF frame discontinuity'}}
    foreach($f in $frames){foreach($k in @('n','ok','cycle_us','qr_us','status','err','cam')){if($null -eq $f.PSObject.Properties[$k]){throw "Missing PERF field $k"}}}
    $preview=@($records | Where-Object {$_.text -match '^\[PREVIEW\]'} | Select-Object -Skip 1 | ForEach-Object {Fields $_.text})
    $result.rate_method='device per-frame cycle_us; first boundary interval excluded'
    $result.metric_seconds=($frames | Measure-Object cycle_us -Sum).Sum/1e6
    $result.qr_count=$frames.Count;$result.qr_pass=@($frames | Where-Object ok -eq 1).Count
    $result.qr_per_s=$frames.Count/$result.metric_seconds;$result.qr_average_ms=(Mean $frames 'qr_us')/1000
    $result.frame_stuck_samples=@($frames | Where-Object {($_.status -band 0x200) -ne 0}).Count
    $result.error_samples=@($frames | Where-Object {($_.status -band 0xc08) -ne 0 -or $_.err -ne 0 -or ($_.cam -band 0x1000000) -ne 0 -or ($_.vdma -band 0xff1) -ne 0}).Count
    $result.details=@{cycle_max_us=(Maximum $frames 'cycle_us');qr_max_us=(Maximum $frames 'qr_us');preview_drops=(Maximum $preview 'drops');preview_errors=(Maximum $preview 'errors')}
    if($frames.Count -gt 1) {
        $result.details.host_interval_qr_per_s=1000*($frames.Count-1)/($frames[-1].host_ms-$frames[0].host_ms)
        $result.details.device_host_rate_ratio=$result.qr_per_s/$result.details.host_interval_qr_per_s
        if($result.details.device_host_rate_ratio -lt 0.85 -or $result.details.device_host_rate_ratio -gt 1.15) {
            $result.details.timer_warning='Device cycle units disagree with host arrival cadence; use host-observed rate for cross-version comparison.'
            $result.qr_per_s=$result.details.host_interval_qr_per_s
            $result.rate_method='UART inter-completion cadence; historical device timer scale did not validate'
            $result.qr_average_ms=$null
        }
    }
    if($preview.Count) {
        $periods=@($preview | Where-Object period_us -gt 0)
        if($periods.Count){$result.video_per_s=1e6/(Mean $periods 'period_us')}
        $result.video_metric='CPU preview submissions (not HDMI or sensor fps)'
        $result.preview_work_average_ms=(Mean $preview 'copy_us')/1000
        $result.details.preview_gap_max_us=Maximum $periods 'period_us'
    } else {
        $updates=@($records | Where-Object {$_.text -eq '[PASS] HDMI UI updated'}).Count
        if($updates){$result.video_per_s=$updates/$raw.requested_measurement_seconds;$result.video_metric='UART HDMI update events / host seconds'}
        elseif($raw.profile.id -in @('baseline_o0','sw_o2_first')) {
            $result.video_per_s=$result.qr_per_s
            $result.video_metric='One HDMI submit per QR cycle, inferred from preserved source; not direct scanout'
        }
    }
} else {
    $events=@($records | Where-Object {$_.text -match '^\[QR (PASS|MISS)\]'})
    $result.rate_method='UART decode completion events / fixed host seconds; no device timer instrumentation'
    $result.metric_seconds=$raw.requested_measurement_seconds
    $result.qr_count=$events.Count;$result.qr_pass=@($events | Where-Object {$_.text -match '^\[QR PASS\]'}).Count
    $result.qr_per_s=$events.Count/$raw.requested_measurement_seconds
    $updates=@($records | Where-Object {$_.text -eq '[PASS] HDMI UI updated'}).Count
    $result.video_per_s=$updates/$raw.requested_measurement_seconds;$result.video_metric='UART HDMI update events / host seconds'
    $result.details.note='Unknown/uninstrumented error counters remain null, not zero.'
    if(!$events.Count){$result.outcome='no_progress'}
}
$result.warning_or_failure_lines=@($records | Where-Object {$_.text -match '\[(FAIL|WARN)\]'}).Count
if($raw.outcome -ne 'measured') {
    $result.warning_or_failure_lines=@($raw.samples | Where-Object {$_.ms -ge $raw.program_done_ms -and $_.text -match '\[(FAIL|WARN)\]'}).Count
}
if($raw.outcome -eq 'measured') {
    $progress=@($records | Where-Object {$_.text -match '^\[(SUMMARY|PERF|QR PASS|QR MISS)\]'})
    $result.details.last_progress_age_s=if($progress.Count){($raw.measurement_end_ms-$progress[-1].ms)/1000}else{$raw.requested_measurement_seconds}
    if($result.details.last_progress_age_s -gt 10) {
        $result.details.progress_warning='No QR runtime progress near observation end; active device-window rates do not represent sustained full-run throughput.'
    }
}
if($result.qr_count -gt 0){$result.qr_pass_percent=100*$result.qr_pass/$result.qr_count}
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "${prefix}_summary.json" -Encoding UTF8
[pscustomobject]$result | Select-Object id,outcome,metric_seconds,qr_count,qr_pass,qr_pass_percent,qr_per_s,video_per_s,frame_stuck_samples,error_samples,warning_or_failure_lines | Format-List
