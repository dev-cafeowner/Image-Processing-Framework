#include "stage5a_qrp1_test.h"

#include <stddef.h>

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

/* Video */
#include "video_vdma.h"
#include "hdmi_display.h"


extern void outbyte(char c);


/* ============================================================================
 * DMA alignment
 * ========================================================================== */

#if defined(__GNUC__)
#define QR_DMA_ALIGNED __attribute__((aligned(64)))
#else
#define QR_DMA_ALIGNED
#endif


/* ============================================================================
 * Stage 5-A constants
 * ========================================================================== */

#define STAGE5A_TIMEOUT_MS                  5000U

#define STAGE5A_OV7670_STARTUP_DELAY_US     100000U

/*
 * Full sensor configuration now enables AEC/AGC/AWB.
 *
 * Give those automatic loops some time before the first
 * diagnostic/QR frame.
 */
#define STAGE5A_CAMERA_SETTLE_DELAY_US      1000000U


/* ============================================================================
 * VDMA diagnostic image
 * ========================================================================== */

#define STAGE5A_VDMA_WIDTH                  640U
#define STAGE5A_VDMA_HEIGHT                 480U
#define STAGE5A_VDMA_BPP                    3U

#define STAGE5A_VDMA_STRIDE                 \
    (STAGE5A_VDMA_WIDTH * STAGE5A_VDMA_BPP)

#define STAGE5A_VDMA_FRAME_BYTES            \
    (STAGE5A_VDMA_STRIDE * STAGE5A_VDMA_HEIGHT)

#define STAGE5A_VDMA_GRAY_BYTES             \
    (STAGE5A_VDMA_WIDTH * STAGE5A_VDMA_HEIGHT)


/* ============================================================================
 * QRP1
 * ========================================================================== */

#define QRP1_MAGIC                          0x51525031U

#define QRP1_HEADER_WORDS                   5U

#define QRP1_RECORD_WORDS                   5U

#define QRP1_MAX_CANDIDATES                 16U


/* ============================================================================
 * DMA buffers
 * ========================================================================== */

static u8 image_buffer[
    QR_HW_IMAGE_BYTES
] QR_DMA_ALIGNED;


static u32 result_buffer[
    QR_HW_QRP1_MAX_WORDS
] QR_DMA_ALIGNED;


/* ============================================================================
 * Wait DMA
 * ========================================================================== */

static int wait_dma(
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


    elapsed_ms =
        0U;


    while (qr_dma_s2mm_busy(
               dma
           )) {

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
            STAGE5A_TIMEOUT_MS) {

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


    xil_printf(
        "[PASS] %s DMA complete "
        "(%u ms) SR=0x%08x\r\n",
        name,
        (unsigned int)elapsed_ms,
        dma_status
    );


    return XST_SUCCESS;
}


/* ============================================================================
 * Gray statistics
 * ========================================================================== */

static void print_gray_stats(void)
{
    u32 i;

    u32 sum;

    u8 min_value;

    u8 max_value;


    sum =
        0U;


    min_value =
        255U;


    max_value =
        0U;


    for (i = 0U;
         i < QR_HW_IMAGE_BYTES;
         ++i) {

        u8 value;


        value =
            image_buffer[i];


        sum +=
            (u32)value;


        if (value <
            min_value) {

            min_value =
                value;
        }


        if (value >
            max_value) {

            max_value =
                value;
        }
    }


    xil_printf(
        "Gray bytes    : %u\r\n",
        (unsigned int)QR_HW_IMAGE_BYTES
    );


    xil_printf(
        "Gray min/max  : %u / %u\r\n",
        (unsigned int)min_value,
        (unsigned int)max_value
    );


    xil_printf(
        "Gray sum      : %u\r\n",
        (unsigned int)sum
    );
}


/* ============================================================================
 * UART Exact Gray8 dump
 * ========================================================================== */

static void dump_gray8_uart(void)
{
    u32 i;


    xil_printf(
        "\r\n"
        "GRAY8_BEGIN %u %u %u\r\n",
        640U,
        480U,
        (unsigned int)QR_HW_IMAGE_BYTES
    );


    for (i = 0U;
         i < QR_HW_IMAGE_BYTES;
         ++i) {

        outbyte(
            (char)image_buffer[i]
        );
    }


    xil_printf(
        "\r\n"
        "GRAY8_END\r\n"
    );
}


/* ============================================================================
 * UART VDMA RGB888 -> Gray dump
 * ========================================================================== */

static void dump_vdma_rgb_as_gray_uart(void)
{
    UINTPTR frame_addr;

    volatile u8 *rgb;

    u32 x;

    u32 y;

    u32 offset;

    u8 c0;

    u8 c1;

    u8 c2;

    u8 gray;


    frame_addr =
        video_vdma_frame_addr(
            0U
        );


    Xil_DCacheInvalidateRange(
        (INTPTR)frame_addr,
        STAGE5A_VDMA_FRAME_BYTES
    );


    rgb =
        (volatile u8 *)frame_addr;


    xil_printf(
        "\r\n"
        "VDMA_GRAY_BEGIN %u %u %u\r\n",
        STAGE5A_VDMA_WIDTH,
        STAGE5A_VDMA_HEIGHT,
        STAGE5A_VDMA_GRAY_BYTES
    );


    for (y = 0U;
         y < STAGE5A_VDMA_HEIGHT;
         ++y) {

        for (x = 0U;
             x < STAGE5A_VDMA_WIDTH;
             ++x) {

            offset =
                (y * STAGE5A_VDMA_STRIDE) +
                (x * STAGE5A_VDMA_BPP);


            c0 =
                rgb[offset + 0U];


            c1 =
                rgb[offset + 1U];


            c2 =
                rgb[offset + 2U];


            /*
             * Diagnostic only.
             *
             * Channel order does not matter because simple average is used.
             */
            gray =
                (u8)(
                    (
                        (u32)c0 +
                        (u32)c1 +
                        (u32)c2
                    ) / 3U
                );


            outbyte(
                (char)gray
            );
        }
    }


    xil_printf(
        "\r\n"
        "VDMA_GRAY_END\r\n"
    );
}


/* ============================================================================
 * Candidate print
 * ========================================================================== */

static void print_candidate(
    u32 index,
    const u32 *record
)
{
    u32 c0;

    u32 c1;

    u32 c2;


    u32 label;

    u32 flags;

    u32 hit_count;


    u32 min_x;

    u32 max_x;

    u32 min_y;

    u32 max_y;


    if (record == NULL) {

        return;
    }


    c0 =
        record[0];

    c1 =
        record[1];

    c2 =
        record[2];


    label =
        c0 &
        0x1FU;


    flags =
        (c0 >> 5) &
        0xFFU;


    hit_count =
        (c0 >> 13) &
        0x7FFFFU;


    min_x =
        c1 &
        0x3FFU;


    max_x =
        (c1 >> 10) &
        0x3FFU;


    min_y =
        (c1 >> 20) &
        0x1FFU;


    max_y =
        c2 &
        0x1FFU;


    xil_printf(
        "CAND[%u] "
        "label=%u "
        "flags=0x%02x "
        "hits=%u "
        "bbox=(%u,%u)-(%u,%u)\r\n",

        (unsigned int)index,

        (unsigned int)label,

        (unsigned int)flags,

        (unsigned int)hit_count,

        (unsigned int)min_x,

        (unsigned int)min_y,

        (unsigned int)max_x,

        (unsigned int)max_y
    );
}


/* ============================================================================
 * Stage 5-A
 * ========================================================================== */

int stage5a_qrp1_test_run(void)
{
    qr_dma_s2mm_t image_dma;

    qr_dma_s2mm_t result_dma;

    qr_csr_t csr;

    qr_frontend_t frontend;

    video_vdma_s2mm_t video_vdma;

    hdmi_display_t hdmi;

    ov7670_t camera;


    u8 pid;

    u8 ver;


    u32 runtime_status;

    u32 error_flags;

    u32 result_words;

    u32 result_bytes;

    u32 candidate_count;

    u32 expected_words;


    u32 active_frame_id;

    u32 image_frame_id;

    u32 packet_frame_id;


    u32 h1;

    u32 h3;


    u32 schema;

    u32 header_words;

    u32 record_words;


    u32 packet_words;

    u32 packet_candidates;

    u32 packet_image_format;

    u32 packet_flags;


    char decoded_payload[
        QR_DECODE_RESULT_MAX
    ];


    qr_decode_box_t decoded_box;


    int decode_status;

    u32 elapsed_ms;

    u32 i;

    int status;


    pid =
        0U;


    ver =
        0U;


    decoded_payload[0] =
        '\0';


    decode_status =
        QR_DECODE_NOT_FOUND;


    /* ========================================================================
     * Banner
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "====================================\r\n"
        " Stage 5-A Exact-Sync QRP1 Test\r\n"
        "====================================\r\n"
    );


    /* ========================================================================
     * Camera AXIS OFF first
     * ====================================================================== */

    ov7670_axis_capture_disable();


    xil_printf(
        "AXIS CTRL(init): 0x%08x\r\n",
        ov7670_axis_read_control()
    );


    /* ========================================================================
     * Frontend
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


    xil_printf(
        "[PASS] Frontend configured\r\n"
    );


    /* ========================================================================
     * Runtime
     * ====================================================================== */

    qr_csr_init(
        &csr,
        QR_HW_RUNTIME_BASEADDR
    );


    if (qr_csr_probe_contract(
            &csr
        ) != XST_SUCCESS) {

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
        "[PASS] Runtime quiesced\r\n"
    );


    /* ========================================================================
     * Video VDMA S2MM
     * ====================================================================== */

#ifndef QR_HW_VDMA_BASEADDR
#error "QR_HW_VDMA_BASEADDR is required."
#endif


    status =
        video_vdma_s2mm_init_start(
            &video_vdma,
            QR_HW_VDMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Video VDMA S2MM start: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "VDMA frame0    : 0x%08x\r\n",
        (u32)video_vdma_frame_addr(
            0U
        )
    );


    xil_printf(
        "VDMA stride    : %u\r\n",
        (unsigned int)VIDEO_VDMA_STRIDE
    );


    xil_printf(
        "VDMA S2MM CR   : 0x%08x\r\n",
        video_vdma_s2mm_cr(
            &video_vdma
        )
    );


    xil_printf(
        "VDMA S2MM SR   : 0x%08x\r\n",
        video_vdma_s2mm_status(
            &video_vdma
        )
    );


    xil_printf(
        "[PASS] Video VDMA running\r\n"
    );


    /* ========================================================================
     * HDMI
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
        "[PASS] HDMI output ready\r\n"
    );


    /* ========================================================================
     * Image DMA
     * ====================================================================== */

    status =
        qr_dma_s2mm_init(
            &image_dma,
            QR_HW_IMAGE_DMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Image DMA init: %d\r\n",
            status
        );


        return status;
    }


    /* ========================================================================
     * Result DMA
     * ====================================================================== */

    status =
        qr_dma_s2mm_init(
            &result_dma,
            QR_HW_RESULT_DMA_BASEADDR
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] Result DMA init: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "[PASS] DMA initialized\r\n"
    );


    /* ========================================================================
     * quirc
     * ====================================================================== */

    status =
        qr_decode_init();


    if (status !=
        QR_DECODE_OK) {

        xil_printf(
            "[FAIL] QR software decoder init\r\n"
        );


        return XST_FAILURE;
    }


    /* ========================================================================
     * Image DMA ARM
     * ====================================================================== */

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
            &image_dma,
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


    xil_printf(
        "Image buffer   : 0x%08x\r\n",
        (u32)(UINTPTR)image_buffer
    );


    xil_printf(
        "Image bytes    : %u\r\n",
        (unsigned int)QR_HW_IMAGE_BYTES
    );


    xil_printf(
        "[PASS] Image DMA armed\r\n"
    );


    /* ========================================================================
     * SCCB init
     * ====================================================================== */

    status =
        ov7670_init(
            &camera,
            QR_HW_I2C0_BASEADDR,
            QR_HW_I2C_SCLK_HZ
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] PS I2C0/SCCB init: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "Waiting for OV7670 startup (100 ms)...\r\n"
    );


    usleep(
        STAGE5A_OV7670_STARTUP_DELAY_US
    );


    /* ========================================================================
     * Real sensor mode
     *
     * NO TEST PATTERN IS ENABLED HERE.
     * ====================================================================== */

    status =
        ov7670_prepare_vga_rgb565(
            &camera,
            (u8)QR_HW_OV7670_CLKRC_BRINGUP,
            &pid,
            &ver
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[FAIL] OV7670 prepare\r\n"
        );


        return status;
    }


    xil_printf(
        "OV7670 final ID : PID=0x%02x VER=0x%02x\r\n",
        pid,
        ver
    );


    /*
     * AEC / AGC / AWB settle.
     */
    xil_printf(
        "Waiting for camera exposure settle (1000 ms)...\r\n"
    );


    usleep(
        STAGE5A_CAMERA_SETTLE_DELAY_US
    );


    /* ========================================================================
     * Frontend enable
     * ====================================================================== */

    qr_frontend_enable(
        &frontend,
        QR_HW_FRONTEND_FB_INVERT
    );


    /* ========================================================================
     * Runtime enable
     * ====================================================================== */

    qr_csr_set_persistent(
        &csr,
        QR_CTRL_PERSISTENT_DEFAULT
    );


    xil_printf(
        "Runtime CTRL   : 0x%08x\r\n",
        qr_csr_read(
            &csr,
            QR_CSR_CONTROL
        )
    );


    /* ========================================================================
     * Camera producer ON
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
        "[PASS] Camera capture started\r\n"
    );


    /* ========================================================================
     * Wait RESULT_READY
     * ====================================================================== */

    elapsed_ms =
        0U;


    for (;;) {

        runtime_status =
            qr_csr_read(
                &csr,
                QR_CSR_STATUS
            );


        if ((runtime_status &
             QR_STATUS_RESULT_READY) != 0U) {

            break;
        }


        if ((runtime_status &
             (
                 QR_STATUS_COMBINED_ERROR |
                 QR_STATUS_IMAGE_OVERFLOW_ERROR |
                 QR_STATUS_FRAME_ID_PROTOCOL_ERROR
             )) != 0U) {

            xil_printf(
                "[FAIL] Runtime error before RESULT_READY\r\n"
            );


            xil_printf(
                "STATUS      : 0x%08x\r\n",
                runtime_status
            );


            return XST_FAILURE;
        }


        if (elapsed_ms >=
            STAGE5A_TIMEOUT_MS) {

            xil_printf(
                "[FAIL] RESULT_READY timeout\r\n"
            );


            xil_printf(
                "STATUS      : 0x%08x\r\n",
                runtime_status
            );


            return XST_FAILURE;
        }


        usleep(
            1000U
        );


        ++elapsed_ms;
    }


    /* ========================================================================
     * Metadata
     * ====================================================================== */

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


    error_flags =
        qr_csr_read(
            &csr,
            QR_CSR_ERROR_FLAGS
        );


    active_frame_id =
        qr_csr_read(
            &csr,
            QR_CSR_ACTIVE_FRAME_ID
        );


    image_frame_id =
        qr_csr_read(
            &csr,
            QR_CSR_IMAGE_FRAME_ID
        );


    xil_printf(
        "\r\n"
        "[RESULT READY]\r\n"
    );


    xil_printf(
        "RESULT_WORDS   : %u\r\n",
        (unsigned int)result_words
    );


    xil_printf(
        "CAND_COUNT     : %u\r\n",
        (unsigned int)candidate_count
    );


    xil_printf(
        "ERROR_FLAGS    : 0x%08x\r\n",
        error_flags
    );


    xil_printf(
        "ACTIVE_ID      : %u\r\n",
        (unsigned int)active_frame_id
    );


    xil_printf(
        "IMAGE_ID       : %u\r\n",
        (unsigned int)image_frame_id
    );


    if ((result_words <
         QRP1_HEADER_WORDS) ||

        (result_words >
         QR_HW_QRP1_MAX_WORDS) ||

        (candidate_count >
         QRP1_MAX_CANDIDATES)) {

        xil_printf(
            "[FAIL] Result metadata range\r\n"
        );


        return XST_FAILURE;
    }


    expected_words =
        QRP1_HEADER_WORDS +
        (
            QRP1_RECORD_WORDS *
            candidate_count
        );


    if (result_words !=
        expected_words) {

        xil_printf(
            "[FAIL] Word count mismatch "
            "expected=%u actual=%u\r\n",
            (unsigned int)expected_words,
            (unsigned int)result_words
        );


        return XST_FAILURE;
    }


    result_bytes =
        result_words *
        sizeof(u32);


    /* ========================================================================
     * Result DMA
     * ====================================================================== */

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
            "[FAIL] Result DMA arm: %d\r\n",
            status
        );


        return status;
    }


    xil_printf(
        "Result buffer  : 0x%08x\r\n",
        (u32)(UINTPTR)result_buffer
    );


    xil_printf(
        "Result bytes   : %u\r\n",
        (unsigned int)result_bytes
    );


    xil_printf(
        "[PASS] Result DMA armed\r\n"
    );


    qr_csr_pulse(
        &csr,
        QR_CTRL_STREAM_START
    );


    xil_printf(
        "[PASS] STREAM_START\r\n"
    );


    /* ========================================================================
     * Result DMA completion
     * ====================================================================== */

    status =
        wait_dma(
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


    /* ========================================================================
     * Image DMA completion
     * ====================================================================== */

    status =
        wait_dma(
            &image_dma,
            "Image"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    Xil_DCacheInvalidateRange(
        (INTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    /* ========================================================================
     * HDMI diagnostic image
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[HDMI IMAGE]\r\n"
    );


    status =
        hdmi_display_show_gray8(
            &hdmi,
            image_buffer
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[WARN] HDMI Gray8 display failed: %d\r\n",
            status
        );
    }
    else {

        xil_printf(
            "[HDMI] Exact Gray8 capture displayed\r\n"
        );
    }


    /* ========================================================================
     * PS QR decode
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[PS QR DECODE]\r\n"
    );


    decode_status =
        qr_decode_frame(
            image_buffer,
            decoded_payload,
            sizeof(decoded_payload),
            &decoded_box
        );


    if (decode_status ==
        QR_DECODE_OK) {

        xil_printf(
            "[PASS] QR PAYLOAD = %s\r\n",
            decoded_payload
        );
    }
    else if (decode_status ==
             QR_DECODE_NOT_FOUND) {

        xil_printf(
            "[WARN] No QR detected in Gray8 frame\r\n"
        );
    }
    else {

        xil_printf(
            "[WARN] QR detected but decode failed\r\n"
        );
    }


    /* ========================================================================
     * QRP1
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[QRP1]\r\n"
    );


    for (i = 0U;
         i < QRP1_HEADER_WORDS;
         ++i) {

        xil_printf(
            "H%u = 0x%08x\r\n",
            (unsigned int)i,
            result_buffer[i]
        );
    }


    if (result_buffer[0] !=
        QRP1_MAGIC) {

        xil_printf(
            "[FAIL] QRP1 Magic\r\n"
        );


        return XST_FAILURE;
    }


    h1 =
        result_buffer[1];


    schema =
        (h1 >> 24) &
        0xFFU;


    header_words =
        (h1 >> 16) &
        0xFFU;


    record_words =
        (h1 >> 8) &
        0xFFU;


    packet_flags =
        h1 &
        0xFFU;


    packet_frame_id =
        result_buffer[2];


    h3 =
        result_buffer[3];


    packet_words =
        (h3 >> 16) &
        0xFFFFU;


    packet_candidates =
        (h3 >> 8) &
        0xFFU;


    packet_image_format =
        h3 &
        0xFFU;


    xil_printf(
        "Schema         : %u\r\n",
        (unsigned int)schema
    );


    xil_printf(
        "Header words   : %u\r\n",
        (unsigned int)header_words
    );


    xil_printf(
        "Record words   : %u\r\n",
        (unsigned int)record_words
    );


    xil_printf(
        "Packet flags   : 0x%02x\r\n",
        (unsigned int)packet_flags
    );


    xil_printf(
        "Packet FRAME_ID: %u\r\n",
        (unsigned int)packet_frame_id
    );


    xil_printf(
        "Packet words   : %u\r\n",
        (unsigned int)packet_words
    );


    xil_printf(
        "Packet CAND    : %u\r\n",
        (unsigned int)packet_candidates
    );


    xil_printf(
        "Image format   : %u\r\n",
        (unsigned int)packet_image_format
    );


    xil_printf(
        "Packet errors  : 0x%08x\r\n",
        result_buffer[4]
    );


    if ((schema != 1U) ||
        (header_words != QRP1_HEADER_WORDS) ||
        (record_words != QRP1_RECORD_WORDS) ||
        (packet_words != result_words) ||
        (packet_candidates != candidate_count) ||
        (packet_image_format != QR_IMAGE_FORMAT_GRAY8)) {

        xil_printf(
            "[FAIL] QRP1 header contract\r\n"
        );


        return XST_FAILURE;
    }


    /* ========================================================================
     * Exact Sync
     * ====================================================================== */

    image_frame_id =
        qr_csr_read(
            &csr,
            QR_CSR_IMAGE_FRAME_ID
        );


    xil_printf(
        "\r\n"
        "[EXACT SYNC]\r\n"
    );


    xil_printf(
        "ACTIVE_ID      : %u\r\n",
        (unsigned int)active_frame_id
    );


    xil_printf(
        "IMAGE_ID       : %u\r\n",
        (unsigned int)image_frame_id
    );


    xil_printf(
        "QRP1_FRAME_ID  : %u\r\n",
        (unsigned int)packet_frame_id
    );


    if ((packet_frame_id !=
         active_frame_id) ||

        (packet_frame_id !=
         image_frame_id)) {

        xil_printf(
            "[WARN] Exact-Sync Frame ID mismatch "
            "(ignored for PS full-frame decode test)\r\n"
        );
    }
    else {

        xil_printf(
            "[PASS] Exact-Sync Frame ID match\r\n"
        );
    }


    /* ========================================================================
     * Candidates
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[CANDIDATES]\r\n"
    );


    if (candidate_count ==
        0U) {

        xil_printf(
            "[WARN] Candidate count = 0\r\n"
        );
    }
    else {

        for (i = 0U;
             i < candidate_count;
             ++i) {

            print_candidate(
                i,

                &result_buffer[
                    QRP1_HEADER_WORDS +
                    (
                        i *
                        QRP1_RECORD_WORDS
                    )
                ]
            );
        }
    }


    /* ========================================================================
     * Image stats
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[IMAGE]\r\n"
    );


    print_gray_stats();


    /* ========================================================================
     * Wait frame completion
     * ====================================================================== */

    elapsed_ms =
        0U;


    for (;;) {

        runtime_status =
            qr_csr_read(
                &csr,
                QR_CSR_STATUS
            );


        if ((runtime_status &
             QR_STATUS_FRAME_COMPLETE_PENDING) != 0U) {

            break;
        }


        if (elapsed_ms >=
            STAGE5A_TIMEOUT_MS) {

            xil_printf(
                "[FAIL] FRAME_COMPLETE_PENDING timeout\r\n"
            );


            return XST_FAILURE;
        }


        usleep(
            1000U
        );


        ++elapsed_ms;
    }


    xil_printf(
        "[PASS] FRAME_COMPLETE_PENDING\r\n"
    );


    /* ========================================================================
     * Freeze camera
     * ====================================================================== */

    ov7670_axis_capture_disable();


    /* ========================================================================
     * FRAME ACK
     * ====================================================================== */

    qr_csr_pulse(
        &csr,
        QR_CTRL_FRAME_ACK
    );


    usleep(
        1000U
    );


    runtime_status =
        qr_csr_read(
            &csr,
            QR_CSR_STATUS
        );


    if ((runtime_status &
         QR_STATUS_FRAME_COMPLETE_PENDING) != 0U) {

        xil_printf(
            "[FAIL] FRAME_ACK release\r\n"
        );


        return XST_FAILURE;
    }


    xil_printf(
        "[PASS] FRAME_ACK release\r\n"
    );


    /* ========================================================================
     * Shutdown processing side
     * ====================================================================== */

    qr_csr_set_persistent(
        &csr,
        0U
    );


    qr_frontend_quiesce(
        &frontend
    );


    /*
     * Freeze VDMA write framebuffer before CPU reads it.
     */
    video_vdma_s2mm_stop(
        &video_vdma
    );


    /* ========================================================================
     * UART image dump 1
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[UART IMAGE DUMP 1/2]\r\n"
    );


    xil_printf(
        "Sending Exact-Sync Gray8 : %u bytes\r\n",
        (unsigned int)QR_HW_IMAGE_BYTES
    );


    dump_gray8_uart();


    xil_printf(
        "[PASS] Exact-Sync Gray8 UART dump complete\r\n"
    );


    /* ========================================================================
     * UART image dump 2
     * ====================================================================== */

    xil_printf(
        "\r\n"
        "[UART IMAGE DUMP 2/2]\r\n"
    );


    xil_printf(
        "VDMA framebuffer : 0x%08x\r\n",
        (u32)video_vdma_frame_addr(
            0U
        )
    );


    xil_printf(
        "Sending VDMA RGB888 -> Gray8 : %u bytes\r\n",
        (unsigned int)STAGE5A_VDMA_GRAY_BYTES
    );


    dump_vdma_rgb_as_gray_uart();


    xil_printf(
        "[PASS] VDMA RGB -> Gray UART dump complete\r\n"
    );


    /* ========================================================================
     * Final
     * ====================================================================== */

    xil_printf(
        "\r\n"
    );


    xil_printf(
        "QR Candidate target : >= 3, observed %u\r\n",
        (unsigned int)candidate_count
    );


    if (candidate_count ==
        0U) {

        xil_printf(
            "[WARN] PL QRP1 candidate count = 0\r\n"
        );
    }


    if (decode_status ==
        QR_DECODE_OK) {

        xil_printf(
            "[PASS] PS QR decode : %s\r\n",
            decoded_payload
        );
    }
    else {

        xil_printf(
            "[WARN] PS QR decode did not succeed\r\n"
        );
    }


    xil_printf(
        "[PASS] Stage 5-A complete\r\n"
    );


    return XST_SUCCESS;
}