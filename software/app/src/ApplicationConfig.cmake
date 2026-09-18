# Default application configuration for hardware/vivado/system.bd.
# Cache values remain overridable; use a fresh build directory when importing.
# Board-measured settings, not a claim that a new build is already qualified.
set(QR_OPTIMIZATION "-O2" CACHE STRING "Application optimization")
set(QR_CAMERA_CLKRC "128" CACHE STRING "OV7670 clock register")
set(QR_CAMERA_DRIVE "0" CACHE STRING "OV7670 COM2 drive strength")
set(QR_FRONTEND_MODE "4" CACHE STRING "Global-threshold frontend")
set(QR_GUIDED_SEED_RADIUS_MIN "8" CACHE STRING "Minimum finder seed tolerance")
set(QR_WAIT_POLL_US "100" CACHE STRING "Hardware polling interval")
foreach(flag QR_PREVIEW_FUSED QR_PREVIEW_NEON QR_PL_PREVIEW
             QR_CAMERA_SOURCE_SYNC QR_CAMERA_CLEAN_PCLK QR_PL_GUIDED
             QR_GUIDED_EARLY_DECODE QR_FALLBACK_EARLY_DECODE QR_ROUTE_AUDIT
             QR_PINGPONG)
    set(${flag} ON CACHE BOOL "Application feature selection")
endforeach()
foreach(flag QR_PER_FRAME_LOGS QR_CAMERA_COLORBARS QR_CANDIDATE_AUDIT
             QR_PIPELINE_TRACE QR_PINGPONG_STALL_TEST QR_FALLBACK_TEST
             QR_PERF_BLANK_TEST)
    set(${flag} OFF CACHE BOOL "Diagnostic injection/logging disabled")
endforeach()
