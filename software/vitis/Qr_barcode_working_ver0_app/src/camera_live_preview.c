#include "camera_live_preview.h"

#include <stddef.h>

#include "sleep.h"

#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

#include "ov7670.h"
#include "ov7670_axis_ctrl.h"

#include "qr_hw_config.h"

#include "video_vdma.h"
#include "vision_frontend.h"


/* ============================================================================
 * UART raw output
 * ========================================================================== */

extern void outbyte(char c);


/* ============================================================================
 * Preview configuration
 *
 * Camera / VDMA:
 *      640 x 480 RGB888
 *
 * UART preview:
 *      160 x 120 Gray4
 *
 * Downsample:
 *      4 x 4
 *
 * Packing:
 *      2 pixels / byte
 *
 * Result:
 *      160 * 120 / 2
 *      = 9600 byte / frame
 * ========================================================================== */

#define PREVIEW_WIDTH               160U
#define PREVIEW_HEIGHT              120U

#define PREVIEW_SCALE               4U

#define PREVIEW_PIXELS              \
    (PREVIEW_WIDTH * PREVIEW_HEIGHT)

#define PREVIEW_BYTES               \
    (PREVIEW_PIXELS / 2U)


#define PREVIEW_CAMERA_RETRY_COUNT  5U

#define PREVIEW_STARTUP_DELAY_US    100000U
#define PREVIEW_SENSOR_SETTLE_US    1000000U

#define PREVIEW_FRAME_DELAY_US      20000U


/* ============================================================================
 * Buffer alignment
 * ========================================================================== */

#if defined(__GNUC__)
#define PREVIEW_ALIGNED __attribute__((aligned(64)))
#else
#define PREVIEW_ALIGNED
#endif


/*
 * Gray4 packed preview buffer.
 *
 * byte:
 *
 * [7:4] pixel N
 * [3:0] pixel N+1
 */
static u8 preview_buffer[
    PREVIEW_BYTES
] PREVIEW_ALIGNED;


/* ============================================================================
 * Prepare OV7670
 *
 * SCCB is currently somewhat intermittent.
 * Instead of forcing the user to press Run repeatedly,
 * retry the complete controller + sensor initialization.
 * ========================================================================== */

static int preview_prepare_camera(
    ov7670_t *camera
)
{
    u32 attempt;

    u8 pid;
    u8 ver;

    int status;


    pid = 0U;
    ver = 0U;


    for (attempt = 1U;
         attempt <= PREVIEW_CAMERA_RETRY_COUNT;
         ++attempt) {

        xil_printf(
            "\r\n"
            "[CAMERA] Full init attempt %u/%u\r\n",
            (unsigned int)attempt,
            (unsigned int)PREVIEW_CAMERA_RETRY_COUNT
        );


        status =
            ov7670_init(
                camera,
                QR_HW_I2C0_BASEADDR,
                QR_HW_I2C_SCLK_HZ
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[WARN] OV7670 I2C init failed\r\n"
            );


            usleep(
                100000U
            );


            continue;
        }


        /*
         * Let SCCB/I2C side settle.
         */
        usleep(
            PREVIEW_STARTUP_DELAY_US
        );


        status =
            ov7670_prepare_vga_rgb565(
                camera,
                (u8)QR_HW_OV7670_CLKRC_BRINGUP,
                &pid,
                &ver
            );


        if (status ==
            XST_SUCCESS) {

            xil_printf(
                "[PASS] Camera ready "
                "PID=0x%02x VER=0x%02x\r\n",
                pid,
                ver
            );


            return XST_SUCCESS;
        }


        xil_printf(
            "[WARN] Camera setup failed "
            "on outer attempt %u\r\n",
            (unsigned int)attempt
        );


        usleep(
            100000U
        );
    }


    xil_printf(
        "[FAIL] Camera setup failed after %u attempts\r\n",
        (unsigned int)PREVIEW_CAMERA_RETRY_COUNT
    );


    return XST_FAILURE;
}


/* ============================================================================
 * Capture one downsampled snapshot
 *
 * RGB888 DDR:
 *
 *     640 x 480
 *     3 bytes / pixel
 *     stride = 1920
 *
 * Preview:
 *
 *     sample one pixel from every 4x4 area
 *     160 x 120
 *
 * RGB byte order does not matter because all three channels
 * are averaged.
 * ========================================================================== */

static void preview_make_snapshot(void)
{
    UINTPTR frame_addr;

    volatile u8 *rgb;

    u32 px;
    u32 py;

    u32 sx;
    u32 sy;

    u32 rgb_offset;

    u32 preview_index;
    u32 byte_index;

    u32 gray;

    u8 gray4;


    frame_addr =
        video_vdma_frame_addr(
            0U
        );


    /*
     * AXI VDMA writes DDR directly.
     *
     * Remove stale CPU cache before reading framebuffer.
     */
    Xil_DCacheInvalidateRange(
        (INTPTR)frame_addr,
        VIDEO_VDMA_FRAME_BYTES
    );


    rgb =
        (volatile u8 *)frame_addr;


    /*
     * Clear destination.
     */
    for (byte_index = 0U;
         byte_index < PREVIEW_BYTES;
         ++byte_index) {

        preview_buffer[byte_index] =
            0U;
    }


    preview_index =
        0U;


    for (py = 0U;
         py < PREVIEW_HEIGHT;
         ++py) {

        /*
         * Sample approximately the center of each 4-pixel group.
         */
        sy =
            (py * PREVIEW_SCALE) +
            2U;


        if (sy >= VIDEO_VDMA_HEIGHT) {

            sy =
                VIDEO_VDMA_HEIGHT - 1U;
        }


        for (px = 0U;
             px < PREVIEW_WIDTH;
             ++px) {

            sx =
                (px * PREVIEW_SCALE) +
                2U;


            if (sx >= VIDEO_VDMA_WIDTH) {

                sx =
                    VIDEO_VDMA_WIDTH - 1U;
            }


            rgb_offset =
                (sy * VIDEO_VDMA_STRIDE) +
                (sx * VIDEO_VDMA_BYTES_PER_PIXEL);


            /*
             * Simple diagnostic grayscale:
             *
             * (C0 + C1 + C2) / 3
             *
             * Therefore RGB/BGR ordering is irrelevant.
             */
            gray =
                (
                    (u32)rgb[rgb_offset + 0U] +
                    (u32)rgb[rgb_offset + 1U] +
                    (u32)rgb[rgb_offset + 2U]
                ) / 3U;


            /*
             * 8-bit Gray -> 4-bit Gray.
             */
            gray4 =
                (u8)(
                    (gray >> 4) &
                    0x0FU
                );


            byte_index =
                preview_index >> 1;


            if ((preview_index &
                 1U) == 0U) {

                /*
                 * Even pixel -> upper nibble.
                 */
                preview_buffer[byte_index] =
                    (u8)(
                        gray4 << 4
                    );
            }
            else {

                /*
                 * Odd pixel -> lower nibble.
                 */
                preview_buffer[byte_index] |=
                    gray4;
            }


            ++preview_index;
        }
    }
}


/* ============================================================================
 * UART send one preview frame
 * ========================================================================== */

static void preview_send_frame(
    u32 frame_number
)
{
    u32 i;


    /*
     * ASCII marker.
     *
     * Python waits for this line before reading binary payload.
     */
    xil_printf(
        "PREVIEW_BEGIN %u %u %u %u\r\n",
        (unsigned int)PREVIEW_WIDTH,
        (unsigned int)PREVIEW_HEIGHT,
        (unsigned int)PREVIEW_BYTES,
        (unsigned int)frame_number
    );


    /*
     * Raw 4-bit packed image.
     */
    for (i = 0U;
         i < PREVIEW_BYTES;
         ++i) {

        outbyte(
            (char)preview_buffer[i]
        );
    }


    xil_printf(
        "\r\n"
        "PREVIEW_END\r\n"
    );
}


/* ============================================================================
 * Live preview
 * ========================================================================== */

int camera_live_preview_run(void)
{
    video_vdma_s2mm_t video_vdma;

    qr_frontend_t frontend;

    ov7670_t camera;


    u32 frame_number;

    int status;


    frame_number =
        0U;


    xil_printf(
        "\r\n"
        "========================================\r\n"
        " OV7670 UART Live Focus Preview\r\n"
        "========================================\r\n"
    );


    xil_printf(
        "Source  : 640x480 RGB888 VDMA\r\n"
    );


    xil_printf(
        "Preview : %ux%u Gray4 packed\r\n",
        (unsigned int)PREVIEW_WIDTH,
        (unsigned int)PREVIEW_HEIGHT
    );


    xil_printf(
        "Payload : %u bytes/frame\r\n",
        (unsigned int)PREVIEW_BYTES
    );


    /* ========================================================================
     * 1. Camera AXIS source OFF
     * ====================================================================== */

    ov7670_axis_capture_disable();


    xil_printf(
        "AXIS CTRL(init): 0x%08x\r\n",
        ov7670_axis_read_control()
    );


    /* ========================================================================
     * 2. Frontend
     *
     * Keep its AXIS input path alive.
     *
     * The frontend may hold its first Binary Frame because no QR runtime
     * release is performed in this preview utility. Subsequent frames are
     * dropped as whole frames internally; the camera AXIS path continues.
     * ====================================================================== */

    qr_frontend_init(
        &frontend,
        QR_HW_FRONTEND_BASEADDR
    );


    if (qr_frontend_probe(
            &frontend
        ) != XST_SUCCESS) {

        xil_printf(
            "[FAIL] Frontend VERSION\r\n"
        );


        return XST_FAILURE;
    }


    qr_frontend_quiesce(
        &frontend
    );


    qr_frontend_set_mode(
        &frontend,
        QR_HW_FRONTEND_FE_MODE
    );


#if QR_HW_FRONTEND_PROGRAM_THRESH

    qr_frontend_set_threshold(
        &frontend,
        QR_HW_FRONTEND_THRESH
    );

#endif


#if QR_HW_FRONTEND_PROGRAM_GEOM

    qr_frontend_set_geometry(
        &frontend,
        QR_HW_FRONTEND_GEOM
    );

#endif


    qr_frontend_enable(
        &frontend,
        QR_HW_FRONTEND_FB_INVERT
    );


    xil_printf(
        "[PASS] Frontend stream consumer ready\r\n"
    );


    /* ========================================================================
     * 3. VDMA S2MM
     * ====================================================================== */

    status =
        video_vdma_s2mm_init_start(
            &video_vdma,
            QR_HW_VDMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Video VDMA start: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "VDMA FB : 0x%08x\r\n",
        (u32)video_vdma_frame_addr(
            0U
        )
    );


    xil_printf(
        "Stride  : %u\r\n",
        (unsigned int)VIDEO_VDMA_STRIDE
    );


    xil_printf(
        "[PASS] VDMA S2MM running\r\n"
    );


    /* ========================================================================
     * 4. OV7670 SCCB + real VGA RGB565 mode
     * ====================================================================== */

    status =
        preview_prepare_camera(
            &camera
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /*
     * Let sensor auto exposure / gain / white balance settle.
     */
    xil_printf(
        "Camera settle 1000 ms...\r\n"
    );


    usleep(
        PREVIEW_SENSOR_SETTLE_US
    );


    /* ========================================================================
     * 5. Start camera AXIS
     * ====================================================================== */

    ov7670_axis_stat_clear();


    status =
        ov7670_axis_capture_enable();


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Camera AXIS enable\r\n"
        );


        return XST_FAILURE;
    }


    xil_printf(
        "[PASS] Camera streaming\r\n"
    );


    /*
     * Wait a couple of frames before showing the first preview.
     */
    usleep(
        200000U
    );


    xil_printf(
        "\r\n"
        "[LIVE] Preview stream started\r\n"
    );


    /* ========================================================================
     * 6. Forever:
     *
     * VDMA framebuffer
     *    -> 160x120 snapshot
     *    -> 4-bit pack
     *    -> UART
     *
     * UART transmission itself limits this to roughly 1 fps at 115200.
     * ====================================================================== */

    for (;;) {

        preview_make_snapshot();


        preview_send_frame(
            frame_number
        );


        ++frame_number;


        /*
         * Small gap so the PC parser has a clean interval.
         */
        usleep(
            PREVIEW_FRAME_DELAY_US
        );
    }


    /*
     * Not reached.
     */
    return XST_SUCCESS;
}