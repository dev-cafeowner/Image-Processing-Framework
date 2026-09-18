# Vitis source configuration

The application runs on Zybo Z7-20 `ps7_cortexa9_0` with a Standalone domain in Vitis 2024.2. It is not a Windows executable or a Linux userspace program.

## Create a local platform and application

1. Export an implemented XSA from the current `hardware/vivado/system.bd` design.
2. In Vitis, create a platform named `vision_platform` from that XSA. Select processor `ps7_cortexa9_0` and OS `standalone`; build the BSP for this hardware.
3. Create a C application named `vision_app` using the Standalone domain. Import the source tree from `software/app/src`, including `display_ctrl` and `dynclk`, the linker script and CMake configuration. The entry point is `main.c` → `vision_runtime_run()`; do not retain a second template `main()`.
4. Build using that platform's generated toolchain, headers and libraries. The provided CMake project requires the AMD BSP `common` module and the `xilstandalone`, `xiltimer`, `xil` libraries. Keep Cortex-A9 hard-float ABI consistent with the BSP.
5. Configure the Vitis hardware debug launch with the matching PL, PS initialization and newly built application. No deployment launcher or executable is distributed here.

`PlatformConfig.cmake` records the current memory/UART description and `lscript.ld` the link layout. Check them against the regenerated platform: DDR at `0x00100000`, length `0x3FF00000`, UART `ps7_uart_1` at `0xE0001000`. Regenerate platform metadata if hardware changes.

## Default configuration

`ApplicationConfig.cmake` seeds the current normal-run selection before `UserConfig.cmake` processes options. Use a fresh build directory to avoid cached experimental values. User-specified cache values remain overridable.

| Setting | Selection |
|---|---|
| Optimization | `-O2`; NEON for `video_pixel_ops.c` only |
| Capture/display | PL preview, source-sync capture, conditioned PCLK |
| Camera CLKRC / drive | `128` / `0` |
| Frontend mode | `4` (global threshold) |
| Candidate decode | PL-guided Geometry/ROI, early ECC, minimum seed radius `8` |
| Fallback | Early ECC before iterative refinement; existing bounded retry policy |
| Frame ownership | Two-bank hardware buffer and independent Gray8 receive slots |
| Wait polling | `100` microseconds |
| Logging | Rate-limited route audit; per-frame diagnostics disabled |
| Test injections | Colorbars, blank frames, stalls and candidate removal disabled |

The register layout and packet ABI must agree with the PL. The default profile is the measured configuration, not proof that a fresh build has already passed board testing. The sources and build definitions are host-independent in intent; the complete Linux build/deployment workflow has not been tested.

Use a newly generated platform after IP/cell naming changes: `qr_hw_config.h` expects `XPAR_QR_RUNTIME_0_BASEADDR` from the `qr_runtime_0` cell. Do not reuse an older BSP or CMake cache. `QR_FRAME_RECEIVER` selects buffered reception; `QR_CAMERA_CONDITIONED_PCLK` selects the returned-clock conditioner. These replace profile-dependent configuration names, without changing register addresses or packet signatures.

## Source tests

`software/tests` contains C tests and mock hardware headers for packet checks, candidate geometry, frame ownership, camera settings and preview helpers. These are test **sources**, not deployable board applications. Local PC test/build/measurement launchers and raw captures are excluded.
