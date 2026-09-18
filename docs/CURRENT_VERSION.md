# 현재 기준 버전: QR 30fps / Fast fallback

`main`의 기준 기능은 [qr-v0.11.0](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.11.0)이다. Zybo Z7-20, OV7670 VGA 640×480, Vivado/Vitis 2024.2 환경에서 검증했다.

## 구조와 역할

- 공통 입력: 24MHz XCLK, 반환 PCLK 기반 동기 수신 및 비동기 FIFO.
- PL: Enable/Bypass 전처리, Finder 후보 생성, QRP1 결과, 이중 binary BRAM bank와 프레임 소유권 관리.
- PS: 동일-frame 후보 검증 → 제한된 후보 조합·Geometry/ROI → 실제 영상 Finder 복원·payload/ECC 검사.
- Fallback: 초기 grid의 실제 ECC를 먼저 검사하고 필요 시 원근 보정을 재시도한다. 연속 guided 실패 시 기존 1/6 실행 제한을 유지한다.
- 표시: 4-buffer VDMA와 PL grayscale/HUD를 사용해 PS 해독 작업과 독립적으로 갱신한다.

현재 선택 전처리는 해당 장면에 맞춘 global threshold 128이다. 자동 전처리 선택이나 모든 조명에서의 최적 설정을 의미하지 않는다.

## 검증 결과

2026-09-18 조명 복원 후 고정 장면의 일반 실행:

| 항목 | 결과 |
|---|---:|
| 유효 측정 시간 | 123.950202초 |
| QR 성공/분석 | 3,720 / 3,720 |
| QR 처리율 | 30.012/s |
| QR 호출 평균 / 관측 최대 | 11.817ms / 12.713ms |
| Capture skip / 소유권 오류 | 0 / 0 |
| 자연 fallback | 0회 |

매 60개 처리 프레임 중 하나의 후보 수를 줄인 별도 실제 영상 A/B에서는 fallback 평균이 59.853ms → 17.085ms, capture skip delta가 60 → 0이었다. 이 진단은 일반 실행의 인식률과 구분한다. [공개 집계 파일](validation/qr-v0.11.0/)

모니터를 촬영한 웹캠의 광학 태그 결과는 판독 가능한 구간에서 약 30fps 입력 / 59.53Hz scan과 부합했다. 직접 HDMI 캡처가 아니고 미판독 구간이 있어 전체 구간의 무누락·무tearing을 보증하지 않는다.

## 정확한 실행 산출물

| 파일 | SHA-256 |
|---|---|
| QPP1 bit | `EEDCEC9813397BCFEFB89642B0CFFFC3EDA4B7751EE5310EA1E6BB006051D33B` |
| QPP1 XSA | `F8CD0CF1F19EF083B7F2D7CE66E4E5D659D92B61F1A67A1FE35949A1B3CB02B3` |
| fallback_fast ELF | `1285E85EA12BB1B9A366E699ADD97ADD9ED13FA942853573E7A85AEA62589C2F` |
| 릴리즈 ZIP | `8EADB37F5CBD709A01CE6560F63C1E1A6CD87959E96C40825D3FD7EB56DD4CA1` |

GitHub Assets의 `qr-v0.11.0.zip`에 이 파일들이 있다. 기존 측정 바이너리를 보존한 것이며, `main` 업로드를 위해 새로 빌드하거나 보드를 재실행한 것은 아니다. 릴리즈 태그와 에셋은 그대로 유지한다.

## 실행과 개발

권장 실행 방법은 [README](../README.md)의 릴리즈 패키지 절차다. 이미 로컬 작업 환경과 산출물이 있는 경우에만 다음을 사용한다.

```powershell
& 'C:/Xilinx/Vitis/2024.2/bin/xsct.bat' ./tools/run_current.tcl
```

이 명령은 보드 PS를 리셋하고 PL·ELF를 JTAG/RAM에 올린다. Flash/SD에는 쓰지 않는다. `run_frame_pingpong.tcl`의 역사적 기본값은 seed8이므로 최신 실행에는 `run_current.tcl`을 사용한다.

현재 기능을 별도 출력 디렉터리에 빌드할 때의 PS 프로파일:

```powershell
./tools/build_software_perf.ps1 -Build Vitis_video30_stage4/current_rebuild -PlPreview -SourceSyncCamera -CleanPclk -CameraClock 128 -CameraDrive 0 -FrontendMode 4 -PlGuided -GuidedEarlyDecode -PingPong -GuidedSeedRadius 8 -WaitPollUs 100 -RouteAudit -FastFallback
```

외부 Xilinx/Digilent IP, 생성 BSP와 기존 BD 등은 추가로 필요하다. 특히 PL 생성 스크립트는 이전 단계의 생성 프로젝트를 참조하므로 클린 clone만으로 원클릭 재빌드된다는 뜻이 아니다. 새 빌드는 위 보존 ELF와 별도로 검증해야 한다. 흰 영상·후보 부족·stall 주입 플래그는 일반 빌드에서 끈다.

## 남은 검증

- QR 크기·거리·각도·조명 변화와 장시간 동작.
- 손상 QR에서 약 52ms에 이르는 긴 실패 경로의 시간 예산.
- 직접 HDMI 프레임·tearing·종단 지연 측정.
- QR 이외 Feature IP 및 대응 PS 처리로 공통 기반의 재사용성 검증.

고정 장면의 30fps QR 기준 구현은 확보했지만, 모든 물리 조건이나 다른 인식 대상까지 검증이 끝난 것은 아니다.
