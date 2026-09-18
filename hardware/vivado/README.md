# Vivado source and historical project snapshots

## Current QPP1 reference (2026-09-18)

The current main application uses `qr_frame_pingpong.bit/.xsa` with the
`fallback_fast` ELF. See [current version](../../docs/CURRENT_VERSION.md).
It uses two binary BRAM banks, matched Gray8 ownership, candidate-guided PS
Geometry/ECC and autonomous PL preview. Fixed-scene QR throughput is about
30/s; the 15/s statements below describe earlier milestones.

Use the `qr-v0.11.0` release package for deployment, or
`tools/run_current.tcl` when the local generated artifacts already exist.
The build scripts still depend on external IP/BSP and earlier generated BD
files; these source snapshots are not a turnkey clean-clone rebuild flow.

## Historical notes

## PL-guided PS Geometry/ROI (2026-09-17)

Follow-up measurement: `Docs/QR_PIPELINE_BOTTLENECK_20260917.md` separates the
remaining 15/s limit into capture (~31.34ms), post-frame PL processing (~5.78ms)
and DMA/ACK. The next 33.32ms camera SOF is already missed before results are
ready. Diagnostic PS builds did not change this PL or the selected normal ELF.

`tools/run_candidate_geometry.tcl` runs the validated candidate-guided PS ELF
with the same corrected PL bitstream (no new PL changes). See
`Docs/PL_GUIDED_GEOMETRY_ROI_20260917.md`: current-scene QR call time fell from
59.1ms to 12.0ms, while actual QR throughput remains 15/s and camera input 30fps.
The previous full-frame ELF and the always-refine intermediate ELF are retained.

## Latest candidate-path correction (2026-09-17)

The separate `tools/build_candidate_address_fix.tcl` build starts from the
preserved Stage4 30fps BD and fixes both binary BRAM word-to-byte address
connections. See `Docs/PL_CANDIDATE_ADDRESS_FIX_20260917.md` for simulation,
on-board tests, selected firmware and rollback. The historical designs below
are retained as measured baselines; they do not include this address fix.
Use the new build/runner for candidate-path work, not a historical baseline.

The current PL+PS performance work is documented in
`Docs/HARDWARE_SOFTWARE_PERFORMANCE_20260917.md`. Its reproducible build entry
point is `tools/build_hardware_perf.tcl`; it creates a separate `Vivado/qr_perf`
project. The camera-path repair artifacts described below remain the rollback
baseline and are not overwritten by that build.

## Autonomous preview / 30fps stage 2

`../../tools/build_video30_stage2.tcl` creates the separate
`Vivado/qr_video30_stage2` project from the preserved
`baselines/qr_perf_stage1.bd`, adds the common PL grayscale/bitmap HUD, and
keeps the QR snapshot/Feature/runtime path intact. Its PS application is built
with `-PlPreview -Build Vitis_video30_stage2/build`; do not use the stage2 ELF
with the old bitstream. The matching runner is `tools/run_video30_stage2.tcl`.
See `Docs/VIDEO_30FPS_STAGE2_20260917.md` for measurements and limitations.
Camera input remains about 9.77fps at this stage; repeated scanout frames are
not counted as new camera frames. The original canonical BD is not overwritten.

## Source-synchronous camera / 30fps stage 3

Stage3 source-synchronous camera work is isolated in `Vivado/qr_video30_stage3`.
`tools/build_video30_stage3.tcl` starts from `baselines/qr_video30_stage2.bd` and
replaces only the camera peripheral with CAM3: 24MHz XCLK, PCLK input registers
and an XPM asynchronous FIFO. It explicitly pins the old RGB565-to-RGB888 remap
against IP propagation defaults. PS/DDR clocks, addresses, physical wiring,
autonomous preview, Feature IP and same-frame QR contract remain intact.
Use `tools/run_video30_stage3.tcl` only with the matching firmware built using
`-PlPreview -SourceSyncCamera -CameraClock 129 -CameraDrive 1 -Build Vitis_video30_stage3/build`.
The qualified candidate is ~15fps (12MHz PCLK). CLKRC 128 / 24MHz PCLK
passed a sensor colorbar test but corrupted real video on the current setup;
it is diagnostic only, not an achieved 30fps release.
See `Docs/VIDEO_30FPS_STAGE3_20260917.md` for validation state and limitations.

## Original recovery history

`current_project_snapshot/` contains the supplied `qrcode.xpr` and Block Design files for architecture/reference purposes.

The project files were modified after `qr_test_working_ver0.xsa` was exported. In addition, the original project references external `rtl/`, `ip_repo/`, `xdc/`, `sim/`, and `core/` paths that were not all stored directly under the `.xpr` directory.

For that reason:

- keep `hardware/baseline/qr_test_working_ver0.xsa` only as the original, unmodified handoff; it did not produce a working camera preview in the on-board test;
- use `hardware/rtl/` as the recovered custom source set;
- do not treat the `.xpr` snapshot as a fully relocatable/reproducible project yet.

The original block design put ILA probes directly on individual camera AXI4-Stream interface pins. Vivado treated those scalar probe nets as overrides of the interface connection: the reconstructed generated RTL drove the broadcaster's `s_axis_tvalid`, `s_axis_tuser`, and `s_axis_tlast` with `1'b0`, while the camera FIFO always saw `TREADY=1`. The repaired `qr_ip1_bd.bd` removes that ILA and its scalar probe nets so the camera output connects to the broadcaster through the AXI interface. It also explicitly preserves the RGB565-to-RGB888 converter's `TSTRB_REMAP` setting.

On a Zybo Z7-20 with an OV7670, a Vivado 2024.2 build from the repaired design passed routing/bit generation (WNS +0.272 ns, no failing endpoints). The existing `Qr_barcode_working_ver0_app.elf` then advanced continuously past `RESULT_READY`, updated the HDMI framebuffer, and displayed a live grayscale camera image with `STATUS: SEARCHING`. No QR code was in view for a decode test.

The locally generated, untracked artifacts are `Vivado/qr_probe/qr_probe.runs/impl_1/qr_ip1_bd_wrapper.bit` and `Vivado/qr_probe/qr_camera_fixed.xsa` (which includes the bitstream). They do not replace the original baseline files. Use the matching new XSA for future Vitis platform regeneration. A later cleanup can add a Tcl-based project/IP regeneration flow using the recovered source tree and the Digilent `vivado-library` dependencies.
