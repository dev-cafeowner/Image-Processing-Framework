param([string]$Directory='Docs/performance/version_matrix_20260917_1333', [string]$Report='Docs/VERSION_COMPARISON_20260917.md')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$catalog=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'version_benchmark_profiles.psd1')
$retestDirectory="$Directory/final_retests"
$rows=@(foreach($p in $catalog.profiles) {
    $path=Join-Path $root "$Directory/$($p.id)_summary.json"
    $retest=Join-Path $root "$retestDirectory/$($p.id)_summary.json"
    if($p.id -in @('stage1_legacy','stage4') -and (Test-Path -LiteralPath $retest)) {$path=$retest}
    elseif($p.id -eq 'stage1_legacy') {continue} # User confirmed camera/board movement; do not rank this run.
    if(Test-Path -LiteralPath $path){Get-Content -LiteralPath $path -Raw | ConvertFrom-Json}
})
function Number($v,[int]$Decimals=3) {if($null -eq $v){return '—'};return ([double]$v).ToString("F$Decimals",[Globalization.CultureInfo]::InvariantCulture)}
$lines=New-Object 'System.Collections.Generic.List[string]'
$lines.Add('# 현재 고정 장면 — 전체 보존 버전 성능 비교')
$lines.Add('')
$lines.Add("기록 갱신: $((Get-Date).ToString('o')). $($rows.Count)/$($catalog.profiles.Count) 실행 결과 확보. 시작/종료 Stage4 기준 반복을 포함한다.")
$lines.Add('')
$lines.Add('## 조건과 해석')
$lines.Add('')
$lines.Add('- 사용자가 지정한 현재 카메라·QR 위치/크기/각도·조명 조건을 유지하도록 요청했다. 자동화는 물리적 셋팅을 바꾸지 않았다. 거리(cm), 조도(lux), 신호 파형은 계측하지 않았다.')
$lines.Add('- 보존된 bit/ELF를 재빌드/튜닝하지 않고 사용한다. 매번 FPGA/PS를 재시작하고, XSCT 완료 후 15초를 기다린 다음 120초 관찰한다. 실패한 실행은 시작 실패로 구분하며 정상 성능 평균에서 제외한다.')
$lines.Add('- 내부 계측이 있는 버전은 관찰 구간 안의 완전한 창/프레임으로만 통계를 낸다. 경계 창을 제외하므로 유효 시간은 120초보다 짧다. 원본은 UART 완료 이벤트/120초이며 QR 함수 시간과 계측되지 않은 오류는 미확인(—)이다.')
$lines.Add('- 영상 열은 구버전에서는 CPU 표시 제출/갱신, Stage2 이후에는 PL 수락 camera SOF다. HDMI 링크 주사율, 반복 포함 scanout, USB 웹캠 fps가 아니다. 다른 측정점을 하나의 정확한 end-to-end fps로 간주하지 않는다.')
$lines.Add('- 순차 실행이므로 동일 픽셀 입력의 순수 알고리즘 벤치마크가 아니다. 버전별 센서 설정/노출·로그 부하도 결과에 포함된다. 시간에 따른 환경 변화 가능성을 보기 위해 최신 버전을 양 끝에서 측정한다.')
$lines.Add('- 인식률은 분석한 QR 프레임 중 PASS 비율이다. 입력된 모든 센서 프레임을 해독한 비율이 아니다. 현재 장면의 결과를 모든 거리/각도/조명에서의 성공률로 일반화하지 않는다.')
$lines.Add('- QR 회/s는 성공과 실패를 합한 분석 처리량이다. 성공한 해독/s는 QR 회/s × 성공률이다. 같은 QR의 반복 해독이며 서로 다른 QR 개수/s가 아니다.')
$lines.Add('- FRAME_STUCK 관측 횟수는 다른 오류와 분리한다. 오류 표본은 고유한 장애 발생 횟수가 아니라 누적/sticky 상태의 관측 합일 수 있다. 빈 칸은 0이 아니라 미계측이다.')
$lines.Add('- Stage1 초기 중간 버전의 최초 실행(523/585)은 사용자가 보드·카메라 이동을 확인했으므로 통제조건 비교에서 제외한다. 원시 로그는 보존하며 final_retests 재측정만 결산에 사용한다. 재측정 뒤 Stage4 종료 기준도 다시 측정한다.')
$lines.Add('')
if($rows.Count -eq $catalog.profiles.Count -and (Test-Path -LiteralPath (Join-Path $root "$retestDirectory/stage4_summary.json"))) {
    $end=@($rows | Where-Object id -eq 'stage4')[0]
    $start=@($rows | Where-Object id -eq 'stage4_start')[0]
    $legacy=@($rows | Where-Object id -eq 'stage1_legacy')[0]
    $stage3fast=@($rows | Where-Object id -eq 'stage3_1x30')[0]
    $scalar=@($rows | Where-Object id -eq 'stage1_legacy_verified')[0]
    $variants=@($rows | Where-Object group -ne 'reference')
    $normal=@($variants | Where-Object outcome -eq 'measured').Count
    $failed=@($variants | Where-Object outcome -ne 'measured').Count
    $lines.Add('## 결론');$lines.Add('')
    $lines.Add("- 중간 설정을 포함한 $($variants.Count)개 구성 중 $normal 개는 120초 관찰을 완료했고, $failed 개는 초기화/입력 검사 또는 DMA 오류로 중단됐다. 시작 기준 반복은 별도이며, 이동이 있었던 실행은 성공률 결산에서 제외했다.")
    $lines.Add("- Stage1 초기 중간 버전 재측정: $($legacy.qr_pass)/$($legacy.qr_count), $(Number $legacy.qr_pass_percent 2)%, QR $(Number $legacy.qr_per_s)회/s, 영상 제출 $(Number $legacy.video_per_s)회/s. 최초 이동 실행의 89.4%를 버전 고유 성능으로 해석하지 않는다.")
    $lines.Add("- 선택 Stage4 종료 기준: $($end.qr_pass)/$($end.qr_count), 입력/PL $(Number $end.video_per_s)fps, QR 분석 $(Number $end.qr_per_s)회/s, QR 평균 $(Number $end.qr_average_ms)ms. 계측된 오류 표본=$($end.error_samples). 영상 입력 30fps와 QR 해독 30회/s는 서로 다른 목표이며 후자는 달성하지 않았다.")
    $lines.Add("- Stage4 시작/종료 비교: 영상 $(Number $start.video_per_s) → $(Number $end.video_per_s), QR $(Number $start.qr_per_s) → $(Number $end.qr_per_s), 성공률 $(Number $start.qr_pass_percent 2)% → $(Number $end.qr_pass_percent 2)%. QR 평균 시간은 $(Number $start.qr_average_ms) → $(Number $end.qr_average_ms)ms. 처리량은 같은 수준이지만 완전히 동일한 영상/노출 조건이었다는 증명은 아니다.")
    $lines.Add('- Stage1은 CPU 복사 비용을 낮췄으나 현재 입력 조건에서 전체 처리량은 PL+PS 안정본과 거의 같다. Stage2는 표시 경로를 PL로 분리했지만 입력 속도 자체는 증가하지 않았다. Stage3 15fps와 Stage4 30fps에서 입력 증가가 QR 분석 처리량 증가로 이어졌다.')
    $lines.Add("- Stage3 1x·30fps 실험도 이번에는 $($stage3fast.qr_pass)/$($stage3fast.qr_count) 성공 및 약 $(Number $stage3fast.video_per_s)fps를 보였다. 이번 한 번의 결과로 Stage4와의 장기 안정성 우열이나 과거 실패 원인을 확정하지 않는다. Stage3/4의 2x·3x 및 약한 XCLK 실험 실패는 표와 원시 로그에 그대로 남긴다.")
    $lines.Add("- Stage1 검증용 scalar 대조본의 $($scalar.qr_pass)/$($scalar.qr_count)($(Number $scalar.qr_pass_percent 2)%)은 초기 중간 버전과 별개 실행이다. 이 실행까지 이동했다고 확인된 것은 아니므로 임의로 제외하거나 100%로 바꾸지 않았다.")
    $lines.Add('- 이번 작업은 측정 도구/보고서만 추가·보완했으며 제품 RTL/PS 코드를 변경하거나 새로 빌드하지 않았다.')
    if($end.outcome -eq 'measured' -and $end.error_samples -eq 0 -and $end.qr_pass -gt 0 -and !$end.details.progress_warning) {
        $lines.Add('- 마지막으로 측정한 선택 Stage4 30fps 부팅 상태를 유지한다.')
    } else {$lines.Add('- 마지막 Stage4 실행 상태는 추가 확인이 필요하다. 복구 출력과 원시 로그를 확인한다.')}
    $lines.Add('')
}
foreach($group in @('main','intermediate','reference')) {
    $title=@{main='주요 버전';intermediate='중간 최적화·고속 실험';reference='시작 기준 반복'}[$group]
    $lines.Add("## $title");$lines.Add('')
    $lines.Add('| 버전 | 결과 | 유효초 | QR 성공/분석 | 성공률 % | QR 회/s | 영상 갱신/s | QR 평균 ms | STUCK 표본 | 기타 오류 표본 |')
    $lines.Add('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |')
    foreach($p in @($catalog.profiles | Where-Object group -eq $group)) {
        $r=@($rows | Where-Object id -eq $p.id)
        if(!$r.Count){$state=if($p.id -eq 'stage1_legacy'){'위치 이동 실행 제외 / 재측정 대기'}else{'아직 미측정'};$lines.Add("| $($p.label) | $state | — | — | — | — | — | — | — | — |");continue}
        $r=$r[0]
        $count=if($null -eq $r.qr_count){'—'}else{"$($r.qr_pass)/$($r.qr_count)"}
        $lines.Add("| $($r.label) | $($r.outcome) | $(Number $r.metric_seconds) | $count | $(Number $r.qr_pass_percent 2) | $(Number $r.qr_per_s) | $(Number $r.video_per_s) | $(Number $r.qr_average_ms) | $(Number $r.frame_stuck_samples 0) | $(Number $r.error_samples 0) |")
    }
    $lines.Add('')
}
$lines.Add('## 실행별 측정 정의와 실패 근거');$lines.Add('')
foreach($r in $rows) {
    $lines.Add("- $($r.id): $($r.rate_method); 영상=$($r.video_metric); WARN/FAIL 줄=$($r.warning_or_failure_lines).")
    if($r.details.failure){$lines.Add("  - 실패: $($r.details.failure -replace '\r?\n',' ')")}
    if($r.details.progress_warning){$lines.Add("  - 주의: $($r.details.progress_warning)")}
    foreach($e in $r.details.failure_context){$lines.Add("  - 시작 후 $(Number ($e.ms/1000))s: $($e.text)")}
    $drops=if($null -ne $r.details.qr){$r.details.qr.preview_copy_drops}else{$r.details.preview_drops}
    if($drops -gt 0){$lines.Add("  - CPU 미리보기 복사 취소 누적값=$drops. 해당 부팅 이후 누적값으로, 120초 구간 내 발생 횟수나 QR 실패 횟수가 아니다.")}
}
$cameraRows=@($rows | Where-Object {$null -ne $_.details.camera})
if($cameraRows.Count) {
    $lines.Add('');$lines.Add('## 카메라 입력 무결성 계측');$lines.Add('')
    $lines.Add('| 버전 | 센서 fps | 최대 프레임 간격 ms | 손실 토큰 누적 | 비정상 라인 누적 | 비정상 상태 창 | RXCLK 손실 누적 |')
    $lines.Add('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    foreach($r in $cameraRows) {
        $c=$r.details.camera;$clockLoss=$r.details.rxclk.lock_losses_max
        $lines.Add("| $($r.id) | $(Number $c.sensor_fps) | $(Number ($c.max_frame_period_us/1000)) | $(Number $c.lost_tokens_max 0) | $(Number $c.bad_lines_max 0) | $(Number $c.invalid_status_windows 0) | $(Number $clockLoss 0) |")
    }
    $lines.Add('');$lines.Add('누적 최대 간격/오류는 부팅 이후 값이다. RXCLK가 없는 버전의 빈 칸은 손실 0을 뜻하지 않는다. 디지털 계측만으로 아날로그 신호 품질이나 화면의 화질을 보증하지 않는다.')
}
$lines.Add('');$lines.Add('## 증거와 제외 범위');$lines.Add('')
$lines.Add('- 원본 로그/설정/bit·ELF·XSA·runner SHA256: `'+$Directory+'/*_raw.json` (JSON 파일 내 measurement_start_ms/end_ms가 관찰 경계).')
$lines.Add('- 이동 실행 제외 사유: 같은 폴더의 run_annotations.json. Stage1 재측정/최종 Stage4 기준: final_retests 하위 폴더. 이전 Stage4 종료 측정도 삭제하지 않고 보조 기록으로 보존한다. 무결성·관찰 경계 최종 확인은 audit.json에 기록한다.')
$lines.Add("- 실행 출력: $Directory/*_program_stdout.log 및 *_program_stderr.log. 내부 timer SUMMARY/CAM3/VIDEO 검증 결과도 같은 폴더에 저장한다.")
$lines.Add('- 컬러바/흰 영상 주입은 QR 장면을 바꾸는 진단이므로 제외했다. FSBL은 부팅 구성요소다. legacy_compile 및 stage4_compat15는 컴파일 회귀용 산출물이며 별도 성능 버전으로 세지 않았다. 잘못된 RGB passthrough 배선의 미검증 bit도 배포하지 않았다.')
$lines.Add('- 기존 배포물/소스/릴리스 ZIP은 수정하지 않는다. 비교 종료 또는 스크립트 오류 시 Stage4 선택 30fps 버전으로 복구한다. QSPI/SD 플래시는 변경하지 않는다.')
$lines | Set-Content -LiteralPath (Join-Path $root $Report) -Encoding UTF8
[ordered]@{updated=(Get-Date).ToString('o');completed=$rows.Count;planned=$catalog.profiles.Count;rows=$rows} | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $root "$Directory/comparison.json") -Encoding UTF8
Write-Output "$($rows.Count)/$($catalog.profiles.Count) result rows; $Report"
