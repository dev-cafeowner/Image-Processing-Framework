#include "video_vdma.h"

#include <stddef.h>
#include <string.h>

#include "xaxivdma_hw.h"
#include "xil_cache.h"

#if defined(__GNUC__)
#define VIDEO_VDMA_ALIGNED __attribute__((aligned(64)))
#else
#define VIDEO_VDMA_ALIGNED
#endif

#define VIDEO_VDMA_RESET_TIMEOUT 1000000U

/*
 * These buffers are intentionally private to the Stage 4-B VDMA sink.
 * The QR path does not read them; they only keep the existing RGB888 VDMA
 * branch consuming the camera stream while the new Gray8 Image DMA is tested.
 */
static u8 video_sink_frame[VIDEO_VDMA_FRAME_BYTES] VIDEO_VDMA_ALIGNED;

static int video_vdma_wait_reset_done(XAxiVdma *instance)
{
    u32 timeout = VIDEO_VDMA_RESET_TIMEOUT;

    while ((XAxiVdma_ResetNotDone(instance, XAXIVDMA_WRITE) != 0) &&
           (timeout != 0U)) {
        --timeout;
    }

    return (timeout != 0U) ? XST_SUCCESS : XST_FAILURE;
}

int video_vdma_s2mm_init_start(video_vdma_s2mm_t *vdma, UINTPTR baseaddr)
{
    XAxiVdma_Config *config;
    u32 i;
    int status;

    if ((vdma == NULL) || (baseaddr == (UINTPTR)0U)) {
        return XST_FAILURE;
    }

    memset(vdma, 0, sizeof(*vdma));

    /* Vitis 2024.2 SDT BSP uses BaseAddress lookup. */
    config = XAxiVdma_LookupConfig(baseaddr);
    if (config == NULL) {
        return XST_FAILURE;
    }

    status = XAxiVdma_CfgInitialize(&vdma->instance, config, baseaddr);
    if (status != XST_SUCCESS) {
        return status;
    }

    if ((vdma->instance.HasS2Mm == 0) ||
        (vdma->instance.MaxNumFrames < (int)VIDEO_VDMA_NUM_FRAMES)) {
        return XST_FAILURE;
    }

    vdma->baseaddr = baseaddr;

    /* Start from a known S2MM state. */
    XAxiVdma_Reset(&vdma->instance, XAXIVDMA_WRITE);
    status = video_vdma_wait_reset_done(&vdma->instance);
    if (status != XST_SUCCESS) {
        return status;
    }

    XAxiVdma_IntrDisable(&vdma->instance,
                         XAXIVDMA_IXR_ALL_MASK,
                         XAXIVDMA_WRITE);
    (void)XAxiVdma_ClearDmaChannelErrors(&vdma->instance,
                                         XAXIVDMA_WRITE,
                                         XAXIVDMA_SR_ERR_ALL_MASK);

    memset(&vdma->setup, 0, sizeof(vdma->setup));
    vdma->setup.VertSizeInput = (int)VIDEO_VDMA_HEIGHT;
    vdma->setup.HoriSizeInput = (int)VIDEO_VDMA_STRIDE;
    vdma->setup.Stride = (int)VIDEO_VDMA_STRIDE;
    vdma->setup.FrameDelay = 0;
    vdma->setup.EnableCircularBuf = 1;
    vdma->setup.EnableSync = 0;
    vdma->setup.PointNum = 0;
    vdma->setup.EnableFrameCounter = 0;
    vdma->setup.FixedFrameStoreAddr = 0;
    vdma->setup.GenLockRepeat = 0;
    vdma->setup.EnableVFlip = 0U;

    /*
     * Stage 4-B only needs a consuming sink, not four distinct display frames.
     * Point all four hardware frame stores at the same aligned RGB888 buffer.
     */
    Xil_DCacheFlushRange((INTPTR)video_sink_frame, VIDEO_VDMA_FRAME_BYTES);
    for (i = 0U; i < VIDEO_VDMA_NUM_FRAMES; ++i) {
        vdma->setup.FrameStoreStartAddr[i] =
            (UINTPTR)video_sink_frame;
    }

    status = XAxiVdma_DmaConfig(&vdma->instance,
                                XAXIVDMA_WRITE,
                                &vdma->setup);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = XAxiVdma_DmaSetBufferAddr(&vdma->instance,
                                       XAXIVDMA_WRITE,
                                       vdma->setup.FrameStoreStartAddr);
    if (status != XST_SUCCESS) {
        return status;
    }

    status = XAxiVdma_DmaStart(&vdma->instance, XAXIVDMA_WRITE);
    if (status != XST_SUCCESS) {
        return status;
    }

    /* Running channel must have RS=1 and HALTED=0. */
    if (((video_vdma_s2mm_cr(vdma) & XAXIVDMA_CR_RUNSTOP_MASK) == 0U) ||
        ((video_vdma_s2mm_status(vdma) & XAXIVDMA_SR_HALTED_MASK) != 0U)) {
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

void video_vdma_s2mm_stop(video_vdma_s2mm_t *vdma)
{
    if (vdma == NULL) {
        return;
    }

    XAxiVdma_DmaStop(&vdma->instance, XAXIVDMA_WRITE);
}

u32 video_vdma_s2mm_cr(const video_vdma_s2mm_t *vdma)
{
    if (vdma == NULL) {
        return 0U;
    }

    return XAxiVdma_ReadReg(vdma->baseaddr,
                            XAXIVDMA_RX_OFFSET + XAXIVDMA_CR_OFFSET);
}

u32 video_vdma_s2mm_status(const video_vdma_s2mm_t *vdma)
{
    if (vdma == NULL) {
        return 0U;
    }

    return XAxiVdma_GetStatus((XAxiVdma *)&vdma->instance,
                              XAXIVDMA_WRITE);
}

UINTPTR video_vdma_frame_addr(u32 index)
{
    if (index >= VIDEO_VDMA_NUM_FRAMES) {
        return (UINTPTR)0U;
    }

    return (UINTPTR)video_sink_frame;
}
