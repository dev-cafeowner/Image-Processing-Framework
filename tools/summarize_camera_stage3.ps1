param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Output,
    [switch]$SkipFirstWindow
)
$ErrorActionPreference='Stop'
$capture=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$rows=@($capture.samples | Where-Object {$_.text -match '^\[CAM3\]'} | ForEach-Object {
    $row=[ordered]@{}
    foreach($m in [regex]::Matches($_.text,'(\w+)=([0-9a-fA-F]+)')) {
        $key=$m.Groups[1].Value; $value=$m.Groups[2].Value
        $row[$key]=if($key -eq 'status') {[Convert]::ToUInt32($value,16)} else {[long]$value}
    }
    [pscustomobject]$row
})
if($SkipFirstWindow) {$rows=@($rows | Select-Object -Skip 1)}
if(!$rows.Count) {throw 'No CAM3 windows'}
$lastRow=$null
foreach($row in $rows) {
    foreach($key in @('window_us','pclk_edges','sensor_frames','pixels','total_frames','lost_tokens','bad_lines','fifo_peak','status','period_cycles','max_period_cycles','clock')) {
        if($null -eq $row.PSObject.Properties[$key]) {throw "Incomplete CAM3 window: $key"}
    }
    if($row.window_us -le 0) {throw 'Invalid elapsed time'}
    if($null -ne $lastRow -and $row.total_frames -ne $lastRow.total_frames+$row.sensor_frames) {throw 'CAM3 counter discontinuity'}
    $lastRow=$row
}
$seconds=($rows | Measure-Object window_us -Sum).Sum/1e6
$result=[ordered]@{
    source=$Path; windows=$rows.Count; excluded_initial_windows=[int]$SkipFirstWindow.IsPresent
    device_seconds=$seconds
    pclk_hz=(($rows | Measure-Object pclk_edges -Sum).Sum/$seconds)
    sensor_fps=(($rows | Measure-Object sensor_frames -Sum).Sum/$seconds)
    pixels_per_second=(($rows | Measure-Object pixels -Sum).Sum/$seconds)
    last_frame_period_us=($rows[-1].period_cycles/62.5)
    max_frame_period_us=(($rows | Measure-Object max_period_cycles -Maximum).Maximum/62.5)
    lost_tokens_max=($rows | Measure-Object lost_tokens -Maximum).Maximum
    bad_lines_max=($rows | Measure-Object bad_lines -Maximum).Maximum
    bad_lines_increase=($rows[-1].bad_lines-$rows[0].bad_lines)
    fifo_peak=($rows | Measure-Object fifo_peak -Maximum).Maximum
    invalid_status_windows=@($rows | Where-Object {($_.status -band 0x01000000) -ne 0 -or ($_.status -band 0xfff) -ne 640 -or (($_.status -shr 12) -band 0xfff) -ne 480 -or $_.clock -ne 1}).Count
    note='PCLK edge counter crosses via Gray CDC. Sensor SOF and pixels count all parsed input, including capture-disabled frames. Sequential MMIO reads have small skew; no claim of unique HDMI frame cadence.'
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding UTF8
[pscustomobject]$result | Format-List
