param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Output,
    [switch]$SkipFirstWindow
)
$ErrorActionPreference = 'Stop'
$capture = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$rows = @($capture.samples | Where-Object {$_.text -match '^\[VIDEO\]'} | ForEach-Object {
    $item = [ordered]@{}
    foreach ($m in [regex]::Matches($_.text, '(\w+)=([0-9a-fA-F]+)')) {
        $item[$m.Groups[1].Value] = if ($m.Groups[1].Value -eq 'mm2s_err') {
            [Convert]::ToUInt32($m.Groups[2].Value,16)
        } else { [long]$m.Groups[2].Value }
    }
    [pscustomobject]$item
})
if (!$rows.Count) { throw 'No VIDEO windows' }
foreach ($row in $rows) {
    foreach ($key in @('window_us','camera_sof','scan_sof','total_camera','total_scan','camera_gap_max_us','scan_gap_max_us','geometry_errors','rejected','mm2s_err','hud','hud_avg_us','hud_max_us')) {
        if ($null -eq $row.PSObject.Properties[$key]) { throw "Incomplete VIDEO: $key" }
    }
    if ($row.window_us -le 0) { throw 'Invalid video interval' }
}
for ($i=1; $i -lt $rows.Count; ++$i) {
    if ($rows[$i].total_camera -ne $rows[$i-1].total_camera + $rows[$i].camera_sof -or
        $rows[$i].total_scan -ne $rows[$i-1].total_scan + $rows[$i].scan_sof) {
        throw 'VIDEO counter gap or restart: split captures before analysis'
    }
}
if ($SkipFirstWindow) {
    if ($rows.Count -lt 2) {throw 'Cannot exclude the only video window'}
    $rows = @($rows | Select-Object -Skip 1)
}
$seconds = ($rows | Measure-Object window_us -Sum).Sum / 1e6
$camera = ($rows | Measure-Object camera_sof -Sum).Sum
$scan = ($rows | Measure-Object scan_sof -Sum).Sum
$hud = ($rows | Measure-Object hud -Sum).Sum
$hudUs = 0.0
$hudCpuUs = 0.0
$hasCpu = @($rows | Where-Object {$null -eq $_.PSObject.Properties['hud_cpu_avg_us']}).Count -eq 0
foreach ($row in $rows) {
    $hudUs += $row.hud * $row.hud_avg_us
    if ($hasCpu) { $hudCpuUs += $row.hud * $row.hud_cpu_avg_us }
}
$result = [ordered]@{
    source=$Path; windows=$rows.Count; excluded_initial_windows=[int]$SkipFirstWindow.IsPresent
    device_window_seconds=$seconds; counters_contiguous=$true
    accepted_camera_sof=$camera; accepted_camera_sof_per_second=($camera/$seconds)
    scan_sof_including_repeats=$scan; scan_sof_including_repeats_per_second=($scan/$seconds)
    camera_gap_max_us=($rows | Measure-Object camera_gap_max_us -Maximum).Maximum
    scan_gap_max_us=($rows | Measure-Object scan_gap_max_us -Maximum).Maximum
    error_windows=@($rows | Where-Object {$_.geometry_errors -ne 0 -or $_.rejected -ne 0 -or $_.mm2s_err -ne 0}).Count
    hud_updates=$hud; hud_pack_and_write_average_us=$(if ($hud) {$hudUs/$hud} else {$null})
    hud_pack_and_write_max_us=($rows | Measure-Object hud_max_us -Maximum).Maximum
    hud_full_cpu_average_us=$(if ($hasCpu -and $hud) {$hudCpuUs/$hud} else {$null})
    hud_full_cpu_max_us=$(if ($hasCpu) {($rows | Measure-Object hud_cpu_max_us -Maximum).Maximum} else {$null})
    note='PL AXIS counters, not HDMI pin measurements. scan_sof includes repeated camera frames. Max gaps are cumulative since PL reset. hud_pack_and_write excludes text rasterization; hud_full_cpu includes it. No claim of unique 30fps video.'
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
