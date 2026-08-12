# Vitis Software

## Environment

- Vitis 2024.2
- Standalone Bare-Metal Application
- Target: Zybo Z7-20 / Zynq-7020

## Verified Baseline

`Qr_barcode_working_ver0_app/` contains the application source used for the
verified board-level runtime baseline.

The corresponding verified hardware handoff is:

`hardware/baseline/qr_test_working_ver0.xsa`

The original development workspace is not stored in this repository.
Generated platform, BSP, build, and IDE files are intentionally excluded.

## Application

Application sources are preserved under:

`Qr_barcode_working_ver0_app/src/`

The software includes:

- OV7670 camera configuration
- Vision Front-End control
- AXI VDMA control
- Result/Image DMA handling
- Runtime CSR control
- QRP1 result handling
- Gray8 image processing
- QR decoding
- HDMI framebuffer output
- UART debug/output

The QR decoder uses the `quirc` library included in the application sources.

## Reusing the Software

1. Open Vitis 2024.2.
2. Create a Platform Component using:

   `hardware/baseline/qr_test_working_ver0.xsa`

3. Create a Standalone domain for the Zynq-7000 PS.
4. Create or import an Application Component.
5. Use the sources under:

   `software/vitis/Qr_barcode_working_ver0_app/src/`

6. Preserve the supplied `UserConfig.cmake`, `CMakeLists.txt`, `app.yaml`,
   linker script, and application configuration files as required.
7. Build the application.
8. Program the FPGA using the matching hardware design.
9. Run the application on the Zynq PS.

## Baseline Policy

This directory preserves the tested software baseline without refactoring.

Generated Vitis workspace files are not treated as source files and are not
stored in Git.

Future cleanup or modularization should be performed in separate commits so
that the verified baseline remains traceable.

## Host Utilities

`tools/` contains host-side scripts used during camera and Gray8 image
bring-up.

Generated image captures and temporary output files are not stored in Git.
