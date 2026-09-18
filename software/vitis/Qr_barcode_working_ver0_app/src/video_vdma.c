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

/* Real circular capture stores; CPU only reads a completed store. */
static u8 video_sink_frame[VIDEO_VDMA_NUM_FRAMES][VIDEO_VDMA_FRAME_BYTES] VIDEO_VDMA_ALIGNED;

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
#if QR_PL_PREVIEW
    if (!config->InternalGenLock || config->Mm2SGenLock != XAXIVDMA_DYN_GENLOCK_SLAVE ||
        config->S2MmGenLock != XAXIVDMA_DYN_GENLOCK_MASTER ||
        vdma->instance.MaxNumFrames != (int)VIDEO_VDMA_NUM_FRAMES)
        return XST_FAILURE;
#endif

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
    vdma->setup.EnableSync = QR_PL_PREVIEW ? 1 : 0;
    vdma->setup.PointNum = 0;
    vdma->setup.EnableFrameCounter = 0;
    vdma->setup.FixedFrameStoreAddr = 0;
    vdma->setup.GenLockRepeat = QR_PL_PREVIEW ? 1 : 0;
    vdma->setup.EnableVFlip = 0U;

    Xil_DCacheFlushRange((INTPTR)video_sink_frame, sizeof(video_sink_frame));
    for (i = 0U; i < VIDEO_VDMA_NUM_FRAMES; ++i) {
        vdma->setup.FrameStoreStartAddr[i] =
            (UINTPTR)video_sink_frame[i];
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
#if QR_PL_PREVIEW
    if ((video_vdma_s2mm_cr(vdma) & 0x8BU) != 0x8BU) return XST_FAILURE;
#endif

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

    return (UINTPTR)video_sink_frame[index];
}

int video_vdma_latest_complete(video_vdma_s2mm_t *vdma, u32 *index, u32 *writer)
{
    u32 current;
    /* Dynamic master may skip stores: (writer-1)%N is not a completed index. */
    if (QR_PL_PREVIEW) return -1;
    if (!vdma || !index || !writer) return -1;
    if (video_vdma_s2mm_status(vdma) &
        (XAXIVDMA_SR_ERR_ALL_MASK | XAXIVDMA_SR_HALTED_MASK)) return -1;
    current = XAxiVdma_CurrFrameStore(&vdma->instance, XAXIVDMA_WRITE);
    if (current >= VIDEO_VDMA_NUM_FRAMES) return -1;
    if (current == vdma->observed_write_frame) return 0;
    vdma->observed_frames += (current + VIDEO_VDMA_NUM_FRAMES -
                             vdma->observed_write_frame) % VIDEO_VDMA_NUM_FRAMES;
    vdma->observed_write_frame = current;
    *writer = current;
    *index = (current + VIDEO_VDMA_NUM_FRAMES - 1U) % VIDEO_VDMA_NUM_FRAMES;
    return 1;
}
