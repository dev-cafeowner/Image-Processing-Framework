# Vivado source configuration

Use Vivado 2024.2 and part `xc7z020clg400-1`. Create a new RTL project named `system` outside the tracked source directories. Do not import historical generated projects.

## IP repositories

Add these directories in Project Settings → IP → Repository:

- `hardware/ip_repo/custom`
- `hardware/ip_repo/runtime`
- `<digilent-vivado-library>/ip`
- `<digilent-vivado-library>/if`

The external [Digilent vivado-library](https://github.com/Digilent/vivado-library/tree/f4613fff005b098065fd5d619a2b88e55720a423) dependency used locally is commit `f4613fff005b098065fd5d619a2b88e55720a423`. The design requires `axi_dynclk:1.2` and `rgb2dvi:1.4`. AMD catalog IP is supplied by Vivado. Keep IP versions fixed unless deliberately migrating and revalidating.

## RTL and Block Design

Before opening `system.bd`, add these module-reference source files:

- `hardware/rtl/bridge/qr_rgb565_gray8_axis_tap.v`
- `hardware/rtl/bridge/qr_binary_bram_address_adapter.v`
- `hardware/rtl/bridge/frame_buffer_address.v`
- `hardware/rtl/bridge/frame_buffer_controller.v`
- `hardware/rtl/video/video_preview_overlay.v`
- `hardware/rtl/camera/ov7670_camera_clock.v`
- `hardware/rtl/camera/ov7670_pclk_rx.v`
- `hardware/rtl/camera/ov7670_camera_interface.v`
- `hardware/rtl/camera/ov7670_pclk_conditioner.v`

Enable the XPM CDC, FIFO and MEMORY libraries in the project. Other design RTL is resolved through packaged user IP. Do not add duplicate copies from both `hardware/rtl` and the IP packages indiscriminately.

Add/copy `hardware/vivado/system.bd` into the project, refresh module references if requested, validate the design, generate output products, and create a Vivado-managed HDL wrapper. Select `system_wrapper` as top.

Add `hardware/constraints/board.xdc` for synthesis and implementation with processing order **LATE**. DDR/FIXED_IO are configured in the Processing System IP. Check camera pin wiring against the XDC before connecting hardware.

## Hardware contract and checks

- PS control clock: 62.5 MHz; camera XCLK: 24 MHz.
- Frame buffer controller: `0x43C40000`, identity `0x51505031`, ABI `0x00010000`, dimensions `0x01E00280`.
- Preview control: `0x43C30000`, identity `0x50525631`.
- Camera identity at `0x40010010`: `0x43414D33`.
- Binary BRAM: 19,200 words, two frame banks. Preserve byte/word address conversion and same-frame ownership.

After implementation inspect setup/hold timing, CDC, bus skew and camera input-register IOB placement before deployment. Export the implemented hardware with bitstream as a new local XSA for Vitis. Generated bitstream/XSA and hardware-upload scripts are intentionally excluded.

`hardware/tb` provides simulation sources. Board timing qualification and simulation/BD validation are different checks; renaming a design does not qualify a newly implemented bitstream.
