param(
    [string[]]$Paths = @(
        'Docs/performance/software_baseline_O0_verified_uart.json',
        'Docs/performance/software_O2_stage1_uart.json',
        'Docs/performance/software_final_uart.json'
    ),
    [string]$Output = 'Docs/performance/software_summary.json'
)
$ErrorActionPreference = 'Stop'
function Get-Stats($values) {
    $sorted = @($values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    [pscustomobject]@{
        count=$sorted.Count
        mean=[math]::Round(($sorted | Measure-Object -Average).Average,3)
        median=$sorted[[math]::Floor(($sorted.Count-1)/2)]
        p95=$sorted[[math]::Ceiling($sorted.Count*0.95)-1]
        max=$sorted[-1]
    }
}
$report = foreach ($path in $Paths) {
    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $frames = @(); $preview = @(); $sync = @()
    foreach ($sample in $data.samples) {
        if ($sample.text -notmatch '^\[(PERF|PREVIEW|SYNC)\]') { continue }
        $kind = $Matches[1]
        $row = [ordered]@{host_ms=$sample.ms}
        foreach ($pair in [regex]::Matches($sample.text,'(\w+)=([0-9A-Fa-f]+)')) {
            $key=$pair.Groups[1].Value; $value=$pair.Groups[2].Value
            if ($key -in @('status','err','cam','vdma','fe')) { $row[$key]=[convert]::ToUInt32($value,16) }
            else { $row[$key]=[long]$value }
        }
        if ($kind -eq 'PERF') { $frames += [pscustomobject]$row }
        elseif ($kind -eq 'SYNC') { $sync += [pscustomobject]$row }
        else { $preview += [pscustomobject]$row }
    }
    $steady = @($frames | Where-Object n -ge 3)
    $metrics = [ordered]@{}
    foreach ($key in @('wait_us','qr_us','display_us','pause_us','cpu_hold_us','cycle_us')) {
        $metrics[$key] = Get-Stats @($steady | ForEach-Object { if ($_.PSObject.Properties.Name -contains $key) { $_.$key } })
    }
    $payloads = @($data.samples.text | Where-Object {$_ -match '^\[QR PASS\] '} | ForEach-Object {$_ -replace '^\[QR PASS\] ',''})
    $previewStats = Get-Stats @($preview | Where-Object period_us -gt 0 | ForEach-Object period_us)
    [pscustomobject]@{
        path=$path
        duration_s=$data.duration_s
        all_frames=$frames.Count
        all_pass=@($frames | Where-Object ok -eq 1).Count
        steady_frames=$steady.Count
        steady_pass=@($steady | Where-Object ok -eq 1).Count
        payloads=@($payloads | Sort-Object -Unique)
        metrics=$metrics
        qr_fps=if($metrics.cycle_us){[math]::Round(1000000/$metrics.cycle_us.mean,4)}else{0}
        preview_period_us=$previewStats
        preview_fps=if($previewStats){[math]::Round(1000000/$previewStats.mean,4)}else{0}
        preview_copy_us=Get-Stats @($preview | ForEach-Object copy_us)
        preview_drops=($preview.drops | Measure-Object -Maximum).Maximum
        preview_errors=($preview.errors | Measure-Object -Maximum).Maximum
        frame_stuck_count=@($frames | Where-Object {($_.status -band 0x200) -ne 0}).Count
        other_runtime_errors=@($frames | Where-Object {($_.status -band 0xC08) -ne 0 -or $_.err -ne 0}).Count
        camera_overflow_count=@($frames | Where-Object {($_.cam -band 0x1000000) -ne 0}).Count
        sync_frames=$sync.Count
        frame_id_mismatches=@($sync | Where-Object {$_.id -ne $_.image}).Count
        frontend_metadata=@($sync.fe | Sort-Object -Unique)
        skipped_camera_frames=($sync.skipped | Measure-Object -Sum).Sum
        failures=@($data.samples.text | Where-Object {$_ -match '\[FAIL\]|\[WARN\]'})
    }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding UTF8
$report | Select-Object path,all_frames,all_pass,steady_frames,steady_pass,qr_fps,preview_fps,preview_drops,preview_errors,frame_stuck_count,other_runtime_errors | Format-List
