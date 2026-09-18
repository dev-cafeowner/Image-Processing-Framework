# Copyright (C) 2023-2024 Advanced Micro Devices, Inc.  All rights reserved.
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.16)

###    USER SETTINGS  START    ###
# Below settings can be customized
# User needs to edit it manually as per their needs.
###    DO NOT ADD OR REMOVE VARIABLES FROM THIS SECTION    ###
# -----------------------------------------
# Add any compiler definitions, they will be added as extra definitions
# Example : Adding VERBOSE=1 will pass -DVERBOSE=1 to the compiler.
set(USER_COMPILE_DEFINITIONS
)
option(QR_PREVIEW_FUSED "Single-pass common preview renderer" ON)
option(QR_PER_FRAME_LOGS "Diagnostic per-frame UART (perturbs timings)" OFF)
option(QR_CANDIDATE_AUDIT "Diagnostic QRP1 validation and sampled candidate logs" OFF)
option(QR_PL_GUIDED "Validated same-frame PL candidates guide bounded Geometry/ROI decode" OFF)
option(QR_GUIDED_EARLY_DECODE "Try ECC before iterative geometry refinement (guided route only)" OFF)
option(QR_FALLBACK_EARLY_DECODE "Try ECC before iterative refinement in the bounded full-image fallback" OFF)
option(QR_ROUTE_AUDIT "Rate-limited slow-route geometry diagnostics" OFF)
option(QR_FALLBACK_TEST "Diagnostic only: remove one PL candidate once per 60 frames" OFF)
if((QR_FALLBACK_EARLY_DECODE OR QR_ROUTE_AUDIT OR QR_FALLBACK_TEST) AND NOT QR_PL_GUIDED)
    message(FATAL_ERROR "Fallback options require the guided route")
endif()
set(QR_GUIDED_SEED_RADIUS_MIN "4" CACHE STRING "Minimum bounded finder seed tolerance (4..12 pixels)")
if(NOT QR_GUIDED_SEED_RADIUS_MIN MATCHES "^(4|8|12)$")
    message(FATAL_ERROR "Seed radius minimum must be 4, 8 or 12")
endif()
list(APPEND USER_COMPILE_DEFINITIONS QR_GUIDED_SEED_RADIUS_MIN=${QR_GUIDED_SEED_RADIUS_MIN})
option(QR_PIPELINE_TRACE "Diagnostic first-observed pipeline event timestamps" OFF)
option(QR_PINGPONG "QPP1 two-bank binary capture and independent Gray8 receiver" OFF)
option(QR_PINGPONG_STALL_TEST "Diagnostic only: hold Gray8 CPU ownership for 120ms" OFF)
if(QR_PINGPONG_STALL_TEST AND NOT QR_PINGPONG)
    message(FATAL_ERROR "Stall test requires QPP1")
endif()
if(QR_PINGPONG AND (QR_PIPELINE_TRACE OR NOT QR_PL_GUIDED OR NOT QR_CAMERA_CLEAN_PCLK))
    message(FATAL_ERROR "QPP1 requires guided capture with conditioned PCLK, without single-slot pipeline trace")
endif()
set(QR_WAIT_POLL_US "1000" CACHE STRING "Hardware wait polling interval in microseconds")
if(NOT QR_WAIT_POLL_US MATCHES "^(100|1000)$")
    message(FATAL_ERROR "QR_WAIT_POLL_US must be 100 or 1000")
endif()
list(APPEND USER_COMPILE_DEFINITIONS QR_WAIT_POLL_US=${QR_WAIT_POLL_US})
set(QR_FRONTEND_MODE "61" CACHE STRING "Frontend diagnostic mode: 61=original, 13=no morphology, 12=adaptive only, 4=global threshold")
if(NOT QR_FRONTEND_MODE MATCHES "^(4|12|13|61)$")
    message(FATAL_ERROR "Unsupported frontend test profile")
endif()
list(APPEND USER_COMPILE_DEFINITIONS QR_HW_FRONTEND_FE_MODE=${QR_FRONTEND_MODE})
option(QR_PREVIEW_NEON "Cortex-A9 SIMD common pixel renderer" ON)
option(QR_PL_PREVIEW "Common autonomous genlocked preview + PL HUD" OFF)
option(QR_CAMERA_SOURCE_SYNC "CAM3 receiver and 24MHz camera clock" OFF)
option(QR_CAMERA_CLEAN_PCLK "MMCM-conditioned 24MHz returned clock" OFF)
option(QR_CAMERA_COLORBARS "Diagnostic sensor-generated color bars (source-sync receiver only)" OFF)
set(QR_CAMERA_DRIVE "1" CACHE STRING "OV7670 COM2 drive: 0=1x, 1=2x, 2=3x, 3=4x")
if(NOT QR_CAMERA_DRIVE MATCHES "^[0-3]$")
    message(FATAL_ERROR "QR_CAMERA_DRIVE must be 0..3")
endif()
list(APPEND USER_COMPILE_DEFINITIONS QR_CAMERA_DRIVE=${QR_CAMERA_DRIVE})
if(QR_CAMERA_SOURCE_SYNC AND NOT QR_PL_PREVIEW)
    message(FATAL_ERROR "Source-sync capture requires autonomous PL preview")
endif()
if(QR_CAMERA_COLORBARS AND NOT QR_CAMERA_SOURCE_SYNC)
    message(FATAL_ERROR "Colorbar diagnostic requires source-sync capture")
endif()
if(QR_CAMERA_CLEAN_PCLK AND (NOT QR_CAMERA_SOURCE_SYNC OR NOT QR_CAMERA_CLKRC STREQUAL "128"))
    message(FATAL_ERROR "Conditioned returned clock requires source-sync and CLKRC=128")
endif()
foreach(flag QR_PREVIEW_FUSED QR_PER_FRAME_LOGS QR_PL_PREVIEW QR_CAMERA_SOURCE_SYNC QR_CAMERA_COLORBARS QR_CAMERA_CLEAN_PCLK QR_CANDIDATE_AUDIT QR_PL_GUIDED QR_GUIDED_EARLY_DECODE QR_PIPELINE_TRACE QR_PINGPONG QR_PINGPONG_STALL_TEST QR_FALLBACK_EARLY_DECODE QR_ROUTE_AUDIT QR_FALLBACK_TEST)
    if(${flag})
        list(APPEND USER_COMPILE_DEFINITIONS ${flag}=1)
    else()
        list(APPEND USER_COMPILE_DEFINITIONS ${flag}=0)
    endif()
endforeach()
set(QR_CAMERA_CLKRC "1" CACHE STRING "OV7670 CLKRC; selected configuration is in ApplicationConfig.cmake")
list(APPEND USER_COMPILE_DEFINITIONS QR_CAMERA_CLKRC=${QR_CAMERA_CLKRC})
option(QR_PERF_BLANK_TEST "Diagnostic only: decode white snapshots on frames 5-7" OFF)
if(QR_PERF_BLANK_TEST)
    list(APPEND USER_COMPILE_DEFINITIONS QR_PERF_BLANK_TEST=1)
endif()

# Undefine any previously specified compiler definitions, either built in or provided with a -D option
# Example : Adding MY_SYMBOL will pass -UMY_SYMBOL to the compiler.
set(USER_UNDEFINED_SYMBOLS
"__clang__"
)


# Add any directories below, they will be added as extra include directories.
# Example 1: Adding /proj/data/include will pass -I/proj/data/include.
# Example 2: Adding ../../common/include will consider the path as relative to this component directory.
# Example 3: Adding ${CMAKE_SOURCE_DIR}/data/include to add data/include from this project.

set(USER_INCLUDE_DIRECTORIES
)
set(USER_COMPILE_SOURCES
"camera_control.c"
"runtime_log.c"
"video_overlay.c"
"video_pixel_ops.c"
"video_vdma.c"
"image_capture_test.c"
"ov7670.c"
"vision_frontend.c"
"qr_dma.c"
"helloworld.c"
"platform.c"
"qr_csr.c"
"ov7670_axis_ctrl.c"
"candidate_packet_test.c"
"quirc.c"
"identify.c"
"decode.c"
"version_db.c"
"qr_decode.c"
"qr_candidate_geometry.c"
"qr_pipeline_trace.c"
"frame_receiver.c"
"display_ctrl/display_ctrl.c"
"dynclk/dynclk.c"
"hdmi_display.c"
"camera_live_preview.c"
"vision_runtime.c"
)

# -----------------------------------------

# Turn on all optional warnings (-Wall)
set(USER_COMPILE_WARNINGS_ALL "-Wall")

# Enable extra warning flags (-Wextra)
set(USER_COMPILE_WARNINGS_EXTRA "-Wextra")

# Make all warnings into hard errors (-Werror)
set(USER_COMPILE_WARNINGS_AS_ERRORS "")

# Check the code for syntax errors, but don't do anything beyond that (-fsyntax-only)
set(USER_COMPILE_WARNINGS_CHECK_SYNTAX_ONLY "")

# Issue all the mandatory diagnostics listed in the C standard (-pedantic)
set(USER_COMPILE_WARNINGS_PEDANTIC "")

# Issue all the mandatory diagnostics, and make all mandatory diagnostics into errors. (-pedantic-errors)
set(USER_COMPILE_WARNINGS_PEDANTIC_AS_ERRORS "")

# Suppress all warnings (-w)
set(USER_COMPILE_WARNINGS_INHIBIT_ALL "")

# -----------------------------------------

# Optimization level   "-O0" [None], "-O1" [Optimize] , "-O2" [Optimize More], "-O3" [Optimize Most] or "-Os" [Optimize Size]
set(QR_OPTIMIZATION "-O2" CACHE STRING "Application optimization (O0 only for comparison)")
set(USER_COMPILE_OPTIMIZATION_LEVEL "${QR_OPTIMIZATION}")


# Other flags related to optimization
set(USER_COMPILE_OPTIMIZATION_OTHER_FLAGS "")

# -----------------------------------------

# Debug level "" [None], "-g1" [Minimum], "g2" [Default], "g3" [Maximum]
set(USER_COMPILE_DEBUG_LEVEL "-g3")

# Other flags related to debugging
set(USER_COMPILE_DEBUG_OTHER_FLAGS "")

# -----------------------------------------

# Enable profiling (-pg) (This feature is not supported currently)
# set(USER_COMPILE_PROFILING_ENABLE )

# -----------------------------------------

# Verbose (-v)
set(USER_COMPILE_VERBOSE "")

# Support ANSI_PROGRAM (-ansi)
set(USER_COMPILE_ANSI "")

# Add any compiler options that are not covered by the above variables, they will be added as extra compiler options
# To enable profiling -pg [ for gprof ]  or -p [ for prof information ]
set(USER_COMPILE_OTHER_FLAGS "")

# -----------------------------------------

# Linker options
# Do not use the standard system startup files when linking.
# The standard system libraries are used normally, unless -nostdlib or -nodefaultlibs is used. (-nostartfiles)
set(USER_LINK_NO_START_FILES "")

# Do not use the standard system libraries when linking. (-nodefaultlibs)
set(USER_LINK_NO_DEFAULT_LIBS "")

# Do not use the standard system startup files or libraries when linking. (-nostdlib)
set(USER_LINK_NO_STDLIB "")

# Omit all symbol information. (-s)
set(USER_LINK_OMIT_ALL_SYMBOL_INFO "")


# -----------------------------------------

# Add any libraries to be linked below, they will be added as extra libraries.
# User needs to update USER_LINK_DIRECTORIES below with these library search paths.
set(USER_LINK_LIBRARIES
"m"
)

# Add any directories to look for the libraries to be linked.
# Example 1: Adding /proj/compression/lib will pass -L/proj/compression/lib to the linker.
# Example 2: Adding ../../common/lib will consider the path as relative to this directory and will pass the path to -L option.
set(USER_LINK_DIRECTORIES
)

# -----------------------------------------

set(USER_LINKER_SCRIPT "${CMAKE_SOURCE_DIR}/lscript.ld")

# Add linker options to be passed, they will be added as extra linker options
# Example : Adding -s will pass -s to the linker.
set(USER_LINK_OTHER_FLAGS
)

# -----------------------------------------

###   END OF USER SETTINGS SECTION ###
###   DO NOT EDIT BEYOND THIS LINE ###

set(USER_COMPILE_OPTIONS
    " ${USER_COMPILE_WARNINGS_ALL}"
    " ${USER_COMPILE_WARNINGS_EXTRA}"
    " ${USER_COMPILE_WARNINGS_AS_ERRORS}"
    " ${USER_COMPILE_WARNINGS_CHECK_SYNTAX_ONLY}"
    " ${USER_COMPILE_WARNINGS_PEDANTIC}"
    " ${USER_COMPILE_WARNINGS_PEDANTIC_AS_ERRORS}"
    " ${USER_COMPILE_WARNINGS_INHIBIT_ALL}"
    " ${USER_COMPILE_OPTIMIZATION_LEVEL}"
    " ${USER_COMPILE_OPTIMIZATION_OTHER_FLAGS}"
    " ${USER_COMPILE_DEBUG_LEVEL}"
    " ${USER_COMPILE_DEBUG_OTHER_FLAGS}"
    " ${USER_COMPILE_VERBOSE}"
    " ${USER_COMPILE_ANSI}"
    " ${USER_COMPILE_OTHER_FLAGS}"
)
foreach(entry ${USER_UNDEFINED_SYMBOLS})
    list(APPEND USER_COMPILE_OPTIONS " -U${entry}")
endforeach()

set(USER_LINK_OPTIONS
    " ${USER_LINKER_NO_START_FILES}"
    " ${USER_LINKER_NO_DEFAULT_LIBS}"
    " ${USER_LINKER_NO_STDLIB}"
    " ${USER_LINKER_OMIT_ALL_SYMBOL_INFO}"
    " ${USER_LINK_OTHER_FLAGS}"
)
