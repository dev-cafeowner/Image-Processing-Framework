# SoC-Based General-Purpose Framework for Image Processing

Zybo Z7-20 / Zynq-7020 기반 카메라 영상처리 프레임워크의 **Vivado·Vitis 소스 저장소**입니다. 공통 Camera·Frame·Memory·Control 기반 위에서 전처리와 대상별 Feature IP·PS 처리를 구성합니다. 현재 인식 대상은 QR입니다.

## 저장소 구성

| 경로 | 내용 |
|---|---|
| `hardware/vivado/system.bd` | 현재 시스템 Block Design |
| `hardware/constraints/board.xdc` | 보드 핀·타이밍 제약 |
| `hardware/rtl` | 카메라·전처리·QR Feature·프레임·표시 RTL |
| `hardware/ip_repo` | 사용자 IP 소스·패키징 정의·드라이버 |
| `hardware/tb`, `hardware/vectors` | RTL 테스트벤치·시험 벡터 |
| `software/app/src` | PS 애플리케이션 C/H·링커·CMake 설정 |
| `software/tests` | PS 로직 Host 시험 소스·모의 하드웨어 헤더 |

PC용 실행·업로드·측정 스크립트, PowerShell 파일, bitstream·ELF·XSA, 생성 프로젝트와 측정 자료는 배포하지 않습니다. IP 구성에 필요한 Tcl, CMake, Makefile은 설계·빌드 정의로 유지합니다. GitHub 릴리즈와 태그를 통한 바이너리 배포도 사용하지 않습니다.

## 개발 환경과 구성

- 보드: Zybo Z7-20, `xc7z020clg400-1`
- 카메라: OV7670, VGA 640×480
- 도구: Vivado / Vitis 2024.2
- PS: `ps7_cortexa9_0`, Standalone/bare-metal
- PL: 반환 PCLK 수신·클록 정형, 전처리 Enable/Bypass, Finder 후보·QRP1 패킷, 이중 프레임 버퍼, 자율 HDMI 표시
- PS 경로: 동일 프레임 후보 검증 → 제한된 후보 조합·Geometry/ROI → 영상 기반 Finder 복원·payload/ECC → 필요한 경우 제한된 전체 영상 fallback

Windows와 Linux에서 각각 해당 OS용 AMD 도구를 설치하고 새 프로젝트/BSP를 구성합니다. 생성된 Windows 프로젝트나 PC 실행 파일을 복사하는 방식이 아닙니다. **Linux PC에서의 개발과 보드에서 Linux OS를 실행하는 것은 다릅니다.** 현재 애플리케이션은 보드의 Linux 사용자 프로그램이 아닙니다. Linux 실기기 개발 흐름은 아직 검증하지 않았습니다.

## 프로젝트 구성하기

1. [Vivado 소스 구성](hardware/vivado/README.md)에 따라 RTL·사용자 IP·외부 Digilent IP와 Block Design을 새 프로젝트에 추가합니다.
2. 제약을 적용하고 설계 검증·합성·구현·타이밍 확인 후 bitstream과 XSA를 **사용자 개발 환경에서 생성**합니다.
3. [Vitis 소스 구성](software/README.md)에 따라 그 XSA로 Standalone 플랫폼/BSP와 애플리케이션을 생성합니다.
4. 애플리케이션을 빌드한 후 Vivado/Vitis의 하드웨어 연결·디버그 기능으로 해당 PL/PS 조합을 보드에 로드합니다.

AMD IP와 Digilent IP, BSP는 별도 의존성입니다. 소스 다운로드만으로 보드 실행이 완료되는 패키지는 아닙니다. PL/PS의 레지스터·프레임 형식이 일치하는지 확인해야 합니다.

## 측정된 기준과 한계

2026-09-18 조명 복원 후 고정 장면에서 기존 검증 빌드는 123.950초 동안 3,720/3,720 QR 해독 성공, 약 30.012회/s를 기록했습니다. QR 호출 평균 11.817ms, 관측 최대 12.713ms이며 해당 실행의 capture skip·소유권 오류는 0회였습니다. 기본 빌드 선택값은 `software/app/src/ApplicationConfig.cmake`에 기록했습니다.

이는 그 장면과 당시 빌드의 결과이며, 이름을 정리한 소스를 새로 빌드한 결과에 자동으로 적용되는 인증은 아닙니다. 모든 거리·각도·조명에서의 인식률, 손상 QR의 긴 실패 지연, 직접 HDMI 캡처 기반 누락·tearing·지연, 두 번째 Feature IP의 재사용성 검증이 남아 있습니다. 웹캠으로 모니터를 촬영한 결과를 직접 HDMI 검증으로 간주하지 않습니다.

## Third-party code

`quirc` (Daniel Beer), Digilent display/dynamic-clock helpers, AMD/Xilinx 플랫폼 코드의 원래 저작권·라이선스 헤더를 유지합니다. 별도의 프로젝트 전체 라이선스를 임의로 부여하지 않습니다.
