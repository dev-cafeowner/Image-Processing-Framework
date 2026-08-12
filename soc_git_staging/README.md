# SoC-Based General-Purpose Framework for Image Processing

Zybo Z7-20 / Zynq-7020 기반의 카메라 영상처리 SoC 프레임워크입니다. 카메라 입력, 구성 가능한 전처리, 대상별 Feature IP, PL 결과 전달, PS 소프트웨어 처리를 분리하여 영상 인식 대상을 변경할 때 공통 플랫폼을 재사용하는 것을 목표로 합니다.

이 저장소의 첫 기준점은 **UI overlay 수정 전 실제 보드 동작을 확인했던 Vitis Stage 6 runtime**과 그 애플리케이션이 사용한 **동일 XSA hardware export**입니다.

## Verified baseline

- Board: Zybo Z7-20 (`xc7z020clg400-1`)
- Toolchain: Vivado / Vitis 2024.2
- Camera: OV7670
- Verified PS application: `Qr_barcode_working_ver0_app`
- Runtime entry: `stage6_qr_runtime_run()`
- Hardware export: `hardware/baseline/qr_test_working_ver0.xsa`
- XSA SHA-256: `5ae75524e74b10f46c604495ac7cdf64c7b952d2a4cc9c8adab6e5067348f2f7`

The same XSA hash was found in both the Vivado project archive and the Vitis platform used by the verified application.

## Architecture

```text
OV7670
  |
  v
Camera Capture / AXI4-Stream
  |
  +--> Configurable Vision Front-End
  |      Gray -> Gaussian -> Adaptive Threshold -> Closing
  |      (stage enable / bypass)
  |             |
  |             v
  |        Binary Frame BRAM
  |             |
  |             v
  |        Run-Length 1:1:3:1:1
  |             |
  |             v
  |        Vertical Cross-Check
  |             |
  |             v
  |        HIT Event Stream
  |             |
  |             v
  |        Sparse CCL / Object Properties
  |             |
  |             v
  |        QRP1 Result Runtime -> AXI DMA -> PS DDR
  |
  +--> Gray8 DMA path -> PS DDR

PS
  -> Runtime CSR / DMA control
  -> Frame selection / Gray8 processing
  -> QR decode
  -> HDMI / UART output
```

## Repository layout

```text
hardware/
  baseline/       exact verified XSA hardware handoff
  rtl/
    camera/       OV7670 capture and AXI stream wrapper
    frontend/     configurable preprocessing pipeline
    qr_feature/   Run-Length, VCC, BRAM reader/arbiter, event packing
    runtime/      Sparse CCL, properties, QRP1 and runtime CSR
    bridge/       RGB565-to-Gray8 AXI stream tap
  constraints/    board/timing constraints recovered from the project
  vivado/         current project snapshot for reference
  tb/             available simulation testbench sources
  vectors/        available simulation vectors / memory files

software/
  vitis/
    Qr_barcode_working_ver0_app/
      src/        verified Stage 6 application source
    tools/        host-side capture/preview utilities used during bring-up

docs/
  register-map/   PL-PS CSR/register documentation
```

## Baseline software path

`software/vitis/Qr_barcode_working_ver0_app/src/helloworld.c` keeps `main()` small and calls the Stage 6 runtime:

```text
main
 -> init_platform
 -> stage6_qr_runtime_run
```

The Stage 6 application contains camera setup, runtime CSR control, result/image DMA handling, QR decoding, VDMA/HDMI support, and bring-up tests used during board validation.

## Important provenance note

`hardware/baseline/qr_test_working_ver0.xsa` is the exact hardware handoff matched to the Vitis baseline.

The RTL under `hardware/rtl/` was recovered from the custom-IP source snapshots embedded in the supplied Vivado working project. Their timestamps precede the verified XSA export and they represent the source set associated with that project. The supplied Vivado project itself continued to be edited after the baseline XSA was exported, so `hardware/vivado/current_project_snapshot/` is retained as a **reference snapshot**, not claimed as a byte-exact reconstruction of the verified XSA project state.

## Generated files

Vivado/Vitis build products, caches, run directories, IDE metadata, bitstreams outside the baseline XSA, simulation databases, and captured image dumps are intentionally excluded from source control.

## Third-party code

The Vitis baseline contains third-party source used by the verified runtime, including:

- `quirc` QR recognition/decoder source by Daniel Beer; original license/copyright headers are preserved in the files.
- Digilent display controller and dynamic-clock helper sources; original copyright/license headers are preserved.
- AMD/Xilinx platform support source generated/provided by the Vitis environment; original SPDX/copyright headers are preserved.

No project-wide license is assigned by this import. Add one only after the project owners select the intended license and confirm compatibility with bundled third-party components.

## Next cleanup steps

The baseline import intentionally avoids functional refactoring. Follow-up commits can add a reproducible Vivado project-generation flow, package the recovered custom IP sources, reduce the Vitis bring-up/test code, and reorganize the PS runtime without losing this known-working reference point.
