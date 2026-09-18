# Vitis Software

현재 애플리케이션은 Zybo Z7-20 / Cortex-A9 Standalone / Vitis 2024.2의 QR 30fps + Fast fallback 구현이다. [현재 버전 상세](../../docs/CURRENT_VERSION.md)를 기준으로 사용한다.

## 현재 경로

`Qr_barcode_working_ver0_app/src/helloworld.c` → `stage6_qr_runtime_run()`.

Runtime은 OV7670 SCCB 설정, DMA·프레임 소유권, 동일-frame QRP1 후보 검증, 후보 조합·Geometry/ROI, 실제 영상 기반 payload/ECC 검사, 제한된 fallback, UART/HUD를 담당한다. **현재는 PL 후보를 PS 해독에 사용한다.** 전체 화면 해독만 수행하던 설명은 초기 버전에 해당한다.

## 하드웨어와 실행 프로파일

- 현재 PL: QPP1 `qr_frame_pingpong.bit/.xsa`
- 현재 ELF: `fallback_fast/Qr_barcode_working_ver0_app.elf`
- 선택 프로파일: PL preview, source-sync/clean PCLK, CLKRC128, drive0, frontend4, guided/early decode, ping-pong, seed8, wait100us, route audit, fast fallback.
- 일반 실행에서는 colorbars·blank·stall·후보 부족 주입을 끈다.

[qr-v0.11.0 Assets](https://github.com/dev-cafeowner/Image-Processing-Framework/releases/tag/qr-v0.11.0)의 ZIP을 새 폴더에 풀어 패키지의 `run.ps1`을 사용한다. 로컬 생성 프로젝트가 이미 있는 경우 저장소 루트의 `tools/run_current.tcl`을 사용한다. 초기 `hardware/baseline` XSA는 현재 QPP1 소스의 실행 하드웨어가 아니다.

## 소스와 재빌드

애플리케이션 소스·Host 시험은 Git에 있고, 생성 Vitis workspace/BSP/IDE/build 파일은 제외한다. 빌드에는 설치된 Xilinx 도구와 적합한 Standalone BSP가 필요하다. 현재 빌드 옵션과 별도 출력 디렉터리 예시는 [개발 안내](../../docs/CURRENT_VERSION.md#실행과-개발)에 있다.

`tools/` 하위 캡처 유틸리티와 애플리케이션의 bring-up 시험은 진단용이다. Host 회귀 테스트와 실기기 검증은 구분하며, 소스 업로드만으로 새 ELF가 기존 측정 바이너리와 동일하다고 간주하지 않는다.

과거 실행 파일은 [릴리즈](../../docs/RELEASES.md)에 보존한다. 라이브 카메라 사진과 해독 payload를 포함한 원시 로그는 업로드하지 않는다.
