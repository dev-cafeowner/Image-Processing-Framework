#include "vision_runtime.h"

#include <string.h>
#include <stdio.h>
#include "xaxivdma_hw.h"

#include "sleep.h"

#include "xaxidma_hw.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xstatus.h"

/* Camera */
#include "ov7670.h"
#include "ov7670_axis_ctrl.h"
#include "camera_control.h"

/* QR / Runtime */
#include "qr_csr.h"
#include "qr_decode.h"
#include "qr_dma.h"
#include "qr_hw_config.h"
#include "qr_perf.h"
#if QR_PINGPONG
#include "frame_receiver.h"
#endif

/* Vision */
#include "vision_frontend.h"

/* Video / HDMI */
#include "video_vdma.h"
#include "hdmi_display.h"
#include "video_pixel_ops.h"
#include "video_overlay.h"
#include "runtime_log.h"
#if QR_PIPELINE_TRACE
#include "qr_pipeline_trace.h"
static qr_pipeline_trace_t pipeline_trace;
static qr_csr_t *pipeline_csr;
static qr_dma_s2mm_t *pipeline_image_dma;
static void runtime_pipeline_observe(void)
{
    u32 id, status;
    if (!pipeline_csr || !pipeline_trace.armed) return;
    id=qr_csr_read(pipeline_csr,QR_CSR_ACTIVE_FRAME_ID);
    status=qr_csr_read(pipeline_csr,QR_CSR_STATUS);
    qr_pipeline_observe(&pipeline_trace,qr_perf_now(),status,id);
    if(pipeline_image_dma && !qr_dma_s2mm_busy(pipeline_image_dma))
        qr_pipeline_image_observe(&pipeline_trace,qr_perf_now(),1);
}
#define PIPE_MARK(event) qr_pipeline_mark(&pipeline_trace,event,qr_perf_now())
#else
#define PIPE_MARK(event) do {} while (0)
#endif
#ifndef QR_WAIT_POLL_US
#define QR_WAIT_POLL_US 1000U
#endif
#if QR_CANDIDATE_AUDIT || QR_PL_GUIDED
#include "qr_candidate_packet.h"
#endif
/* Blocking only during setup; streaming logs use one bounded UART queue. */
#define xil_printf runtime_log_printf


/* ============================================================================
 * Alignment
 * ========================================================================== */

#if defined(__GNUC__)
#define QR_DMA_ALIGNED __attribute__((aligned(64)))
#else
#define QR_DMA_ALIGNED
#endif


/* ============================================================================
 * Runtime constants
 * ========================================================================== */

#define RUNTIME_TIMEOUT_MS               5000U

#define RUNTIME_CAMERA_STARTUP_US        100000U
#define RUNTIME_CAMERA_SETTLE_US         3000000U

#define RUNTIME_CAMERA_OUTER_RETRIES     5U

#define RUNTIME_RESULT_MAX               QR_DECODE_RESULT_MAX

/* Keep errors and one measured summary; omit per-step success chatter. */
#define RUNTIME_VERBOSE 0
#define RUNTIME_TRACE(...) do { if (RUNTIME_VERBOSE) xil_printf(__VA_ARGS__); } while (0)


/* ============================================================================
 * DMA buffers
 * ========================================================================== */

/*
 * Exact-Sync Gray8 image
 *
 * 640 x 480 x 1 byte
 * = 307200 bytes
 */
static u8 image_buffers[2][QR_HW_IMAGE_BYTES] QR_DMA_ALIGNED;
static u32 image_write_slot;


/*
 * QRP1 result packet buffer
 */
static u32 result_buffer[
    QR_HW_QRP1_MAX_WORDS
] QR_DMA_ALIGNED;

#if QR_PL_GUIDED
static qr_candidate_packet_t completed_candidates;
static int completed_candidates_valid;
#endif

#if QR_CANDIDATE_AUDIT
/* Observe only; this diagnostic does not route PL candidates into the decoder.
 * Sampled UART output perturbs timing, so use the preserved ELF for benchmarks. */
static int candidate_audit_sample;
static void runtime_audit_candidates(u32 words, u32 frame, u32 count, const u8 *gray)
{
    static u32 frames, invalid;
    qr_candidate_packet_t packet;
    u32 i;
    int status=qr_candidate_packet_parse(result_buffer, words, frame, count, &packet);
    ++frames;
    invalid+=(status!=QR_PACKET_OK);
    candidate_audit_sample=((frames%30U)==1U);
    if (!candidate_audit_sample) return;
    xil_printf("[PLAUDIT] frame=%lu count=%lu words=%lu check=%d checked=%lu invalid=%lu\r\n",
               frame, count, words, status, frames, invalid);
    if (status!=QR_PACKET_OK) return;
    for(i=0;i<packet.count;++i) {
        const qr_candidate_t *c=&packet.items[i];
        u32 x=c->sum_x/c->hits, y=c->sum_y/c->hits;
        xil_printf("[PLCAND] frame=%lu i=%lu label=%lu hits=%lu xmin=%lu xmax=%lu ymin=%lu ymax=%lu cx=%lu cy=%lu gray=%lu\r\n",
            frame,i,(u32)c->label,(u32)c->hits,(u32)c->min_x,(u32)c->max_x,
            (u32)c->min_y,(u32)c->max_y,x,y,(u32)gray[y*640U+x]);
    }
}
#endif


/*
 * Last successfully decoded QR payload.
 *
 * This is NEVER cleared merely because the current frame
 * does not contain a QR.
 */
static char last_result[
    RUNTIME_RESULT_MAX
];

/* Preview owns separate CPU memory; the completed QR slot remains immutable. */
#define RUNTIME_UI_PANEL_HEIGHT 64U
#if QR_PREVIEW_FUSED || QR_PL_PREVIEW
static u8 preview_gray[HDMI_DISPLAY_WIDTH * RUNTIME_UI_PANEL_HEIGHT] QR_DMA_ALIGNED;
#else
static u8 preview_gray[QR_HW_IMAGE_BYTES] QR_DMA_ALIGNED;
#endif
static video_vdma_s2mm_t *preview_vdma;
static hdmi_display_t *preview_hdmi;
static int preview_qr_detected;
static XTime preview_qr_time;
#if !QR_PL_PREVIEW
static XTime preview_last_present;
#endif
static u32 preview_presented;
static u32 preview_copy_drops;
static u32 preview_errors;
static u64 preview_service_ticks;
static u64 preview_copy_sum_us;
static u32 preview_copy_max_us;
static u32 preview_period_max_us;
static u64 preview_invalidate_us, preview_convert_us, preview_ui_us, preview_commit_us;
static void runtime_preview_service(void);

/* Always count every completed, identity-checked frame, even with UART trace
 * disabled. Windows may be >1s when decode is slow: report measured duration,
 * never assume a fixed interval or equate QR rate with display rate. */
static struct {
    XTime since;
    u32 qr, pass, total_qr, total_pass, previous_preview;
    u32 cycle_max, pl_frames, pl_candidates, runtime_errors, camera_overflows;
    u32 error_or, vdma_error_or;
    u64 cycle_us, qr_us, qr_preview_us, range_us, fill_us, identify_us, payload_us;
    u32 scans;
#if QR_PL_GUIDED
    u32 guided_attempts, guided_pass, geometry_reject, packet_reject;
    u32 fallback_attempts, fallback_pass, fallback_skipped;
    u64 proposal_us, guided_us, fallback_us, roi_pixels;
    u32 early_pass, refine_attempts, refine_pass;
    u32 fallback_early_pass, fallback_refine_attempts, fallback_max_us, qr_max_us;
    u64 fallback_refine_us;
    u64 refine_us;
#endif
} perf_window;

static void runtime_report_window(XTime now, u32 cycle_us, u32 qr_us,
                                 u32 callback_us, int detected, u32 candidates,
                                 u32 runtime_status, u32 errors, u32 camera,
                                 u32 vdma_status)
{
    const qr_decode_profile_t *p = qr_decode_last_profile();
    u32 elapsed, previews;
    ++perf_window.qr;
    ++perf_window.total_qr;
    perf_window.pass += (detected != 0);
    perf_window.total_pass += (detected != 0);
    perf_window.cycle_us += cycle_us;
    if (cycle_us > perf_window.cycle_max) perf_window.cycle_max = cycle_us;
    perf_window.qr_us += qr_us;
    perf_window.qr_preview_us += callback_us;
    perf_window.scans += p->scans;
    perf_window.range_us += p->range_us;
    perf_window.fill_us += p->fill_us;
    perf_window.identify_us += p->identify_us;
    perf_window.payload_us += p->payload_us;
#if QR_PL_GUIDED
    perf_window.guided_attempts += p->guided_attempts;
    perf_window.guided_pass += p->guided_pass;
    perf_window.geometry_reject += p->geometry_reject;
    perf_window.packet_reject += p->packet_reject;
    perf_window.fallback_attempts += p->fallback_attempts;
    perf_window.fallback_pass += p->fallback_pass;
    perf_window.fallback_skipped += p->fallback_skipped;
    perf_window.proposal_us += p->proposal_us;
    perf_window.guided_us += p->guided_us;
    perf_window.fallback_us += p->fallback_us;
    perf_window.roi_pixels += p->roi_pixels;
    perf_window.early_pass += p->early_pass;
    perf_window.refine_attempts += p->refine_attempts;
    perf_window.refine_pass += p->refine_pass;
    perf_window.refine_us += p->refine_us;
    perf_window.fallback_early_pass += p->fallback_early_pass;
    perf_window.fallback_refine_attempts += p->fallback_refine_attempts;
    perf_window.fallback_refine_us += p->fallback_refine_us;
    if(p->fallback_us > perf_window.fallback_max_us) perf_window.fallback_max_us=p->fallback_us;
    if(qr_us > perf_window.qr_max_us) perf_window.qr_max_us=qr_us;
#endif
    perf_window.pl_frames += (candidates != 0U);
    perf_window.pl_candidates += candidates;
    perf_window.runtime_errors += (errors != 0U ||
        (runtime_status & (QR_STATUS_COMBINED_ERROR | QR_STATUS_FRAME_STUCK |
         QR_STATUS_IMAGE_OVERFLOW_ERROR | QR_STATUS_FRAME_ID_PROTOCOL_ERROR)) != 0U);
    perf_window.camera_overflows += ((camera & (1U << 24)) != 0U);
    perf_window.error_or |= errors;
    perf_window.vdma_error_or |= vdma_status &
        (XAXIVDMA_SR_ERR_ALL_MASK | XAXIVDMA_SR_HALTED_MASK);
    elapsed = qr_perf_us(perf_window.since, now);
    if (elapsed < 1000000U) return;
#if QR_PL_PREVIEW
    video_overlay_report(XAxiVdma_GetStatus(&preview_vdma->instance, XAXIVDMA_READ));
#endif
#if QR_CAMERA_SOURCE_SYNC
    camera_control_report();
#endif
    previews = preview_presented - perf_window.previous_preview;
    xil_printf("[SUMMARY] window_us=%lu qr=%lu pass=%lu preview=%lu total_qr=%lu total_pass=%lu total_preview=%lu cycle_avg_us=%lu cycle_max_us=%lu qr_avg_us=%lu qr_preview_avg_us=%lu copy_avg_us=%lu copy_max_us=%lu preview_gap_max_us=%lu drops=%lu display_errors=%lu pl_frames=%lu pl_candidates=%lu runtime_errors=%lu camera_overflows=%lu err=%08lx vdma_err=%08lx\r\n",
        elapsed, perf_window.qr, perf_window.pass, previews,
        perf_window.total_qr, perf_window.total_pass, preview_presented,
        (u32)(perf_window.cycle_us / perf_window.qr), perf_window.cycle_max,
        (u32)(perf_window.qr_us / perf_window.qr),
        (u32)(perf_window.qr_preview_us / perf_window.qr),
        previews ? (u32)(preview_copy_sum_us / previews) : 0U,
        preview_copy_max_us, preview_period_max_us, preview_copy_drops, preview_errors,
        perf_window.pl_frames, perf_window.pl_candidates, perf_window.runtime_errors,
        perf_window.camera_overflows, perf_window.error_or, perf_window.vdma_error_or);
    xil_printf("[DECODE] qr=%lu scans=%lu range_avg_us=%lu fill_avg_us=%lu identify_avg_us=%lu payload_avg_us=%lu log_drops=%lu\r\n",
        perf_window.qr, perf_window.scans,
        (u32)(perf_window.range_us / perf_window.qr),
        (u32)(perf_window.fill_us / perf_window.qr),
        (u32)(perf_window.identify_us / perf_window.qr),
        (u32)(perf_window.payload_us / perf_window.qr), runtime_log_dropped());
#if QR_PL_GUIDED
    xil_printf("[ROUTE] qr=%lu guided_attempts=%lu guided_pass=%lu geometry_reject=%lu packet_reject=%lu fallback_attempts=%lu fallback_pass=%lu fallback_skipped=%lu proposal_avg_us=%lu guided_avg_us=%lu fallback_avg_us=%lu roi_avg_pixels=%lu early_pass=%lu refine_attempts=%lu refine_pass=%lu refine_avg_us=%lu\r\n",
        perf_window.qr, perf_window.guided_attempts, perf_window.guided_pass,
        perf_window.geometry_reject, perf_window.packet_reject,
        perf_window.fallback_attempts, perf_window.fallback_pass, perf_window.fallback_skipped,
        (u32)(perf_window.proposal_us / perf_window.qr),
        perf_window.guided_attempts ? (u32)(perf_window.guided_us / perf_window.guided_attempts) : 0U,
        perf_window.fallback_attempts ? (u32)(perf_window.fallback_us / perf_window.fallback_attempts) : 0U,
        perf_window.guided_attempts ? (u32)(perf_window.roi_pixels / perf_window.guided_attempts) : 0U,
        perf_window.early_pass, perf_window.refine_attempts, perf_window.refine_pass,
        perf_window.refine_attempts ? (u32)(perf_window.refine_us / perf_window.refine_attempts) : 0U);
    xil_printf("[LATENCY] qr=%lu qr_max_us=%lu fallback_max_us=%lu fallback_early_pass=%lu fallback_refine_attempts=%lu fallback_refine_avg_us=%lu\r\n",
        perf_window.qr,perf_window.qr_max_us,perf_window.fallback_max_us,
        perf_window.fallback_early_pass,perf_window.fallback_refine_attempts,
        perf_window.fallback_refine_attempts ? (u32)(perf_window.fallback_refine_us/perf_window.fallback_refine_attempts):0U);
#endif
#if QR_PIPELINE_TRACE
    qr_pipeline_report();
#endif
#if QR_PINGPONG
    frame_receiver_report(Xil_In32(QR_HW_RUNTIME_BASEADDR + QR_CSR_DROP_COUNT));
#endif
    xil_printf("[RENDER] preview=%lu invalidate_avg_us=%lu convert_avg_us=%lu ui_avg_us=%lu commit_avg_us=%lu\r\n",
        previews,
        previews ? (u32)(preview_invalidate_us / previews) : 0U,
        previews ? (u32)(preview_convert_us / previews) : 0U,
        previews ? (u32)(preview_ui_us / previews) : 0U,
        previews ? (u32)(preview_commit_us / previews) : 0U);
    {
        u32 total_qr = perf_window.total_qr, total_pass = perf_window.total_pass;
        memset(&perf_window, 0, sizeof(perf_window));
        perf_window.total_qr = total_qr;
        perf_window.total_pass = total_pass;
        perf_window.previous_preview = preview_presented;
        perf_window.since = now; /* UART cost belongs to the following interval. */
    }
    preview_copy_sum_us = 0U;
    preview_copy_max_us = 0U;
    preview_period_max_us = 0U;
    preview_invalidate_us = preview_convert_us = preview_ui_us = preview_commit_us = 0U;
}


/* ============================================================================
 * Wait AXI DMA S2MM completion
 * ========================================================================== */

static int runtime_wait_dma(
    qr_dma_s2mm_t *dma,
    const char *name
)
{
    XTime wait_started;
    u32 dma_status;


    if ((dma == NULL) ||
        (name == NULL)) {

        return XST_FAILURE;
    }


    wait_started = qr_perf_now();


    while (qr_dma_s2mm_busy(dma)) {
#if QR_PINGPONG
        if (frame_receiver_failed()) return XST_FAILURE;
#endif

        dma_status =
            qr_dma_s2mm_status(
                dma
            );


        if ((dma_status &
             XAXIDMA_ERR_ALL_MASK) != 0U) {

            xil_printf(
                "[FAIL] %s DMA error "
                "SR=0x%08lx\r\n",
                name,
                dma_status
            );


            return XST_FAILURE;
        }


        if (qr_perf_us(wait_started, qr_perf_now()) >=
            RUNTIME_TIMEOUT_MS * 1000U) {

            xil_printf(
                "[FAIL] %s DMA timeout "
                "SR=0x%08lx\r\n",
                name,
                dma_status
            );


            return XST_FAILURE;
        }


        usleep(
            QR_WAIT_POLL_US
        );


        runtime_preview_service();
    }


    dma_status =
        qr_dma_s2mm_status(
            dma
        );


    if ((dma_status &
         XAXIDMA_ERR_ALL_MASK) != 0U) {

        xil_printf(
            "[FAIL] %s DMA final error "
            "SR=0x%08lx\r\n",
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

static int runtime_wait_status_set(
    qr_csr_t *csr,
    u32 mask,
    const char *name
)
{
    XTime wait_started;
    u32 status;


    if ((csr == NULL) ||
        (name == NULL)) {

        return XST_FAILURE;
    }


    wait_started = qr_perf_now();


    for (;;) {

        status =
            qr_csr_read(
                csr,
                QR_CSR_STATUS
            );

#if QR_PIPELINE_TRACE
        runtime_pipeline_observe();
#endif

#if QR_PINGPONG
        if (frame_receiver_failed()) return XST_FAILURE;
#endif
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
                "STATUS      : 0x%08lx\r\n",
                status
            );


            xil_printf(
                "ERROR_FLAGS : 0x%08lx\r\n",
                qr_csr_read(
                    csr,
                    QR_CSR_ERROR_FLAGS
                )
            );


            return XST_FAILURE;
        }


        if (qr_perf_us(wait_started, qr_perf_now()) >=
            RUNTIME_TIMEOUT_MS * 1000U) {

            xil_printf(
                "[FAIL] Timeout waiting %s "
                "STATUS=0x%08lx\r\n",
                name,
                status
            );


            return XST_FAILURE;
        }


        usleep(
            QR_WAIT_POLL_US
        );


        runtime_preview_service();
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

static int runtime_wait_status_clear(
    qr_csr_t *csr,
    u32 mask,
    const char *name
)
{
    XTime wait_started;
    u32 status;


    if ((csr == NULL) ||
        (name == NULL)) {

        return XST_FAILURE;
    }


    wait_started = qr_perf_now();


    for (;;) {

        status =
            qr_csr_read(
                csr,
                QR_CSR_STATUS
            );


        if ((status & mask) == 0U) {

            return XST_SUCCESS;
        }


        if (qr_perf_us(wait_started, qr_perf_now()) >=
            RUNTIME_TIMEOUT_MS * 1000U) {

            xil_printf(
                "[FAIL] Timeout clearing %s "
                "STATUS=0x%08lx\r\n",
                name,
                status
            );


            return XST_FAILURE;
        }


        usleep(
            QR_WAIT_POLL_US
        );


        runtime_preview_service();
    }
}


/* ============================================================================
 * Arm Gray8 Image DMA
 * ========================================================================== */

#if !QR_PINGPONG
static int runtime_arm_image_dma(
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
        (INTPTR)image_buffers[image_write_slot],
        QR_HW_IMAGE_BYTES
    );


    Xil_DCacheInvalidateRange(
        (INTPTR)image_buffers[image_write_slot],
        QR_HW_IMAGE_BYTES
    );


    status =
        qr_dma_s2mm_arm(
            image_dma,
            (UINTPTR)image_buffers[image_write_slot],
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


#endif
/* ============================================================================
 * Camera complete initialization
 *
 * SCCB is still intermittent.
 * Therefore retry the entire camera initialization sequence.
 * ========================================================================== */

static int runtime_prepare_camera(
    ov7670_t *camera
)
{
    u32 attempt;

    u8 pid;
    u8 ver;
    u8 clock_readback, pll_readback;

    int status;


    if (camera == NULL) {

        return XST_FAILURE;
    }


#if QR_CAMERA_SOURCE_SYNC
    if (camera_control_check() != XST_SUCCESS) return XST_FAILURE;
#endif
    pid = 0U;
    ver = 0U;


    for (attempt = 1U;
         attempt <= RUNTIME_CAMERA_OUTER_RETRIES;
         ++attempt) {

        xil_printf(
            "[CAMERA] setup attempt %u/%u\r\n",
            (unsigned int)attempt,
            (unsigned int)RUNTIME_CAMERA_OUTER_RETRIES
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
            RUNTIME_CAMERA_STARTUP_US
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

            if (ov7670_read_reg(camera, OV7670_REG_CLKRC, &clock_readback) != XST_SUCCESS ||
                clock_readback != (u8)QR_HW_OV7670_CLKRC_BRINGUP ||
                ov7670_read_reg(camera, 0x6BU, &pll_readback) != XST_SUCCESS) {
                xil_printf("[WARN] Camera clock readback failed; retrying setup\r\n");
                continue;
            }
#if QR_CAMERA_SOURCE_SYNC
            if (camera_control_sensor_check(camera) != XST_SUCCESS) return XST_FAILURE;
            xil_printf("[CAMERA CLOCK] CLKRC=%02x DBLV=%02x XCLK_HZ=24000000 source_sync=1 FCLK0_HZ=62500000\r\n",
                       clock_readback, pll_readback);
#else
            xil_printf("[CAMERA CLOCK] CLKRC=%02x DBLV=%02x XCLK_DIV=2 FCLK0_HZ=62500000\r\n",
                       clock_readback, pll_readback);
#endif
            if ((pll_readback & 0xC0U) != 0U) {
                xil_printf("[FAIL] Camera PLL multiplier violates the validated PCLK profile\r\n");
                return XST_FAILURE;
            }

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

#define RUNTIME_UI_WIDTH              640U
#define RUNTIME_UI_HEIGHT             RUNTIME_UI_PANEL_HEIGHT

#define RUNTIME_UI_FONT_WIDTH         5U
#define RUNTIME_UI_FONT_HEIGHT        7U

#define RUNTIME_UI_FONT_SCALE         2U


#define RUNTIME_UI_BG                 0U
#define RUNTIME_UI_FG                 255U


/* ============================================================================
 * 5x7 character bitmap
 *
 * bit4 = left pixel
 * bit0 = right pixel
 * ========================================================================== */

static void runtime_font5x7(
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

static void runtime_fill_rect(
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

        if ((y + py) >= RUNTIME_UI_HEIGHT) {
            break;
        }


        for (px = 0U; px < width; ++px) {

            if ((x + px) >= RUNTIME_UI_WIDTH) {
                break;
            }


            image[
                ((y + py) * RUNTIME_UI_WIDTH)
                + (x + px)
            ] = value;
        }
    }
}


/* ============================================================================
 * Draw one character
 * ========================================================================== */

static void runtime_draw_char(
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


    runtime_font5x7(
        c,
        rows
    );


    for (row = 0U;
         row < RUNTIME_UI_FONT_HEIGHT;
         ++row) {

        for (col = 0U;
             col < RUNTIME_UI_FONT_WIDTH;
             ++col) {

            if ((rows[row] &
                 (1U << (4U - col))) == 0U) {

                continue;
            }


            for (sy = 0U;
                 sy < RUNTIME_UI_FONT_SCALE;
                 ++sy) {

                for (sx = 0U;
                     sx < RUNTIME_UI_FONT_SCALE;
                     ++sx) {

                    u32 px;
                    u32 py;


                    px =
                        x +
                        (col * RUNTIME_UI_FONT_SCALE) +
                        sx;


                    py =
                        y +
                        (row * RUNTIME_UI_FONT_SCALE) +
                        sy;


                    if ((px < RUNTIME_UI_WIDTH) &&
                        (py < RUNTIME_UI_HEIGHT)) {

                        image[
                            (py * RUNTIME_UI_WIDTH) +
                            px
                        ] = RUNTIME_UI_FG;
                    }
                }
            }
        }
    }
}


/* ============================================================================
 * Draw string
 * ========================================================================== */

static void runtime_draw_text(
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
            RUNTIME_UI_FONT_WIDTH *
            RUNTIME_UI_FONT_SCALE
        ) +
        RUNTIME_UI_FONT_SCALE;


    while (*text != '\0') {

        if ((cursor_x +
             (
                 RUNTIME_UI_FONT_WIDTH *
                 RUNTIME_UI_FONT_SCALE
             )) >= RUNTIME_UI_WIDTH) {

            break;
        }


        runtime_draw_char(
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

static void runtime_draw_ui(
    u8 *image,
    int detected
)
{
    /*
     * Black banner over camera image.
     */
    runtime_fill_rect(
        image,
        0U,
        0U,
        RUNTIME_UI_WIDTH,
        RUNTIME_UI_PANEL_HEIGHT,
        RUNTIME_UI_BG
    );


    /*
     * Line 1
     */
    runtime_draw_text(
        image,
        12U,
        8U,
        "LAST QR:"
    );


    if (detected != 0) {

        runtime_draw_text(
            image,
            108U,
            8U,
            "PASS"
        );
    }
    else {

        runtime_draw_text(
            image,
            108U,
            8U,
            "MISS"
        );
    }


    /* Preview is newer than the last analyzed snapshot: label its age. */
    {
        char age[32];
        u32 age_ms = preview_qr_time ?
            (u32)(((qr_perf_now() - preview_qr_time) * 1000ULL) / (COUNTS_PER_SECOND)) : 0U;
        if (preview_qr_time)
            snprintf(age, sizeof(age), "AGE: %uMS", (unsigned int)age_ms);
        else
            snprintf(age, sizeof(age), "AGE: --");
        runtime_draw_text(image, 240U, 8U, age);
    }

    /*
     * Line 2
     */
    runtime_draw_text(
        image,
        12U,
        36U,
        "LAST:"
    );


    if (last_result[0] != '\0') {

        runtime_draw_text(
            image,
            108U,
            36U,
            last_result
        );
    }
    else {

        runtime_draw_text(
            image,
            108U,
            36U,
            "--"
        );
    }
}

/* Called during hardware waits and QR row scans. Capture uses a four-slot ring;
 * conservatively reject even a one-slot writer advance during the CPU copy. */
static void runtime_preview_service(void)
{
#if QR_PINGPONG
    frame_receiver_service();
#endif
#if QR_PIPELINE_TRACE
    runtime_pipeline_observe();
#endif
#if QR_PL_PREVIEW
    XTime started, finished;
    int submitted;
    static XTime last_update;
    runtime_log_service();
    if (!preview_vdma || !preview_hdmi) return;
    started = qr_perf_now();
    if (last_update && qr_perf_us(last_update, started) < 100000U) return;
    if ((video_vdma_s2mm_status(preview_vdma) |
         XAxiVdma_GetStatus(&preview_vdma->instance, XAXIVDMA_READ)) &
        (XAXIVDMA_SR_ERR_ALL_MASK | XAXIVDMA_SR_HALTED_MASK)) {
        if (preview_errors++ == 0U) xil_printf("[WARN] Autonomous video DMA error\r\n");
        last_update = started;
        return;
    }
    if (!video_overlay_ready()) return;
    runtime_draw_ui(preview_gray, preview_qr_detected);
    submitted = video_overlay_submit(preview_gray);
    if (submitted != XST_SUCCESS) ++preview_errors;
    finished = qr_perf_now();
    if (submitted == XST_SUCCESS) video_overlay_cpu_time(qr_perf_us(started, finished));
    last_update = finished;
    preview_service_ticks += finished-started;
    // No CPU video submissions: SUMMARY preview stays zero in this mode.
    // VIDEO camera_sof / scan_sof and HUD updates are separately measured.
#else
    u32 index, writer, copy_us, period_us;
#if !QR_PREVIEW_FUSED
    u32 pixel;
#else
    u8 *destination;
#endif
    XTime started, presented, invalidated, converted, ui_done;
    int available;
    const u8 *source;
    runtime_log_service();
    if (!preview_vdma || !preview_hdmi) return;
    available = video_vdma_latest_complete(preview_vdma, &index, &writer);
    if (available < 0) {
        if (preview_errors++ == 0U)
            xil_printf("[WARN] Preview DMA status=%08lx\r\n",
                       video_vdma_s2mm_status(preview_vdma));
        return;
    }
    if (!available) return;

    started = qr_perf_now();
#if QR_PREVIEW_FUSED
    destination = hdmi_display_begin_frame(preview_hdmi);
    if (!destination) { ++preview_errors; return; }
#endif
    source = (const u8 *)video_vdma_frame_addr(index);
    Xil_DCacheInvalidateRange((INTPTR)source, VIDEO_VDMA_FRAME_BYTES);
    invalidated = qr_perf_now();
    /* Existing RGB565 -> RGB888 converter stores B, G, R in DDR byte order. */
#if QR_PREVIEW_FUSED
    /* The opaque HUD replaces the first rows; do not convert hidden pixels. */
    video_bgr888_to_gray_rgb888(
        destination + RUNTIME_UI_PANEL_HEIGHT * HDMI_DISPLAY_STRIDE,
        source + RUNTIME_UI_PANEL_HEIGHT * VIDEO_VDMA_STRIDE,
        HDMI_DISPLAY_WIDTH * (HDMI_DISPLAY_HEIGHT - RUNTIME_UI_PANEL_HEIGHT));
#else
    for (pixel = 0U; pixel < QR_HW_IMAGE_BYTES; ++pixel) {
        preview_gray[pixel] = (u8)((29U * source[pixel * 3U] +
            150U * source[pixel * 3U + 1U] +
            77U * source[pixel * 3U + 2U]) >> 8);
    }
#endif
    converted = qr_perf_now();
    if (writer != XAxiVdma_CurrFrameStore(&preview_vdma->instance, XAXIVDMA_WRITE) ||
        (video_vdma_s2mm_status(preview_vdma) & XAXIVDMA_SR_ERR_ALL_MASK)) {
        ++preview_copy_drops;
#if QR_PREVIEW_FUSED
        hdmi_display_cancel_frame(preview_hdmi);
#endif
        preview_service_ticks += qr_perf_now() - started;
        return;
    }
    runtime_draw_ui(preview_gray, preview_qr_detected);
#if QR_PREVIEW_FUSED
    video_gray8_to_rgb888(destination, preview_gray,
                         HDMI_DISPLAY_WIDTH * RUNTIME_UI_PANEL_HEIGHT);
    ui_done = qr_perf_now();
    if (hdmi_display_commit_frame(preview_hdmi) != XST_SUCCESS) {
#else
    ui_done = qr_perf_now();
    if (hdmi_display_show_gray8(preview_hdmi, preview_gray) != XST_SUCCESS) {
#endif
        ++preview_errors;
        xil_printf("[WARN] Preview display submission failed\r\n");
        preview_service_ticks += qr_perf_now() - started;
        return;
    }
    presented = qr_perf_now();
    ++preview_presented;
    copy_us = qr_perf_us(started, presented);
    period_us = preview_last_present ? qr_perf_us(preview_last_present, presented) : 0U;
    preview_copy_sum_us += copy_us;
    preview_invalidate_us += qr_perf_us(started, invalidated);
    preview_convert_us += qr_perf_us(invalidated, converted);
    preview_ui_us += qr_perf_us(converted, ui_done);
    preview_commit_us += qr_perf_us(ui_done, presented);
    if (copy_us > preview_copy_max_us) preview_copy_max_us = copy_us;
    if (period_us > preview_period_max_us) preview_period_max_us = period_us;
    if (QR_PER_FRAME_LOGS) xil_printf("[PREVIEW] n=%lu period_us=%lu copy_us=%lu drops=%lu errors=%lu\r\n",
               preview_presented,
               period_us, copy_us, preview_copy_drops, preview_errors);
    preview_last_present = presented;
    preview_service_ticks += qr_perf_now() - started;
#endif
}

static void runtime_print_ui(
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
 * Runtime
 *
 * Continuous QR runtime
 * ========================================================================== */

int vision_runtime_run(void)
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
    u32 status_before_ack, errors_before_ack, camera_before_clear;
    XTime perf_cycle, perf_capture, perf_qr_start, perf_qr_end, perf_display_end, perf_end;
    u64 perf_preview_before, perf_preview_during;
    u32 stuck_frames = 0U;
    u8 *completed_image;
    u32 active_id, image_id, fe_config, skipped_frames;


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
    image_write_slot = 0U;
#if QR_PERF_BLANK_TEST
    status = video_pixel_ops_self_test();
    xil_printf("[PIXEL TEST] result=%d neon=%d colors=16777216\r\n",
               status, video_pixel_ops_uses_neon());
    if (status != 0) return XST_FAILURE;
#endif


    last_result[0] =
        '\0';


    xil_printf(
        "\r\n"
        "========================================\r\n"
        " Runtime Continuous QR Runtime\r\n"
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
     * OV7670 configuration before starting memory/video traffic
     * ====================================================================== */

    status =
        runtime_prepare_camera(
            &camera
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


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


    xil_printf(
        "Camera exposure settle 3000 ms...\r\n"
    );


    usleep(
        RUNTIME_CAMERA_SETTLE_US
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

#if QR_PINGPONG
    status = frame_receiver_init(&image_dma, &image_buffers[0][0], QR_HW_IMAGE_BYTES);
#else
    status = runtime_arm_image_dma(&image_dma);
#endif


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
        "Runtime CTRL : 0x%08lx\r\n",
        qr_csr_read(
            &csr,
            QR_CSR_CONTROL
        )
    );


    /* ========================================================================
     * 13. Camera AXIS producer ON LAST
     * ====================================================================== */

#if QR_CAMERA_SOURCE_SYNC
    if (camera_control_validate_input() != XST_SUCCESS) return XST_FAILURE;
#endif
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


    preview_vdma = &video_vdma;
    preview_hdmi = &hdmi;
    runtime_log_set_async(1);
    memset(&perf_window, 0, sizeof(perf_window));
    perf_window.since = qr_perf_now();
#if QR_CAMERA_SOURCE_SYNC
#if QR_CAMERA_CLEAN_PCLK
    xil_printf("[BUILD] vision_app pl_preview=1 source_sync=1 clean_pclk=1 camera_clkrc=%lu colorbars=%lu; VIDEO scan_sof includes repeats\r\n", (u32)QR_CAMERA_CLKRC, (u32)QR_CAMERA_COLORBARS);
#else
    xil_printf("[BUILD] vision_app pl_preview=1 source_sync=1 camera_clkrc=%lu colorbars=%lu; VIDEO scan_sof includes repeats\r\n", (u32)QR_CAMERA_CLKRC, (u32)QR_CAMERA_COLORBARS);
#endif
#elif QR_PL_PREVIEW
    xil_printf("[BUILD] vision_app pl_preview=1 camera_clkrc=%lu; SUMMARY preview=CPU submissions (0); VIDEO scan_sof includes repeats\r\n", (u32)QR_CAMERA_CLKRC);
#else
    xil_printf("[BUILD] vision_app fused_preview=%lu per_frame_logs=%lu camera_clkrc=%lu neon=%d\r\n",
               (u32)QR_PREVIEW_FUSED, (u32)QR_PER_FRAME_LOGS, (u32)QR_CAMERA_CLKRC,
               video_pixel_ops_uses_neon());
#endif
    qr_decode_set_progress_callback(runtime_preview_service);
#if QR_PIPELINE_TRACE
    pipeline_csr=&csr;
    pipeline_image_dma=&image_dma;
    memset(&pipeline_trace,0,sizeof(pipeline_trace));
    xil_printf("[BUILD PIPE] observer=PS poll_us=%lu; timestamps are first observations, not PL edges\r\n",(u32)QR_WAIT_POLL_US);
#endif
    perf_cycle = qr_perf_now();

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
            runtime_wait_status_set(
                &csr,
                QR_STATUS_RESULT_READY,
                "RESULT_READY"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        /* Both processing paths now share the accepted camera SOF.
         * Disabling future snapshot SOFs does not abort the active image.
         * Keep the camera/RGB888 preview running while software decodes. */
#if !QR_PINGPONG
        qr_csr_set_persistent(&csr,
            QR_CTRL_PERSISTENT_DEFAULT & ~QR_CTRL_IMAGE_CAPTURE_ENABLE);
#endif

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
         * QRP1 must always be drained. QR_PL_GUIDED additionally validates
         * and copies the records before rearming this DMA buffer.
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

        PIPE_MARK(QR_PIPE_STREAM);
        qr_csr_pulse(
            &csr,
            QR_CTRL_STREAM_START
        );


        /* ====================================================================
         * D. Wait Result DMA
         * ================================================================== */

        status =
            runtime_wait_dma(
                &result_dma,
                "Result"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        PIPE_MARK(QR_PIPE_RDMA);
        Xil_DCacheInvalidateRange(
            (INTPTR)result_buffer,
            result_bytes
        );


        /* ====================================================================
         * E. Wait Exact Gray8 Image DMA
         * ================================================================== */

#if QR_PINGPONG
        // The hardware result is dispatched only after this frame's image EOF.
        // The receiver may already be DMA-writing the OTHER slot by now.
        status = frame_receiver_take(qr_csr_read(&csr, QR_CSR_IMAGE_FRAME_ID), &completed_image);
#else
        status = runtime_wait_dma(&image_dma, "Image");
#endif


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        /*
         * DMA -> CPU ownership.
         */
        PIPE_MARK(QR_PIPE_IDMA);
#if !QR_PINGPONG
        completed_image = image_buffers[image_write_slot];
#endif
        Xil_DCacheInvalidateRange(
            (INTPTR)completed_image,
            QR_HW_IMAGE_BYTES
        );


        /* Snapshot is complete; camera and preview are deliberately still ON. */
        perf_capture = qr_perf_now();
        PIPE_MARK(QR_PIPE_CACHE);

        /* Release the PL-held frame immediately after both DMAs finish.
         * The CPU owns completed_image; the next DMA will use the OTHER slot.
         * Never re-arm DMA onto memory still being decoded. */
        /* ====================================================================
         * J. Wait Exact-Sync current frame complete
         * ================================================================== */

        status =
            runtime_wait_status_set(
                &csr,
                QR_STATUS_FRAME_COMPLETE_PENDING,
                "FRAME_COMPLETE_PENDING"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        RUNTIME_TRACE(
            "[PASS] FRAME_COMPLETE_PENDING\r\n"
        );


        /* ====================================================================
         * K. ACK CURRENT frame
         *
         * Future Gray8 snapshot SOFs are disabled; preview stays ON.
         * ================================================================== */

        status_before_ack = qr_csr_read(&csr, QR_CSR_STATUS);
        errors_before_ack = qr_csr_read(&csr, QR_CSR_ERROR_FLAGS);
        camera_before_clear = ov7670_axis_read_cam_status();
        active_id = qr_csr_read(&csr, QR_CSR_ACTIVE_FRAME_ID);
        image_id = qr_csr_read(&csr, QR_CSR_IMAGE_FRAME_ID);
        fe_config = qr_csr_read(&csr, QR_CSR_FE_CONFIG);
        skipped_frames = qr_csr_read(&csr, QR_CSR_DROP_COUNT);
        if (active_id != image_id || result_buffer[0] != 0x51525031U ||
            result_buffer[2] != image_id) {
            xil_printf("[FAIL] Frame identity mismatch active=%lu image=%lu packet=%lu magic=%08lx\r\n",
                       active_id, image_id, result_buffer[2], result_buffer[0]);
            return XST_FAILURE;
        }
#if QR_PL_GUIDED
        /* Copy before ACK/rearm: result_buffer will belong to the next DMA. */
        completed_candidates_valid = qr_candidate_packet_parse(result_buffer,
            result_words, image_id, candidate_count, &completed_candidates) == QR_PACKET_OK;
        if (errors_before_ack || (status_before_ack & (QR_STATUS_COMBINED_ERROR |
            QR_STATUS_FRAME_STUCK | QR_STATUS_IMAGE_OVERFLOW_ERROR |
            QR_STATUS_FRAME_ID_PROTOCOL_ERROR))) completed_candidates_valid = 0;
#endif
#if QR_CANDIDATE_AUDIT
        runtime_audit_candidates(result_words, image_id, candidate_count, completed_image);
#endif
        if (status_before_ack & QR_STATUS_FRAME_STUCK) {
            if (stuck_frames++ == 0U)
                xil_printf("[NOTICE] PL frame watchdog exceeded; recorded before ACK/clear\r\n");
        }
        PIPE_MARK(QR_PIPE_ACK);
        qr_csr_pulse(
            &csr,
            QR_CTRL_FRAME_ACK
        );


        /* ====================================================================
         * L. Wait pending flag clear
         * ================================================================== */

        status =
            runtime_wait_status_clear(
                &csr,
                QR_STATUS_FRAME_COMPLETE_PENDING,
                "FRAME_COMPLETE_PENDING"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        RUNTIME_TRACE(
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
            runtime_wait_status_clear(
                &csr,
                QR_STATUS_FRONTEND_FRAME_READY,
                "FRONTEND_FRAME_READY"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        RUNTIME_TRACE(
            "[PASS] Frontend frame released\r\n"
        );


        /* ====================================================================
         * N. Also ensure RESULT_READY from previous frame is gone
         * ================================================================== */

        status =
            runtime_wait_status_clear(
                &csr,
                QR_STATUS_RESULT_READY,
                "RESULT_READY"
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        RUNTIME_TRACE(
            "[PASS] Previous result released\r\n"
        );
        PIPE_MARK(QR_PIPE_RELEASE);


        /* ====================================================================
         * O. Clear sticky per-frame diagnostics
         *
         * Safe now:
         *
         * - Future Gray8 snapshot SOFs disabled
         * - Current frame released
         * - No next frame active
         * ================================================================== */

#if !QR_PINGPONG
        qr_csr_pulse(&csr, QR_CTRL_ERROR_CLEAR);
        usleep(100U);
#endif


        clear_status =
            qr_csr_read(
                &csr,
                QR_CSR_STATUS
            );


        RUNTIME_TRACE(
            "[FRAME %u] Status after ERROR_CLEAR : 0x%08lx\r\n",
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

            RUNTIME_TRACE(
                "[PASS] Per-frame runtime errors cleared\r\n"
            );
        }



        /* Capture frame N+1 while CPU decodes immutable frame N. The tap's
         * in-flight reservation blocks any further SOF until the next ACK. */
#if QR_PINGPONG
        if (frame_receiver_failed()) return XST_FAILURE;
        // Old consumer is fully released. Grant one new descriptor, independent
        // of physical capture credit; never let a new result mask release checks.
        frame_receiver_dispatch();
#else
        image_write_slot ^= 1U;
        status = runtime_arm_image_dma(&image_dma);
        if (status != XST_SUCCESS) return status;
        qr_csr_set_persistent(&csr, QR_CTRL_PERSISTENT_DEFAULT);
#endif

#if QR_PIPELINE_TRACE
        {
            XTime next_arm=qr_perf_now();
            qr_pipeline_accumulate(&pipeline_trace,next_arm,image_id);
            qr_pipeline_arm(&pipeline_trace,next_arm,image_id);
        }
#endif
        /* ====================================================================
         * G. PS QR decode: optional same-frame PL-guided Geometry/ROI route
         * ================================================================== */

#if QR_PERF_BLANK_TEST
        /* Diagnostic-only input injection; never modify the preview buffer. */
        if (frame_count >= 5U && frame_count <= 7U) {
            memset(completed_image, 255, QR_HW_IMAGE_BYTES);
            xil_printf("[TEST] White QR snapshot n=%lu; live preview unchanged\r\n", frame_count);
        }
#endif
#if QR_PINGPONG_STALL_TEST
        if(frame_count>=5U && frame_count<=7U) {
            u32 before=2166136261U,after=2166136261U,p;
            XTime stall_start;
            for(p=0;p<QR_HW_IMAGE_BYTES;p++) before=(before^completed_image[p])*16777619U;
            stall_start=qr_perf_now();
            while(qr_perf_us(stall_start,qr_perf_now())<120000U) {
                runtime_preview_service(); usleep(100U);
            }
            // Discard cached lines so a forbidden DMA overwrite cannot hide.
            Xil_DCacheInvalidateRange((INTPTR)completed_image,QR_HW_IMAGE_BYTES);
            for(p=0;p<QR_HW_IMAGE_BYTES;p++) after=(after^completed_image[p])*16777619U;
            xil_printf("[TEST QPP1] id=%lu hold_us=120000 before=%08lx after=%08lx intact=%lu\r\n",
                       image_id,before,after,(u32)(before==after));
            if(before!=after || frame_receiver_failed()) return XST_FAILURE;
        }
#endif
        perf_qr_start = qr_perf_now();
#if QR_CAMERA_COLORBARS
        camera_control_pattern_report(completed_image, frame_count);
#endif
        perf_preview_before = preview_service_ticks;
#if QR_PL_GUIDED
#if QR_FALLBACK_TEST
        if(frame_count%60U==5U && completed_candidates_valid && completed_candidates.count>=3U) {
            completed_candidates.count=2;
            xil_printf("[TEST FALLBACK] frame=%lu forced_count=2\r\n",image_id);
        }
#endif
        decode_status = qr_decode_guided_frame(completed_image,
            completed_candidates_valid ? &completed_candidates : NULL,
            image_id, decoded_payload, sizeof(decoded_payload), &decoded_box);
#else
        decode_status =
            qr_decode_frame(
                completed_image,
                decoded_payload,
                sizeof(decoded_payload),
                &decoded_box
            );
#endif
        perf_qr_end = qr_perf_now();
#if QR_PINGPONG
        if (frame_receiver_release() != XST_SUCCESS) return XST_FAILURE;
#endif
        perf_preview_during = preview_service_ticks - perf_preview_before;
#if QR_CANDIDATE_AUDIT
        if (candidate_audit_sample) qr_decode_audit_finders(image_id, decode_status);
#endif


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


        preview_qr_detected = detected;
        preview_qr_time = perf_qr_end;
        runtime_preview_service();
        perf_display_end = qr_perf_now();

        /* ====================================================================
         * I. UART UI
         * ================================================================== */

        RUNTIME_TRACE(
            "\r\n"
            "[FRAME %u]\r\n",
            (unsigned int)frame_count
        );


        RUNTIME_TRACE(
            "PL candidates : %u\r\n",
            (unsigned int)candidate_count
        );


        if (RUNTIME_VERBOSE) runtime_print_ui(detected);


        /* ====================================================================
         * R. Current frame complete
         * ================================================================== */

        perf_end = qr_perf_now();
        if (QR_PER_FRAME_LOGS) xil_printf("[SYNC] n=%lu id=%lu image=%lu fe=%08lx skipped=%lu\r\n",
                   frame_count, active_id, image_id, fe_config, skipped_frames);
        if (QR_PER_FRAME_LOGS) xil_printf("[PERF] n=%lu ok=%lu wait_us=%lu qr_us=%lu display_us=%lu cpu_hold_us=%lu cycle_us=%lu status=%08lx err=%08lx cam=%08lx vdma=%08lx\r\n",
                   frame_count, (u32)detected,
                   qr_perf_us(perf_cycle, perf_capture),
                   qr_perf_us(perf_qr_start, perf_qr_end),
                   qr_perf_us(perf_qr_end, perf_display_end),
                   qr_perf_us(perf_capture, perf_end),
                   qr_perf_us(perf_cycle, perf_end),
                   status_before_ack, errors_before_ack, camera_before_clear,
                   video_vdma_s2mm_status(&video_vdma));
        runtime_report_window(perf_end, qr_perf_us(perf_cycle, perf_end),
            qr_perf_us(perf_qr_start, perf_qr_end), qr_perf_us(0, perf_preview_during),
            detected, candidate_count, status_before_ack, errors_before_ack,
            camera_before_clear, video_vdma_s2mm_status(&video_vdma));
        perf_cycle = perf_end;
        ++frame_count;
    }


    /*
     * Not reached.
     */
    return XST_SUCCESS;
}
