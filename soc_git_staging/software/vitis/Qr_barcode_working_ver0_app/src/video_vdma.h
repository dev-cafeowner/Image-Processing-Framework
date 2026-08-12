#ifndef VIDEO_VDMA_H
#define VIDEO_VDMA_H

#include "xaxivdma.h"
#include "xil_types.h"
#include "xstatus.h"

#define VIDEO_VDMA_NUM_FRAMES       4U
#define VIDEO_VDMA_WIDTH            640U
#define VIDEO_VDMA_HEIGHT           480U
#define VIDEO_VDMA_BYTES_PER_PIXEL  3U
#define VIDEO_VDMA_STRIDE           (VIDEO_VDMA_WIDTH * VIDEO_VDMA_BYTES_PER_PIXEL)
#define VIDEO_VDMA_FRAME_BYTES      (VIDEO_VDMA_STRIDE * VIDEO_VDMA_HEIGHT)

typedef struct {
    XAxiVdma instance;
    XAxiVdma_DmaSetup setup;
    UINTPTR baseaddr;
} video_vdma_s2mm_t;

/*
 * Starts only the VDMA S2MM(write) channel.
 * This is a Stage 4-B bring-up helper whose purpose is to keep the legacy
 * camera/HDMI branch READY so an AXI4-Stream Broadcaster cannot stall the
 * Gray8/Image-DMA branch.
 */
int video_vdma_s2mm_init_start(video_vdma_s2mm_t *vdma, UINTPTR baseaddr);

void video_vdma_s2mm_stop(video_vdma_s2mm_t *vdma);
u32 video_vdma_s2mm_cr(const video_vdma_s2mm_t *vdma);
u32 video_vdma_s2mm_status(const video_vdma_s2mm_t *vdma);
UINTPTR video_vdma_frame_addr(u32 index);

#endif
