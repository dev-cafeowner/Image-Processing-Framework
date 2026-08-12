#include "hdmi_display.h"

#include <stddef.h>
#include <string.h>

#include "xparameters.h"
#include "xil_cache.h"
#include "xil_printf.h"


#if defined(__GNUC__)
#define HDMI_ALIGNED __attribute__((aligned(64)))
#else
#define HDMI_ALIGNED
#endif


/*
 * HDMI 출력용 RGB888 framebuffer.
 *
 * DisplayCtrl은 3개의 frame pointer를 요구하지만,
 * 이번 bring-up에서는 화면 전환이 필요 없으므로
 * 세 pointer 모두 동일한 framebuffer를 가리킨다.
 *
 * 640 * 480 * 3 = 921600 bytes
 */
static u8 hdmi_frame[HDMI_DISPLAY_FRAME_BYTES] HDMI_ALIGNED;


/*
 * Digilent DisplayCtrl은 DISPLAY_NUM_FRAMES == 3.
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


    /*
     * Initial screen = black.
     */
    memset(
        hdmi_frame,
        0,
        sizeof(hdmi_frame)
    );


    Xil_DCacheFlushRange(
        (INTPTR)hdmi_frame,
        HDMI_DISPLAY_FRAME_BYTES
    );


    /*
     * For this bring-up all three hardware display stores
     * use the same static framebuffer.
     */
    for (i = 0U;
         i < DISPLAY_NUM_FRAMES;
         ++i) {

        hdmi_frames[i] =
            hdmi_frame;
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
        (unsigned int)(UINTPTR)hdmi_frame
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
    u32 pixel;


    if ((hdmi == NULL) ||
        (gray == NULL) ||
        (hdmi->initialized == 0)) {

        return XST_FAILURE;
    }


    for (pixel = 0U;
         pixel < (HDMI_DISPLAY_WIDTH *
                  HDMI_DISPLAY_HEIGHT);
         ++pixel) {

        const u8 value =
            gray[pixel];

        const u32 dst =
            pixel * HDMI_DISPLAY_BYTES_PER_PIXEL;


        hdmi_frame[dst + 0U] =
            value;

        hdmi_frame[dst + 1U] =
            value;

        hdmi_frame[dst + 2U] =
            value;
    }


    /*
     * CPU generated the framebuffer.
     * Flush cache so VDMA MM2S sees the new pixels.
     */
    Xil_DCacheFlushRange(
        (INTPTR)hdmi_frame,
        HDMI_DISPLAY_FRAME_BYTES
    );


    xil_printf(
        "[PASS] Gray8 copied to HDMI framebuffer\r\n"
    );


    return XST_SUCCESS;
}


/* ============================================================
 * Debug framebuffer address
 * ============================================================ */

UINTPTR hdmi_display_frame_addr(void)
{
    return (UINTPTR)hdmi_frame;
}