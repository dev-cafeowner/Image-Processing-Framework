#include "image_capture_test.h"

#include <stddef.h>

#include "sleep.h"
#include "xaxidma_hw.h"
#include "xaxivdma_hw.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

#include "ov7670.h"
#include "ov7670_axis_ctrl.h"

#include "qr_csr.h"
#include "qr_dma.h"
#include "qr_hw_config.h"
#include "vision_frontend.h"
#include "video_vdma.h"


#if defined(__GNUC__)
#define QR_DMA_ALIGNED __attribute__((aligned(64)))
#else
#define QR_DMA_ALIGNED
#endif


#define IMAGE_CAPTURE_TIMEOUT_MS 3000U


static u8 image_buffer[QR_HW_IMAGE_BYTES] QR_DMA_ALIGNED;


/* ============================================================
 * Gray8 DDR result statistics
 * ============================================================ */
static void print_gray_stats(void)
{
    u32 i;
    u32 sum = 0U;
    u8 min_value = 255U;
    u8 max_value = 0U;

    for (i = 0U; i < QR_HW_IMAGE_BYTES; ++i) {

        const u8 value = image_buffer[i];

        sum += (u32)value;

        if (value < min_value) {
            min_value = value;
        }

        if (value > max_value) {
            max_value = value;
        }
    }

    xil_printf("Gray bytes   : %u\r\n",
               (unsigned int)QR_HW_IMAGE_BYTES);

    xil_printf("Gray min/max : %u / %u\r\n",
               (unsigned int)min_value,
               (unsigned int)max_value);

    xil_printf("Gray sum     : %u\r\n",
               (unsigned int)sum);

    xil_printf("First 32     : ");

    for (i = 0U; i < 32U; ++i) {

        xil_printf("%02x%s",
                   image_buffer[i],
                   ((i & 0x0FU) == 0x0FU)
                       ? "\r\n               "
                       : " ");
    }

    xil_printf("\r\n");
}


/* ============================================================
 * Image capture test
 *
 * OV7670
 *   -> RGB565 AXI4-Stream
 *   -> Gray8 Tap
 *   -> Image DMA S2MM
 *   -> DDR
 *
 * IMPORTANT START ORDER
 *
 *  1. OV7670 AXIS OFF
 *  2. Frontend / Runtime configure
 *  3. VDMA start
 *  4. Image DMA arm
 *  5. Camera SCCB configure
 *  6. Frontend + Runtime capture enable
 *  7. OV7670 AXIS ON
 *
 * This guarantees that the first AXI SOF cannot arrive before
 * the Gray8/Frontend frame path is ready.
 * ============================================================ */
int image_capture_test_run(void)
{
    qr_dma_s2mm_t image_dma;
    qr_csr_t csr;
    qr_frontend_t frontend;
    video_vdma_s2mm_t video_vdma;
    ov7670_t camera;

    u8 pid = 0U;
    u8 ver = 0U;

    u32 elapsed_ms = 0U;
    u32 dma_status;
    u32 runtime_status;
    u32 axis_control;

    int status;


    xil_printf("\r\n");
    xil_printf("====================================\r\n");
    xil_printf(" Image capture test Camera -> Gray8 DMA Test\r\n");
    xil_printf("====================================\r\n");


    /* ========================================================
     * 0. Force OV7670 AXIS source OFF first
     *
     * ARM processor reset does not necessarily reset PL AXI
     * registers, so do not assume capture_en == 0.
     * ======================================================== */
    ov7670_axis_capture_disable();

    axis_control = ov7670_axis_read_control();

    xil_printf("AXIS CTRL(init): 0x%08x\r\n",
               axis_control);

    if ((axis_control & 0x00000001U) != 0U) {

        xil_printf("[FAIL] OV7670 AXIS did not disable\r\n");

        return XST_FAILURE;
    }

    xil_printf("[PASS] OV7670 AXIS disabled\r\n");


    /* ========================================================
     * 1. Vision Frontend initialize / configure
     * ======================================================== */
    qr_frontend_init(&frontend,
                     QR_HW_FRONTEND_BASEADDR);

    if (qr_frontend_probe(&frontend) != XST_SUCCESS) {

        xil_printf("[FAIL] Frontend VERSION\r\n");

        return XST_FAILURE;
    }


    qr_frontend_quiesce(&frontend);

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


    xil_printf("[PASS] Frontend quiesced/configured\r\n");


    /* ========================================================
     * 2. Runtime initialize / quiesce
     * ======================================================== */
    qr_csr_init(
        &csr,
        QR_HW_RUNTIME_BASEADDR
    );


    if (qr_csr_probe_contract(&csr) != XST_SUCCESS) {

        xil_printf("[FAIL] Runtime CSR contract\r\n");

        return XST_FAILURE;
    }


    /*
     * Disable all persistent runtime functions while DMA and
     * camera are being prepared.
     */
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


    xil_printf("[PASS] Runtime quiesced\r\n");


#ifndef QR_HW_VDMA_BASEADDR
#error "QR_HW_VDMA_BASEADDR is required for Image capture test broadcaster bring-up."
#endif


    /* ========================================================
     * 3. Start existing video VDMA path
     *
     * Broadcaster has another consumer on the normal video
     * branch. Keep this branch running so that it cannot
     * backpressure the camera stream.
     * ======================================================== */
    status = video_vdma_s2mm_init_start(
        &video_vdma,
        QR_HW_VDMA_BASEADDR
    );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] Video VDMA S2MM start: %d\r\n",
            status
        );

        xil_printf(
            "VDMA S2MM CR : 0x%08x\r\n",
            video_vdma_s2mm_cr(&video_vdma)
        );

        xil_printf(
            "VDMA S2MM SR : 0x%08x\r\n",
            video_vdma_s2mm_status(&video_vdma)
        );

        return status;
    }


    xil_printf(
        "VDMA frame0   : 0x%08x\r\n",
        (u32)video_vdma_frame_addr(0U)
    );


    xil_printf(
        "VDMA stride   : %u\r\n",
        (unsigned int)VIDEO_VDMA_STRIDE
    );


    xil_printf(
        "VDMA S2MM CR : 0x%08x\r\n",
        video_vdma_s2mm_cr(&video_vdma)
    );


    xil_printf(
        "VDMA S2MM SR : 0x%08x\r\n",
        video_vdma_s2mm_status(&video_vdma)
    );


    xil_printf("[PASS] Video VDMA S2MM running\r\n");


    /* ========================================================
     * 4. Image DMA initialize
     * ======================================================== */
    status = qr_dma_s2mm_init(
        &image_dma,
        QR_HW_IMAGE_DMA_BASEADDR
    );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] Image DMA init: %d\r\n",
            status
        );

        return status;
    }


    /*
     * Prepare DDR destination buffer before S2MM starts.
     */
    Xil_DCacheFlushRange(
        (INTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    Xil_DCacheInvalidateRange(
        (INTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    /* ========================================================
     * 5. ARM Image DMA BEFORE starting camera stream
     * ======================================================== */
    status = qr_dma_s2mm_arm(
        &image_dma,
        (UINTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] Image DMA arm: %d\r\n",
            status
        );

        return status;
    }


    xil_printf(
        "Image buffer : 0x%08x\r\n",
        (u32)(UINTPTR)image_buffer
    );


    xil_printf(
        "Image bytes  : %u\r\n",
        (unsigned int)QR_HW_IMAGE_BYTES
    );


    xil_printf("[PASS] Image DMA armed\r\n");


    /* ========================================================
     * 6. OV7670 SCCB / sensor configuration
     *
     * AXI stream source is still disabled here.
     * ======================================================== */
    status = ov7670_init(
        &camera,
        QR_HW_I2C0_BASEADDR,
        QR_HW_I2C_SCLK_HZ
    );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] PS I2C0/SCCB init: %d\r\n",
            status
        );

        return status;
    }


    status = ov7670_probe(
        &camera,
        &pid,
        &ver
    );


    xil_printf(
        "OV7670 ID    : PID=0x%02x VER=0x%02x\r\n",
        pid,
        ver
    );


    if (status != XST_SUCCESS) {

        xil_printf("[FAIL] OV7670 probe\r\n");

        return status;
    }


    status = ov7670_configure_vga_rgb565(
        &camera,
        (u8)QR_HW_OV7670_CLKRC_BRINGUP
    );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] OV7670 VGA/RGB565 config\r\n"
        );

        return status;
    }


    xil_printf(
        "[PASS] OV7670 VGA/RGB565 baseline\r\n"
    );


    /* ========================================================
     * 7. Enable downstream consumers FIRST
     *
     * Frontend and Runtime/Gray8 capture are made ready before
     * the OV7670 AXIS producer can emit the first SOF.
     * ======================================================== */

    /*
     * Frontend enable.
     */
    qr_frontend_enable(
        &frontend,
        QR_HW_FRONTEND_FB_INVERT
    );


    /*
     * Runtime:
     *
     * ENABLE
     * IMAGE_CAPTURE_ENABLE
     * AUTO_START_ENABLE
     *
     * Current contract default = 0x000000A1.
     */
    qr_csr_set_persistent(
        &csr,
        QR_CTRL_PERSISTENT_DEFAULT
    );


    xil_printf("[PASS] Capture enabled\r\n");


    xil_printf(
        "Runtime CTRL : 0x%08x\r\n",
        qr_csr_read(&csr, QR_CSR_CONTROL)
    );


    /*
     * Sanity check:
     * bit0 = ENABLE
     * bit5 = IMAGE_CAPTURE_ENABLE
     */
    if ((qr_csr_read(&csr, QR_CSR_CONTROL)
         & (QR_CTRL_ENABLE | QR_CTRL_IMAGE_CAPTURE_ENABLE))
        != (QR_CTRL_ENABLE | QR_CTRL_IMAGE_CAPTURE_ENABLE)) {

        xil_printf(
            "[FAIL] Runtime image capture not enabled\r\n"
        );

        return XST_FAILURE;
    }


    /* ========================================================
     * 8. Clear AXIS statistics before starting producer
     * ======================================================== */
    ov7670_axis_stat_clear();


    /* ========================================================
     * 9. Start OV7670 AXI producer LAST
     *
     * First new SOF after this point should see:
     *
     * capture_enable        = 1
     * frame_slot_available  = 1
     * s_axis_tuser          = 1
     *
     * and produce frame_sof_accept.
     * ======================================================== */
    status = ov7670_axis_capture_enable();


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] OV7670 AXIS capture enable\r\n"
        );

        xil_printf(
            "AXIS CTRL     : 0x%08x\r\n",
            ov7670_axis_read_control()
        );

        return XST_FAILURE;
    }


    xil_printf(
        "AXIS CTRL     : 0x%08x\r\n",
        ov7670_axis_read_control()
    );


    xil_printf(
        "AXIS CAM STAT : 0x%08x\r\n",
        ov7670_axis_read_cam_status()
    );


    xil_printf(
        "AXIS FIFO STAT: 0x%08x\r\n",
        ov7670_axis_read_fifo_status()
    );


    xil_printf(
        "AXIS VERSION  : 0x%08x\r\n",
        ov7670_axis_read_version()
    );


    xil_printf(
        "[PASS] OV7670 AXIS capture enabled\r\n"
    );


    /* ========================================================
     * 10. Wait for one full Gray8 image DMA transfer
     * ======================================================== */
    while (qr_dma_s2mm_busy(&image_dma)) {

        dma_status =
            qr_dma_s2mm_status(&image_dma);


        if ((dma_status & XAXIDMA_ERR_ALL_MASK) != 0U) {

            xil_printf(
                "[FAIL] Image DMA error, SR=0x%08x\r\n",
                dma_status
            );

            return XST_FAILURE;
        }


        if (elapsed_ms >= IMAGE_CAPTURE_TIMEOUT_MS) {

            runtime_status =
                qr_csr_read(&csr, QR_CSR_STATUS);


            xil_printf(
                "[FAIL] Image DMA timeout\r\n"
            );


            xil_printf(
                "DMA SR       : 0x%08x\r\n",
                dma_status
            );


            xil_printf(
                "VDMA CR      : 0x%08x\r\n",
                video_vdma_s2mm_cr(&video_vdma)
            );


            xil_printf(
                "VDMA SR      : 0x%08x\r\n",
                video_vdma_s2mm_status(&video_vdma)
            );


            xil_printf(
                "Runtime CTRL : 0x%08x\r\n",
                qr_csr_read(&csr, QR_CSR_CONTROL)
            );


            xil_printf(
                "Runtime STAT : 0x%08x\r\n",
                runtime_status
            );


            xil_printf(
                "ACTIVE_ID    : %u\r\n",
                (unsigned int)
                qr_csr_read(
                    &csr,
                    QR_CSR_ACTIVE_FRAME_ID
                )
            );


            xil_printf(
                "IMAGE_ID     : %u\r\n",
                (unsigned int)
                qr_csr_read(
                    &csr,
                    QR_CSR_IMAGE_FRAME_ID
                )
            );


            xil_printf(
                "AXIS CTRL    : 0x%08x\r\n",
                ov7670_axis_read_control()
            );


            xil_printf(
                "AXIS CAM STAT: 0x%08x\r\n",
                ov7670_axis_read_cam_status()
            );


            xil_printf(
                "AXIS FIFO    : 0x%08x\r\n",
                ov7670_axis_read_fifo_status()
            );


            return XST_FAILURE;
        }


        usleep(1000U);
        ++elapsed_ms;
    }


    /* ========================================================
     * 11. DMA finished - check final status
     * ======================================================== */
    dma_status =
        qr_dma_s2mm_status(&image_dma);


    if ((dma_status & XAXIDMA_ERR_ALL_MASK) != 0U) {

        xil_printf(
            "[FAIL] Image DMA completed with error, SR=0x%08x\r\n",
            dma_status
        );

        return XST_FAILURE;
    }


    /* ========================================================
     * 12. DMA wrote DDR -> invalidate ARM cache
     * ======================================================== */
    Xil_DCacheInvalidateRange(
        (INTPTR)image_buffer,
        QR_HW_IMAGE_BYTES
    );


    runtime_status =
        qr_csr_read(&csr, QR_CSR_STATUS);


    /* ========================================================
     * 13. Print final state
     * ======================================================== */
    xil_printf(
        "DMA complete : %u ms\r\n",
        (unsigned int)elapsed_ms
    );


    xil_printf(
        "DMA SR       : 0x%08x\r\n",
        dma_status
    );


    xil_printf(
        "VDMA CR      : 0x%08x\r\n",
        video_vdma_s2mm_cr(&video_vdma)
    );


    xil_printf(
        "VDMA SR      : 0x%08x\r\n",
        video_vdma_s2mm_status(&video_vdma)
    );


    xil_printf(
        "Runtime CTRL : 0x%08x\r\n",
        qr_csr_read(&csr, QR_CSR_CONTROL)
    );


    xil_printf(
        "Runtime STAT : 0x%08x\r\n",
        runtime_status
    );


    xil_printf(
        "ACTIVE_ID    : %u\r\n",
        (unsigned int)
        qr_csr_read(
            &csr,
            QR_CSR_ACTIVE_FRAME_ID
        )
    );


    xil_printf(
        "IMAGE_ID     : %u\r\n",
        (unsigned int)
        qr_csr_read(
            &csr,
            QR_CSR_IMAGE_FRAME_ID
        )
    );


    xil_printf(
        "AXIS CTRL    : 0x%08x\r\n",
        ov7670_axis_read_control()
    );


    print_gray_stats();


    xil_printf(
        "[PASS] Image capture test complete\r\n"
    );


    return XST_SUCCESS;
}