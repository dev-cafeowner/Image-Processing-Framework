#include "stage6_qr_runtime.h"

#include <string.h>

#include "sleep.h"

#include "xaxidma_hw.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

/* Camera */
#include "ov7670.h"
#include "ov7670_axis_ctrl.h"

/* QR / Runtime */
#include "qr_csr.h"
#include "qr_decode.h"
#include "qr_dma.h"
#include "qr_hw_config.h"

/* Vision */
#include "vision_frontend.h"

/* Video / HDMI */
#include "video_vdma.h"
#include "hdmi_display.h"


/* ============================================================================
 * Alignment
 * ========================================================================== */

#if defined(__GNUC__)
#define QR_DMA_ALIGNED __attribute__((aligned(64)))
#else
#define QR_DMA_ALIGNED
#endif


/* ============================================================================
 * Stage 6 constants
 * ========================================================================== */

#define STAGE6_TIMEOUT_MS               5000U

#define STAGE6_CAMERA_STARTUP_US        100000U
#define STAGE6_CAMERA_SETTLE_US         3000000U

#define STAGE6_CAMERA_OUTER_RETRIES     5U

#define STAGE6_RESULT_MAX               QR_DECODE_RESULT_MAX


/* ============================================================================
 * DMA buffers
 * ========================================================================== */

/*
 * Exact-Sync Gray8 image
 *
 * 640 x 480 x 1 byte
 * = 307200 bytes
 */
static u8 image_buffer[
    QR_HW_IMAGE_BYTES
] QR_DMA_ALIGNED;


/*
 * QRP1 result packet buffer
 */
static u32 result_buffer[
    QR_HW_QRP1_MAX_WORDS
] QR_DMA_ALIGNED;


/*
 * Last successfully decoded QR payload.
 *
 * This is NEVER cleared merely because the current frame
 * does not contain a QR.
 */
static char last_result[
    STAGE6_RESULT_MAX
];


/* ============================================================================
 * Wait AXI DMA S2MM completion
 * ========================================================================== */

static int stage6_wait_dma(
    qr_dma_s2mm_t *dma,
    const char *name
)
{
    u32 elapsed_ms;
    u32 dma_status;


    if ((dma == NULL) ||
        (name == NULL)) {

        return XST_FAILURE;
    }


    elapsed_ms = 0U;


    while (qr_dma_s2mm_busy(dma)) {

        dma_status =
            qr_dma_s2mm_status(
                dma
            );


        if ((dma_status &
             XAXIDMA_ERR_ALL_MASK) != 0U) {

            xil_printf(
                "[FAIL] %s DMA error "
                "SR=0x%08x\r\n",
                name,
                dma_status
            );


            return XST_FAILURE;
        }


        if (elapsed_ms >=
            STAGE6_TIMEOUT_MS) {

            xil_printf(
                "[FAIL] %s DMA timeout "
                "SR=0x%08x\r\n",
                name,
                dma_status
            );


            return XST_FAILURE;
        }


        usleep(
            1000U
        );


        ++elapsed_ms;
    }


    dma_status =
        qr_dma_s2mm_status(
            dma
        );


    if ((dma_status &
         XAXIDMA_ERR_ALL_MASK) != 0U) {

        xil_printf(
            "[FAIL] %s DMA final error "
            "SR=0x%08x\r\n",
            name,
            dma_status
        );


        return XST_FAILURE;
    }


    return XST_SUCCESS;
}


/* ============================================================================
 * Wait Runtime STATUS bit = 1
 * ========================================================================== */

static int stage6_wait_status_set(
    qr_csr_t *csr,
    u32 mask,
    const char *name
)
{
    u32 elapsed_ms;
    u32 status;


    if ((csr == NULL) ||
        (name == NULL)) {

        return XST_FAILURE;
    }


    elapsed_ms = 0U;


    for (;;) {

        status =
            qr_csr_read(
                csr,
                QR_CSR_STATUS
            );


        if ((status & mask) != 0U) {

            return XST_SUCCESS;
        }


        /*
         * Runtime errors.
         */
        if ((status &
             (
                 QR_STATUS_COMBINED_ERROR |
                 QR_STATUS_IMAGE_OVERFLOW_ERROR |
                 QR_STATUS_FRAME_ID_PROTOCOL_ERROR
             )) != 0U) {

            xil_printf(
                "[FAIL] Runtime error while waiting %s\r\n",
                name
            );


            xil_printf(
                "STATUS      : 0x%08x\r\n",
                status
            );


            xil_printf(
                "ERROR_FLAGS : 0x%08x\r\n",
                qr_csr_read(
                    csr,
                    QR_CSR_ERROR_FLAGS
                )
            );


            return XST_FAILURE;
        }


        if (elapsed_ms >=
            STAGE6_TIMEOUT_MS) {

            xil_printf(
                "[FAIL] Timeout waiting %s "
                "STATUS=0x%08x\r\n",
                name,
                status
            );


            return XST_FAILURE;
        }


        usleep(
            1000U
        );


        ++elapsed_ms;
    }
}


/* ============================================================================
 * Wait Runtime STATUS bit = 0
 *
 * IMPORTANT:
 * This function intentionally does NOT treat sticky error bits
 * as an immediate failure.
 *
 * It is used during FRAME_ACK / release cleanup, where those
 * sticky bits may still be present until ERROR_CLEAR.
 * ========================================================================== */

static int stage6_wait_status_clear(
    qr_csr_t *csr,
    u32 mask,
    const char *name
)
{
    u32 elapsed_ms;
    u32 status;


    if ((csr == NULL) ||
        (name == NULL)) {

        return XST_FAILURE;
    }


    elapsed_ms = 0U;


    for (;;) {

        status =
            qr_csr_read(
                csr,
                QR_CSR_STATUS
            );


        if ((status & mask) == 0U) {

            return XST_SUCCESS;
        }


        if (elapsed_ms >=
            STAGE6_TIMEOUT_MS) {

            xil_printf(
                "[FAIL] Timeout clearing %s "
                "STATUS=0x%08x\r\n",
                name,
                status
            );


            return XST_FAILURE;
        }


        usleep(
            1000U
        );


        ++elapsed_ms;
    }
}


/* ============================================================================
 * Arm Gray8 Image DMA
 * ========================================================================== */

static int stage6_arm_image_dma(
    qr_dma_s2mm_t *image_dma
)
{
    int status;


    if (image_dma == NULL) {

        return XST_FAILURE;
    }


    /*
     * CPU -> DMA ownership preparation.
     */
    Xil_DCacheFlushRange(
        (INTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    Xil_DCacheInvalidateRange(
        (INTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    status =
        qr_dma_s2mm_arm(
            image_dma,
            (UINTPTR)image_buffer,
            QR_HW_IMAGE_BYTES
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Image DMA arm: %d\r\n",
            status
        );


        return status;
    }


    return XST_SUCCESS;
}


/* ============================================================================
 * Camera complete initialization
 *
 * SCCB is still intermittent.
 * Therefore retry the entire camera initialization sequence.
 * ========================================================================== */

static int stage6_prepare_camera(
    ov7670_t *camera
)
{
    u32 attempt;

    u8 pid;
    u8 ver;

    int status;


    if (camera == NULL) {

        return XST_FAILURE;
    }


    pid = 0U;
    ver = 0U;


    for (attempt = 1U;
         attempt <= STAGE6_CAMERA_OUTER_RETRIES;
         ++attempt) {

        xil_printf(
            "[CAMERA] setup attempt %u/%u\r\n",
            (unsigned int)attempt,
            (unsigned int)STAGE6_CAMERA_OUTER_RETRIES
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
                "[WARN] Camera I2C init failed\r\n"
            );


            usleep(
                100000U
            );


            continue;
        }


        /*
         * Let SCCB controller / camera settle.
         */
        usleep(
            STAGE6_CAMERA_STARTUP_US
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
            "[WARN] Camera setup retry\r\n"
        );


        usleep(
            100000U
        );
    }


    xil_printf(
        "[FAIL] Camera setup failed\r\n"
    );


    return XST_FAILURE;
}


/* ============================================================================
 * UART application UI
 *
 * Final HDMI overlay will use exactly the same state.
 * ========================================================================== */
/* ============================================================================
 * HDMI UI
 *
 * 5 x 7 font
 * scale = 2
 *
 * Gray8 framebuffer 위에 직접 그린 뒤
 * hdmi_display_show_gray8()가 RGB888 HDMI framebuffer로 복사한다.
 * ========================================================================== */

#define STAGE6_UI_WIDTH              640U
#define STAGE6_UI_HEIGHT             480U

#define STAGE6_UI_FONT_WIDTH         5U
#define STAGE6_UI_FONT_HEIGHT        7U

#define STAGE6_UI_FONT_SCALE         2U

#define STAGE6_UI_PANEL_HEIGHT       64U

#define STAGE6_UI_BG                 0U
#define STAGE6_UI_FG                 255U


/* ============================================================================
 * 5x7 character bitmap
 *
 * bit4 = left pixel
 * bit0 = right pixel
 * ========================================================================== */

static void stage6_font5x7(
    char c,
    u8 rows[7]
)
{
    u32 i;


    for (i = 0U; i < 7U; ++i) {
        rows[i] = 0U;
    }


    /* lowercase -> uppercase */
    if ((c >= 'a') && (c <= 'z')) {
        c = (char)(c - 'a' + 'A');
    }


    switch (c) {

    case 'A':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1FU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'B':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1EU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x1EU;
        break;

    case 'C':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x10U;
        rows[3]=0x10U; rows[4]=0x10U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case 'D':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x1EU;
        break;

    case 'E':
        rows[0]=0x1FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x1FU;
        break;

    case 'F':
        rows[0]=0x1FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x10U;
        break;

    case 'G':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x10U;
        rows[3]=0x17U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0FU;
        break;

    case 'H':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1FU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'I':
        rows[0]=0x1FU; rows[1]=0x04U; rows[2]=0x04U;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x1FU;
        break;

    case 'J':
        rows[0]=0x07U; rows[1]=0x02U; rows[2]=0x02U;
        rows[3]=0x02U; rows[4]=0x12U; rows[5]=0x12U;
        rows[6]=0x0CU;
        break;

    case 'K':
        rows[0]=0x11U; rows[1]=0x12U; rows[2]=0x14U;
        rows[3]=0x18U; rows[4]=0x14U; rows[5]=0x12U;
        rows[6]=0x11U;
        break;

    case 'L':
        rows[0]=0x10U; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x10U; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x1FU;
        break;

    case 'M':
        rows[0]=0x11U; rows[1]=0x1BU; rows[2]=0x15U;
        rows[3]=0x15U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'N':
        rows[0]=0x11U; rows[1]=0x19U; rows[2]=0x15U;
        rows[3]=0x13U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'O':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case 'P':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1EU; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x10U;
        break;

    case 'Q':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x15U; rows[5]=0x12U;
        rows[6]=0x0DU;
        break;

    case 'R':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1EU; rows[4]=0x14U; rows[5]=0x12U;
        rows[6]=0x11U;
        break;

    case 'S':
        rows[0]=0x0FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x0EU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x1EU;
        break;

    case 'T':
        rows[0]=0x1FU; rows[1]=0x04U; rows[2]=0x04U;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x04U;
        break;

    case 'U':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case 'V':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x0AU;
        rows[6]=0x04U;
        break;

    case 'W':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x15U; rows[4]=0x15U; rows[5]=0x15U;
        rows[6]=0x0AU;
        break;

    case 'X':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x0AU;
        rows[3]=0x04U; rows[4]=0x0AU; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'Y':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x0AU;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x04U;
        break;

    case 'Z':
        rows[0]=0x1FU; rows[1]=0x01U; rows[2]=0x02U;
        rows[3]=0x04U; rows[4]=0x08U; rows[5]=0x10U;
        rows[6]=0x1FU;
        break;


    case '0':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x13U;
        rows[3]=0x15U; rows[4]=0x19U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case '1':
        rows[0]=0x04U; rows[1]=0x0CU; rows[2]=0x04U;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x0EU;
        break;

    case '2':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x01U;
        rows[3]=0x02U; rows[4]=0x04U; rows[5]=0x08U;
        rows[6]=0x1FU;
        break;

    case '3':
        rows[0]=0x1EU; rows[1]=0x01U; rows[2]=0x01U;
        rows[3]=0x0EU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x1EU;
        break;

    case '4':
        rows[0]=0x02U; rows[1]=0x06U; rows[2]=0x0AU;
        rows[3]=0x12U; rows[4]=0x1FU; rows[5]=0x02U;
        rows[6]=0x02U;
        break;

    case '5':
        rows[0]=0x1FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x1EU;
        break;

    case '6':
        rows[0]=0x0EU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case '7':
        rows[0]=0x1FU; rows[1]=0x01U; rows[2]=0x02U;
        rows[3]=0x04U; rows[4]=0x08U; rows[5]=0x08U;
        rows[6]=0x08U;
        break;

    case '8':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x0EU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case '9':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x0FU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x0EU;
        break;


    case ':':
        rows[1]=0x04U;
        rows[2]=0x04U;
        rows[4]=0x04U;
        rows[5]=0x04U;
        break;

    case '-':
        rows[3]=0x0EU;
        break;

    case '.':
        rows[6]=0x04U;
        break;

    case '/':
        rows[0]=0x01U;
        rows[1]=0x02U;
        rows[2]=0x02U;
        rows[3]=0x04U;
        rows[4]=0x08U;
        rows[5]=0x08U;
        rows[6]=0x10U;
        break;

    case ' ':
        break;


    default:
        /* '?' */
        rows[0]=0x0EU;
        rows[1]=0x11U;
        rows[2]=0x01U;
        rows[3]=0x02U;
        rows[4]=0x04U;
        rows[6]=0x04U;
        break;
    }
}


/* ============================================================================
 * Fill rectangle on Gray8 image
 * ========================================================================== */

static void stage6_fill_rect(
    u8 *image,
    u32 x,
    u32 y,
    u32 width,
    u32 height,
    u8 value
)
{
    u32 px;
    u32 py;


    if (image == NULL) {
        return;
    }


    for (py = 0U; py < height; ++py) {

        if ((y + py) >= STAGE6_UI_HEIGHT) {
            break;
        }


        for (px = 0U; px < width; ++px) {

            if ((x + px) >= STAGE6_UI_WIDTH) {
                break;
            }


            image[
                ((y + py) * STAGE6_UI_WIDTH)
                + (x + px)
            ] = value;
        }
    }
}


/* ============================================================================
 * Draw one character
 * ========================================================================== */

static void stage6_draw_char(
    u8 *image,
    u32 x,
    u32 y,
    char c
)
{
    u8 rows[7];

    u32 row;
    u32 col;

    u32 sx;
    u32 sy;


    stage6_font5x7(
        c,
        rows
    );


    for (row = 0U;
         row < STAGE6_UI_FONT_HEIGHT;
         ++row) {

        for (col = 0U;
             col < STAGE6_UI_FONT_WIDTH;
             ++col) {

            if ((rows[row] &
                 (1U << (4U - col))) == 0U) {

                continue;
            }


            for (sy = 0U;
                 sy < STAGE6_UI_FONT_SCALE;
                 ++sy) {

                for (sx = 0U;
                     sx < STAGE6_UI_FONT_SCALE;
                     ++sx) {

                    u32 px;
                    u32 py;


                    px =
                        x +
                        (col * STAGE6_UI_FONT_SCALE) +
                        sx;


                    py =
                        y +
                        (row * STAGE6_UI_FONT_SCALE) +
                        sy;


                    if ((px < STAGE6_UI_WIDTH) &&
                        (py < STAGE6_UI_HEIGHT)) {

                        image[
                            (py * STAGE6_UI_WIDTH) +
                            px
                        ] = STAGE6_UI_FG;
                    }
                }
            }
        }
    }
}


/* ============================================================================
 * Draw string
 * ========================================================================== */

static void stage6_draw_text(
    u8 *image,
    u32 x,
    u32 y,
    const char *text
)
{
    u32 cursor_x;

    u32 char_step;


    if ((image == NULL) ||
        (text == NULL)) {

        return;
    }


    cursor_x =
        x;


    char_step =
        (
            STAGE6_UI_FONT_WIDTH *
            STAGE6_UI_FONT_SCALE
        ) +
        STAGE6_UI_FONT_SCALE;


    while (*text != '\0') {

        if ((cursor_x +
             (
                 STAGE6_UI_FONT_WIDTH *
                 STAGE6_UI_FONT_SCALE
             )) >= STAGE6_UI_WIDTH) {

            break;
        }


        stage6_draw_char(
            image,
            cursor_x,
            y,
            *text
        );


        cursor_x +=
            char_step;


        ++text;
    }
}


/* ============================================================================
 * Draw final UI
 *
 * STATUS:
 *
 * Current frame recognition state.
 *
 * RESULT:
 *
 * Last successful QR payload.
 * It persists until another valid QR is decoded.
 * ========================================================================== */

static void stage6_draw_ui(
    u8 *image,
    int detected
)
{
    /*
     * Black banner over camera image.
     */
    stage6_fill_rect(
        image,
        0U,
        0U,
        STAGE6_UI_WIDTH,
        STAGE6_UI_PANEL_HEIGHT,
        STAGE6_UI_BG
    );


    /*
     * Line 1
     */
    stage6_draw_text(
        image,
        12U,
        8U,
        "STATUS:"
    );


    if (detected != 0) {

        stage6_draw_text(
            image,
            108U,
            8U,
            "DETECTED"
        );
    }
    else {

        stage6_draw_text(
            image,
            108U,
            8U,
            "SEARCHING"
        );
    }


    /*
     * Line 2
     */
    stage6_draw_text(
        image,
        12U,
        36U,
        "RESULT:"
    );


    if (last_result[0] != '\0') {

        stage6_draw_text(
            image,
            108U,
            36U,
            last_result
        );
    }
    else {

        stage6_draw_text(
            image,
            108U,
            36U,
            "--"
        );
    }
}

static void stage6_print_ui(
    int detected
)
{
    xil_printf(
        "\r\n"
        "----------------------------------------\r\n"
    );


    if (detected != 0) {

        xil_printf(
            "STATUS : DETECTED\r\n"
        );
    }
    else {

        xil_printf(
            "STATUS : SEARCHING\r\n"
        );
    }


    /*
     * IMPORTANT:
     *
     * last_result persists across frames where QR decode fails
     * or no QR is visible.
     */
    if (last_result[0] != '\0') {

        xil_printf(
            "RESULT : %s\r\n",
            last_result
        );
    }
    else {

        xil_printf(
            "RESULT : --\r\n"
        );
    }


    xil_printf(
        "----------------------------------------\r\n"
    );
}


/* ============================================================================
 * Stage 6
 *
 * Continuous QR runtime
 * ========================================================================== */

int stage6_qr_runtime_run(void)
{
    /* ========================================================================
     * Hardware instances
     * ====================================================================== */

    qr_dma_s2mm_t image_dma;
    qr_dma_s2mm_t result_dma;

    qr_csr_t csr;

    qr_frontend_t frontend;

    video_vdma_s2mm_t video_vdma;

    hdmi_display_t hdmi;

    ov7670_t camera;


    /* ========================================================================
     * QR decode
     * ====================================================================== */

    char decoded_payload[
        QR_DECODE_RESULT_MAX
    ];


    qr_decode_box_t decoded_box;


    /* ========================================================================
     * Runtime metadata
     * ====================================================================== */

    u32 frame_count;

    u32 result_words;
    u32 result_bytes;

    u32 candidate_count;

    u32 clear_status;


    /* ========================================================================
     * Generic
     * ====================================================================== */

    int decode_status;

    int detected;

    int status;


    /* ========================================================================
     * Initial state
     * ====================================================================== */

    frame_count = 0U;


    last_result[0] =
        '\0';


    xil_printf(
        "\r\n"
        "========================================\r\n"
        " Stage 6 Continuous QR Runtime\r\n"
        "========================================\r\n"
    );


    /* ========================================================================
     * 1. Camera AXIS producer OFF
     * ====================================================================== */

    ov7670_axis_capture_disable();


    /* ========================================================================
     * 2. Vision Frontend
     * ====================================================================== */

    qr_frontend_init(
        &frontend,
        QR_HW_FRONTEND_BASEADDR
    );


    if (qr_frontend_probe(
            &frontend
        ) !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Frontend probe\r\n"
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


    xil_printf(
        "[PASS] Frontend configured\r\n"
    );


    /* ========================================================================
     * 3. Runtime CSR
     * ====================================================================== */

    qr_csr_init(
        &csr,
        QR_HW_RUNTIME_BASEADDR
    );


    if (qr_csr_probe_contract(
            &csr
        ) !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Runtime CSR contract\r\n"
        );


        return XST_FAILURE;
    }


    qr_csr_set_persistent(
        &csr,
        0U
    );


    qr_csr_pulse(
        &csr,
        QR_CTRL_ERROR_CLEAR
    );


    qr_csr_clear_irq(
        &csr,
        QR_IRQ_ALL
    );


    xil_printf(
        "[PASS] Runtime initialized\r\n"
    );


    /* ========================================================================
     * 4. Video VDMA S2MM
     * ====================================================================== */

    status =
        video_vdma_s2mm_init_start(
            &video_vdma,
            QR_HW_VDMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Video VDMA: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "[PASS] Video VDMA S2MM running\r\n"
    );


    /* ========================================================================
     * 5. HDMI
     * ====================================================================== */

    status =
        hdmi_display_init(
            &hdmi,
            &video_vdma
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] HDMI init: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "[PASS] HDMI initialized\r\n"
    );


    /* ========================================================================
     * 6. Image AXI DMA
     * ====================================================================== */

    status =
        qr_dma_s2mm_init(
            &image_dma,
            QR_HW_IMAGE_DMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Image DMA init\r\n"
        );


        return status;
    }


    /* ========================================================================
     * 7. Result AXI DMA
     * ====================================================================== */

    status =
        qr_dma_s2mm_init(
            &result_dma,
            QR_HW_RESULT_DMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Result DMA init\r\n"
        );


        return status;
    }


    xil_printf(
        "[PASS] AXI DMA initialized\r\n"
    );


    /* ========================================================================
     * 8. quirc QR decoder
     * ====================================================================== */

    status =
        qr_decode_init();


    if (status !=
        QR_DECODE_OK) {

        xil_printf(
            "[FAIL] QR decoder init\r\n"
        );


        return XST_FAILURE;
    }


    /* ========================================================================
     * 9. OV7670 camera configuration
     * ====================================================================== */

    status =
        stage6_prepare_camera(
            &camera
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    xil_printf(
        "Camera exposure settle 3000 ms...\r\n"
    );


    usleep(
        STAGE6_CAMERA_SETTLE_US
    );


    /* ========================================================================
     * 10. Frontend ON
     * ====================================================================== */

    qr_frontend_enable(
        &frontend,
        QR_HW_FRONTEND_FB_INVERT
    );


    /* ========================================================================
     * 11. FIRST Image DMA
     *
     * Must be armed BEFORE runtime and camera producer.
     * ====================================================================== */

    status =
        stage6_arm_image_dma(
            &image_dma
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * 12. Runtime enable
     * ====================================================================== */

    qr_csr_set_persistent(
        &csr,
        QR_CTRL_PERSISTENT_DEFAULT
    );


    xil_printf(
        "Runtime CTRL : 0x%08x\r\n",
        qr_csr_read(
            &csr,
            QR_CSR_CONTROL
        )
    );


    /* ========================================================================
     * 13. Camera AXIS producer ON LAST
     * ====================================================================== */

    ov7670_axis_stat_clear();


    status =
        ov7670_axis_capture_enable();


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Camera AXIS start\r\n"
        );


        return XST_FAILURE;
    }


    xil_printf(
        "[PASS] Continuous camera capture started\r\n"
    );


    xil_printf(
        "\r\n"
        "========================================\r\n"
        " QR runtime active\r\n"
        "========================================\r\n"
    );


    /* ========================================================================
     * Continuous frame loop
     * ====================================================================== */

    for (;;) {

        detected =
            0;


        decoded_payload[0] =
            '\0';


        /* ====================================================================
         * A. Wait PL result metadata ready
         * ================================================================== */

        status =
            stage6_wait_status_set(
                &csr,
                QR_STATUS_RESULT_READY,
                "RESULT_READY"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        result_words =
            qr_csr_read(
                &csr,
                QR_CSR_RESULT_WORDS
            );


        candidate_count =
            qr_csr_read(
                &csr,
                QR_CSR_CANDIDATE_COUNT
            );


        /*
         * PL candidate records are currently not used for the PS full-frame
         * decoder, but QRP1 stream still must be drained.
         */
        if ((result_words < 5U) ||
            (result_words >
             QR_HW_QRP1_MAX_WORDS)) {

            xil_printf(
                "[FAIL] Invalid RESULT_WORDS=%u\r\n",
                (unsigned int)result_words
            );


            return XST_FAILURE;
        }


        result_bytes =
            result_words *
            sizeof(u32);


        /* ====================================================================
         * B. Arm Result DMA
         * ================================================================== */

        Xil_DCacheFlushRange(
            (INTPTR)result_buffer,
            result_bytes
        );


        Xil_DCacheInvalidateRange(
            (INTPTR)result_buffer,
            result_bytes
        );


        status =
            qr_dma_s2mm_arm(
                &result_dma,
                (UINTPTR)result_buffer,
                result_bytes
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[FAIL] Result DMA arm\r\n"
            );


            return status;
        }


        /* ====================================================================
         * C. Request QRP1 stream
         * ================================================================== */

        qr_csr_pulse(
            &csr,
            QR_CTRL_STREAM_START
        );


        /* ====================================================================
         * D. Wait Result DMA
         * ================================================================== */

        status =
            stage6_wait_dma(
                &result_dma,
                "Result"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        Xil_DCacheInvalidateRange(
            (INTPTR)result_buffer,
            result_bytes
        );


        /* ====================================================================
         * E. Wait Exact Gray8 Image DMA
         * ================================================================== */

        status =
            stage6_wait_dma(
                &image_dma,
                "Image"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        /*
         * DMA -> CPU ownership.
         */
        Xil_DCacheInvalidateRange(
            (INTPTR)image_buffer,
            QR_HW_IMAGE_BYTES
        );


        /* ====================================================================
         * F. STOP Camera AXIS IMMEDIATELY
         *
         * CRITICAL CHANGE:
         *
         * PS QR decoding may take a significant amount of time.
         * Do not allow another physical frame to enter while PS is processing.
         * ================================================================== */

        ov7670_axis_capture_disable();


        xil_printf(
            "[PASS] Camera producer paused for PS processing\r\n"
        );


        /* ====================================================================
         * G. PS full-frame QR decode
         * ================================================================== */

        decode_status =
            qr_decode_frame(
                image_buffer,
                decoded_payload,
                sizeof(decoded_payload),
                &decoded_box
            );


        if (decode_status ==
            QR_DECODE_OK) {

            /*
             * ONLY a successful new QR decode updates last_result.
             */
            strncpy(
                last_result,
                decoded_payload,
                sizeof(last_result) - 1U
            );


            last_result[
                sizeof(last_result) - 1U
            ] = '\0';


            detected =
                1;
        }


        /* ====================================================================
        * H. HDMI image + UI overlay
        *
        * IMPORTANT:
        *
        * QR decode is already complete.
        * Therefore modifying image_buffer here does NOT affect detection.
        * ================================================================== */

        stage6_draw_ui(
            image_buffer,
            detected
        );


        status =
            hdmi_display_show_gray8(
                &hdmi,
                image_buffer
            );


        if (status != XST_SUCCESS) {

            xil_printf(
                "[WARN] HDMI framebuffer update failed\r\n"
            );
        }
        else {

            xil_printf(
                "[PASS] HDMI UI updated\r\n"
            );
        }


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[WARN] HDMI framebuffer update failed\r\n"
            );
        }


        /* ====================================================================
         * I. UART UI
         * ================================================================== */

        xil_printf(
            "\r\n"
            "[FRAME %u]\r\n",
            (unsigned int)frame_count
        );


        xil_printf(
            "PL candidates : %u\r\n",
            (unsigned int)candidate_count
        );


        stage6_print_ui(
            detected
        );


        /* ====================================================================
         * J. Wait Exact-Sync current frame complete
         * ================================================================== */

        status =
            stage6_wait_status_set(
                &csr,
                QR_STATUS_FRAME_COMPLETE_PENDING,
                "FRAME_COMPLETE_PENDING"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        xil_printf(
            "[PASS] FRAME_COMPLETE_PENDING\r\n"
        );


        /* ====================================================================
         * K. ACK CURRENT frame
         *
         * Camera producer is already OFF.
         * ================================================================== */

        qr_csr_pulse(
            &csr,
            QR_CTRL_FRAME_ACK
        );


        /* ====================================================================
         * L. Wait pending flag clear
         * ================================================================== */

        status =
            stage6_wait_status_clear(
                &csr,
                QR_STATUS_FRAME_COMPLETE_PENDING,
                "FRAME_COMPLETE_PENDING"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        xil_printf(
            "[PASS] FRAME_ACK accepted\r\n"
        );


        /* ====================================================================
         * M. Wait Frontend frame release
         *
         * FRAME_COMPLETE_PENDING=0 does NOT necessarily mean the frontend
         * has finished releasing its held frame.
         *
         * Wait until FRONTEND_FRAME_READY goes LOW.
         * ================================================================== */

        status =
            stage6_wait_status_clear(
                &csr,
                QR_STATUS_FRONTEND_FRAME_READY,
                "FRONTEND_FRAME_READY"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        xil_printf(
            "[PASS] Frontend frame released\r\n"
        );


        /* ====================================================================
         * N. Also ensure RESULT_READY from previous frame is gone
         * ================================================================== */

        status =
            stage6_wait_status_clear(
                &csr,
                QR_STATUS_RESULT_READY,
                "RESULT_READY"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        xil_printf(
            "[PASS] Previous result released\r\n"
        );


        /* ====================================================================
         * O. Clear sticky per-frame diagnostics
         *
         * Safe now:
         *
         * - Camera AXIS producer OFF
         * - Current frame released
         * - No next frame active
         * ================================================================== */

        qr_csr_pulse(
            &csr,
            QR_CTRL_ERROR_CLEAR
        );


        usleep(
            100U
        );


        clear_status =
            qr_csr_read(
                &csr,
                QR_CSR_STATUS
            );


        xil_printf(
            "[FRAME %u] Status after ERROR_CLEAR : 0x%08x\r\n",
            (unsigned int)frame_count,
            clear_status
        );


        if ((clear_status &
             (
                 QR_STATUS_COMBINED_ERROR |
                 QR_STATUS_FRAME_STUCK |
                 QR_STATUS_IMAGE_OVERFLOW_ERROR |
                 QR_STATUS_FRAME_ID_PROTOCOL_ERROR
             )) != 0U) {

            xil_printf(
                "[WARN] Sticky runtime error did not fully clear\r\n"
            );
        }
        else {

            xil_printf(
                "[PASS] Per-frame runtime errors cleared\r\n"
            );
        }


        /* ====================================================================
         * P. Arm NEXT Image DMA
         *
         * Camera remains OFF here.
         * ================================================================== */

        status =
            stage6_arm_image_dma(
                &image_dma
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        xil_printf(
            "[PASS] Next Image DMA armed\r\n"
        );


        /* ====================================================================
         * Q. Resume camera LAST
         * ================================================================== */

        ov7670_axis_stat_clear();


        status =
            ov7670_axis_capture_enable();


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[FAIL] Camera AXIS resume\r\n"
            );


            return XST_FAILURE;
        }


        xil_printf(
            "[PASS] Camera producer resumed\r\n"
        );


        /* ====================================================================
         * R. Current frame complete
         * ================================================================== */

        ++frame_count;
    }


    /*
     * Not reached.
     */
    return XST_SUCCESS;
}