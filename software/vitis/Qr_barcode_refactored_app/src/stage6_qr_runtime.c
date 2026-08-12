#include "stage6_qr_runtime.h"

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
#include "qr_app_ui.h"
#include "qr_camera.h"

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

#define STAGE6_CAMERA_SETTLE_US         3000000U




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


    qr_app_ui_init();


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
        qr_camera_prepare(
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
             * Only a successful new QR decode updates
             * the persistent application result.
             */
            qr_app_ui_set_result(
                decoded_payload
            );


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

        qr_app_ui_draw(
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


        qr_app_ui_print(
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