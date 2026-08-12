# Vitis Software

## Environment

- Vitis 2024.2
- Standalone Bare-Metal Application
- Target Board: Zybo Z7-20
- Device: Zynq-7020

## Verified Software Baseline

`Qr_barcode_working_ver0_app/` contains the Vitis application source used
for the board-level verified runtime.

The corresponding hardware handoff is:

`hardware/baseline/qr_test_working_ver0.xsa`

The original Vitis workspace, generated platform, BSP, build, and IDE files
are not included in this repository.

Only the application source and required configuration files are preserved.

## Verified Runtime Path

The board-level runtime was verified with the following processing path:

OV7670 Camera
→ PL Vision Front-End
→ Gray8 Image DMA
→ DDR / PS
→ PS Full-Frame QR Decode
→ UART / HDMI Output

The software configures the camera and PL runtime, receives the Gray8 image
through AXI DMA, performs QR decoding on the PS, and outputs the recognition
result through UART and HDMI.

QR recognition was verified on the Zybo Z7-20 board using actual camera input.

## PL QR Candidate Pipeline

The PL QR candidate detection pipeline was implemented and verified separately.

Run-Length Scan
→ 1:1:3:1:1 Detection
→ Vertical Cross-Check
→ HIT Event Stream
→ Sparse CCL
→ Object Properties
→ Candidate Result

In the current board demonstration runtime, the PL candidate records are
not directly used by the PS QR decoder.

The QRP1 result stream is received and drained, while final QR recognition
is performed using the full-frame Gray8 image on the PS.

Therefore, the repository distinguishes between:

- PL candidate pipeline implementation and verification
- Board-level QR recognition using the PS full-frame decoder

## Application Source

The verified application is stored under:

`software/vitis/Qr_barcode_working_ver0_app/`

Application entry point:

`src/helloworld.c`

Main runtime:

`src/stage6_qr_runtime.c`

The runtime includes:

- OV7670 SCCB configuration
- Vision Front-End control
- Runtime CSR control
- AXI DMA handling
- Gray8 frame transfer
- QR decoding
- HDMI framebuffer output
- UART result output

The QR decoder uses the included `quirc` library.

## Reusing the Software

1. Open Vitis 2024.2.
2. Create a Platform Component using `hardware/baseline/qr_test_working_ver0.xsa`.
3. Create a Standalone domain for the Cortex-A9 processor.
4. Create an Application Component.
5. Add the application sources from `software/vitis/Qr_barcode_working_ver0_app/src/`.
6. Build the application.
7. Program the FPGA using the corresponding hardware design.
8. Run the application on the Zynq PS.

## Repository Policy

This directory preserves the actual tested software baseline.

The verified application source is intentionally preserved without
refactoring so that the repository remains traceable to the board-level
demonstration.

Generated Vitis workspace files, BSP files, IDE metadata, and build
artifacts are not treated as project source and are excluded from Git.

## Host Utilities

`tools/` contains host-side scripts used during camera and Gray8 image
bring-up.

Generated image captures and temporary output files are not stored in Git.
