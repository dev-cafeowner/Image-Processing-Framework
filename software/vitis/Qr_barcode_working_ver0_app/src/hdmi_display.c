#include "hdmi_display.h"

#include <stddef.h>
#include <string.h>

#include "xparameters.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "video_pixel_ops.h"
#include "video_overlay.h"
#include "xaxivdma_hw.h"


#if defined(__GNUC__)
#define HDMI_ALIGNED __attribute__((aligned(64)))
#else
#define HDMI_ALIGNED
#endif


/* Separate scanout, pending and CPU-render buffers. Never modify a buffer
 * currently being read OR already scheduled for the next vertical boundary. */
#if !QR_PL_PREVIEW
static u8 hdmi_frame[DISPLAY_NUM_FRAMES][HDMI_DISPLAY_FRAME_BYTES] HDMI_ALIGNED;
#endif
static u32 hdmi_requested_frame;


/*
 * Use the display controller's configured frame count (4 in this project).
 */
static u8 *hdmi_frames[DISPLAY_NUM_FRAMES];


/* ============================================================
 * HDMI initialize
 * ============================================================ */

int hdmi_display_init(
    hdmi_display_t *hdmi,
    video_vdma_s2mm_t *video_vdma
)
{
    int status;
    u32 i;


    if ((hdmi == NULL) ||
        (video_vdma == NULL)) {

        return XST_FAILURE;
    }


#ifndef XPAR_XVTC_0_BASEADDR
#error "XPAR_XVTC_0_BASEADDR is required."
#endif

#ifndef XPAR_AXI_DYNCLK_0_BASEADDR
#error "XPAR_AXI_DYNCLK_0_BASEADDR is required."
#endif


    memset(
        hdmi,
        0,
        sizeof(*hdmi)
    );


#if !QR_PL_PREVIEW
    /* Initial screen = black; autonomous mode never writes capture stores. */
    memset(
        hdmi_frame,
        0,
        sizeof(hdmi_frame)
    );


    Xil_DCacheFlushRange(
        (INTPTR)hdmi_frame,
        sizeof(hdmi_frame)
    );
#else
    if (video_overlay_init() != XST_SUCCESS) return XST_FAILURE;
#endif


    hdmi_requested_frame = 0U;
    hdmi->render_frame = -1;
    for (i = 0U;
         i < DISPLAY_NUM_FRAMES;
         ++i) {

#if QR_PL_PREVIEW
        hdmi_frames[i] = (u8 *)video_vdma_frame_addr(i);
#else
        hdmi_frames[i] = hdmi_frame[i];
#endif
    }


    xil_printf(
        "\r\n[HDMI] Initializing display...\r\n"
    );


    xil_printf(
        "[HDMI] VDMA   : 0x%08x\r\n",
        (unsigned int)video_vdma->baseaddr
    );


    xil_printf(
        "[HDMI] VTC    : 0x%08x\r\n",
        (unsigned int)XPAR_XVTC_0_BASEADDR
    );


    xil_printf(
        "[HDMI] DynClk : 0x%08x\r\n",
        (unsigned int)XPAR_AXI_DYNCLK_0_BASEADDR
    );


    xil_printf(
        "[HDMI] FB     : 0x%08x\r\n",
        (unsigned int)(UINTPTR)hdmi_frames[0]
    );


    xil_printf(
        "[HDMI] stride : %u\r\n",
        (unsigned int)HDMI_DISPLAY_STRIDE
    );


    /*
     * IMPORTANT:
     *
     * Do NOT initialize another XAxiVdma object here.
     *
     * video_vdma_s2mm_init_start() already initialized
     * the VDMA and started its WRITE/S2MM channel.
     *
     * DisplayCtrl receives the same driver instance and
     * configures only READ/MM2S.
     */
    status =
        DisplayInitialize(
            &hdmi->display,
            &video_vdma->instance,

            /*
             * Vitis 2024.2 SDT:
             * XVtc_LookupConfig() uses BaseAddress.
             */
            (UINTPTR)XPAR_XVTC_0_BASEADDR,

            (u32)XPAR_AXI_DYNCLK_0_BASEADDR,

            hdmi_frames,

            HDMI_DISPLAY_STRIDE
        );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] DisplayInitialize: %d\r\n",
            status
        );

        return status;
    }


    /*
     * DisplayInitialize defaults to VMODE_640x480.
     * Start VTC + DynClk + VDMA MM2S.
     */
#if QR_PL_PREVIEW
    hdmi->display.autoGenlock = 1;
    hdmi->display.vdmaConfig.EnableSync = 1;
#endif
    status =
        DisplayStart(
            &hdmi->display
        );


    if (status != XST_SUCCESS) {

        xil_printf(
            "[FAIL] DisplayStart: %d\r\n",
            status
        );

        return status;
    }


    hdmi->initialized =
        1;
#if QR_PL_PREVIEW
    /* RS + circular + genlock enable + internal source must all be set. */
    if ((XAxiVdma_ReadReg(video_vdma->baseaddr, XAXIVDMA_CR_OFFSET) & 0x8BU) != 0x8BU) {
        hdmi->initialized = 0;
        return XST_FAILURE;
    }
#endif
    hdmi_requested_frame = hdmi->display.curFrame;


    xil_printf(
        "[PASS] HDMI 640x480 RGB888 started\r\n"
    );


    return XST_SUCCESS;
}


/* ============================================================
 * Gray8 -> RGB888 framebuffer
 *
 * Because R = G = B = gray,
 * RGB/BGR byte order does not matter for this diagnostic image.
 * ============================================================ */

int hdmi_display_show_gray8(
    hdmi_display_t *hdmi,
    const u8 *gray
)
{
    u8 *destination;
    if (!gray) return XST_FAILURE;
    destination = hdmi_display_begin_frame(hdmi);
    if (!destination) return XST_FAILURE;
    video_gray8_to_rgb888(destination, gray,
                         HDMI_DISPLAY_WIDTH * HDMI_DISPLAY_HEIGHT);
    return hdmi_display_commit_frame(hdmi);
}

u8 *hdmi_display_begin_frame(hdmi_display_t *hdmi)
{
#if QR_PL_PREVIEW
    (void)hdmi;
    return NULL; /* Capture/scanout stores are exclusively owned by VDMA. */
#else
    u32 index, reading;
    if (!hdmi || !hdmi->initialized || hdmi->render_frame >= 0) return NULL;
    reading = (u32)XAxiVdma_CurrFrameStore(hdmi->display.vdma, XAXIVDMA_READ);
    if (reading >= DISPLAY_NUM_FRAMES) return NULL;
    for (index = 0; index < DISPLAY_NUM_FRAMES; ++index) {
        if (index != reading && index != hdmi_requested_frame) {
            hdmi->render_frame = (int)index;
            return hdmi_frame[index];
        }
    }
    return NULL;
#endif
}

void hdmi_display_cancel_frame(hdmi_display_t *hdmi)
{
    if (hdmi) hdmi->render_frame = -1;
}

int hdmi_display_commit_frame(hdmi_display_t *hdmi)
{
#if QR_PL_PREVIEW
    (void)hdmi;
    return XST_FAILURE;
#else
    u32 index, reading;
    int status;
    if (!hdmi || !hdmi->initialized || hdmi->render_frame < 0)
        return XST_FAILURE;
    index = (u32)hdmi->render_frame;
    hdmi->render_frame = -1;
    reading = (u32)XAxiVdma_CurrFrameStore(hdmi->display.vdma, XAXIVDMA_READ);
    if (index >= DISPLAY_NUM_FRAMES || reading >= DISPLAY_NUM_FRAMES ||
        index == reading || index == hdmi_requested_frame)
        return XST_FAILURE;
    Xil_DCacheFlushRange((INTPTR)hdmi_frame[index], HDMI_DISPLAY_FRAME_BYTES);
    status = DisplayChangeFrame(&hdmi->display, index);
    if (status == XST_SUCCESS) hdmi_requested_frame = index;
    return status;
#endif
}


/* ============================================================
 * Debug framebuffer address
 * ============================================================ */

UINTPTR hdmi_display_frame_addr(void)
{
    return (UINTPTR)hdmi_frames[hdmi_requested_frame];
}
