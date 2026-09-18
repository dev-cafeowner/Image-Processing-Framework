# SoC-Based General-Purpose Framework for Image Processing

Zybo Z7-20 / Zynq-7020 기반 카메라 영상처리 프레임워크입니다. Camera·Frame·Memory·Control 기반을 공통으로 유지하면서, 전처리 Stage와 대상별 Feature IP·PS 처리를 교체하는 구조를 목표로 합니다.

현재 `main`은 **QR 30fps / Fast fallback** 기준 구현입니다. 실행 바이너리는 [qr-v0.11.0 릴리즈](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.11.0)에서 받으세요.

## 현재 검증 상태

- 보드: Zybo Z7-20 (`xc7z020clg400-1`)
- 카메라: OV7670, VGA 640×480
- 도구: Vivado / Vitis 2024.2, Cortex-A9 Standalone
- 고정 장면: 123.950초 동안 3,720/3,720 성공, QR 처리 약 30.012회/s
- QR 호출: 평균 11.817ms, 관측 최대 12.713ms
- 해당 일반 실행의 capture skip·소유권 오류: 0회

이는 **해당 장면에서의 검증 결과**입니다. 모든 거리·각도·조명에서 100% 인식하거나 모든 실패 처리가 33.3ms 내에 끝난다는 보장은 아닙니다. [상세 결과와 한계](docs/CURRENT_VERSION.md), [주요 버전 비교](docs/RELEASES.md)

## 실행하기

1. [최신 릴리즈](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.11.0)의 **Assets → qr-v0.11.0.zip**과 SHA-256 파일을 받습니다. 자동 생성되는 Source code ZIP에는 bit/XSA/ELF가 없습니다.
2. 새 디렉터리에 압축을 풉니다. 기존 작업 소스 위에 덮어쓰지 않습니다.
3. 보드 전원, JTAG USB, OV7670 배선과 HDMI 연결을 확인합니다.
4. 압축을 푼 디렉터리의 PowerShell에서 실행합니다.

```powershell
.\run.ps1 -VerifyOnly
.\run.ps1 -Xsct 'C:/Xilinx/Vitis/2024.2/bin/xsct.bat'
```

`run.ps1`은 파일 해시를 검증한 후 PS를 리셋하고 PL과 ELF를 JTAG/RAM에 올립니다. Flash/SD에는 쓰지 않습니다. PowerShell 실행 정책이 스크립트를 제한한다면 로컬 정책에 맞게 실행하세요. 정책을 자동으로 변경하지 않습니다.

이미 기존 로컬 작업 환경과 검증 산출물이 있는 경우에는 저장소 루트에서 다음 명령을 사용합니다.

```powershell
& 'C:/Xilinx/Vitis/2024.2/bin/xsct.bat' ./tools/run_current.tcl
```

이 명령은 `Vivado/qr_frame_pingpong`의 PL과 `Vitis_video30_stage4/fallback_fast`의 ELF를 선택합니다. 과거 실행 스크립트는 복구를 위해 당시 기본값을 유지합니다.

## 현재 구조

- **Camera / PL 전처리**: PCLK 동기 수신, 비동기 FIFO, Enable/Bypass 가능한 전처리. 현재 장면에서는 global threshold 128을 선택합니다.
- **QR Feature / 결과**: Finder 후보 생성, QRP1 패킷, 프레임 ID·형식·좌표·오류 검증.
- **Frame / Memory**: QPP1 binary BRAM 2 bank와 PS Gray8 소유권 슬롯으로 입력과 처리를 겹칩니다.
- **PS 해독**: 검증 후보 → 제한된 후보 조합·Geometry/ROI → 실제 Finder 복원 → payload/ECC. 필요한 경우 제한된 full-frame fallback을 사용합니다.
- **HDMI**: 자율 VDMA와 PL grayscale/HUD 경로로 PS QR 처리와 표시를 분리합니다.

프로젝트의 첫 번째 인식 대상은 QR입니다. 다른 Feature IP뿐 아니라 그 결과를 처리하는 PS 코드도 함께 개발해야 범용 교체 구조를 검증할 수 있습니다.

## 소스 위치

| 경로 | 내용 |
|---|---|
| `hardware/rtl/camera` | 카메라 클록·PCLK 수신·비동기 전달 |
| `hardware/rtl/frontend` | 가변 전처리 |
| `hardware/rtl/qr_feature` | Finder 후보 추출 |
| `hardware/rtl/bridge` | Gray8 tap·BRAM 주소 변환·QPP1 |
| `hardware/rtl/video` | 자율 표시·HUD·진단 태그 |
| `hardware/rtl/runtime` | 후보 집계·QRP1·CSR |
| `hardware/tb` | RTL 회귀 테스트 |
| `software/vitis/Qr_barcode_working_ver0_app/src` | PS Runtime·Geometry·Decode·DMA |
| `software/tests` | Host 회귀 테스트 |
| `tools` | 빌드·실행·계측·검증 스크립트 |
| `docs` | 현재 버전·릴리즈·공개 성능 집계 |

## 빌드와 회귀 테스트

[현재 빌드 프로파일](docs/CURRENT_VERSION.md#실행과-개발)을 참조하세요. 새 빌드는 검증된 ELF를 덮어쓰지 않는 출력 디렉터리를 사용하고 별도로 검증해야 합니다.

```powershell
./tools/test_candidate_packet.ps1
./tools/test_candidate_geometry.ps1 -EarlyDecode -FastFallback -SeedRadius 8
./tools/test_pingpong_receiver.ps1
./tools/test_frame_pingpong_parser.ps1
./tools/test_gray_ring.ps1
```

위 Host 시험에는 설치된 Xilinx 도구에 포함된 GCC가 필요합니다. 보드에는 접근하지 않습니다. PL 빌드는 외부 Xilinx/Digilent IP와 이전 단계의 생성 BD 등을, PS 빌드는 생성 BSP를 요구합니다. **클린 clone만으로 모든 빌드가 재현되는 단계는 아닙니다.**

## 과거 버전과 산출물

과거 11개 버전은 [릴리즈·태그](docs/RELEASES.md)로 보존합니다. `hardware/baseline/qr_test_working_ver0.xsa`와 이전 프로젝트 스냅샷은 초기 이력이며 현재 QPP1 실행에 사용할 하드웨어가 아닙니다.

Vivado/Vitis 생성 프로젝트, 대형 빌드 산출물, 원시 UART·촬영 자료는 소스 관리에서 제외합니다. 선택한 bit/XSA/ELF는 릴리즈 Assets로 배포하며, 검증 결과는 실제 측정과 합성·주입 진단을 구분합니다.

## 남은 과제

QR 크기·거리·각도·조명 변화 시험, 손상 QR의 긴 실패 지연, 직접 HDMI 프레임·tearing·지연 검증, 두 번째 Feature IP와 대응 PS 처리 개발이 남아 있습니다.

## Third-party code

`quirc` (Daniel Beer), Digilent display/dynamic-clock helpers, AMD/Xilinx 플랫폼 소스의 원래 저작권·라이선스 헤더를 유지합니다. 별도의 프로젝트 전체 라이선스를 임의로 부여하지 않습니다.
