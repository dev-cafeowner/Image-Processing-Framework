#ifndef VIDEO_VDMA_H
#define VIDEO_VDMA_H

#include "xaxivdma.h"
#include "xil_types.h"
#include "xstatus.h"
#ifndef QR_PL_PREVIEW
#define QR_PL_PREVIEW 0
#endif

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
    u32 observed_write_frame;
    u32 observed_frames;
} video_vdma_s2mm_t;

/*
 * Starts only the VDMA S2MM(write) channel.
 * Four independent RGB888 stores keep the preview branch consuming camera
 * data while software processes a separate Gray8 snapshot.
 */
int video_vdma_s2mm_init_start(video_vdma_s2mm_t *vdma, UINTPTR baseaddr);

void video_vdma_s2mm_stop(video_vdma_s2mm_t *vdma);
u32 video_vdma_s2mm_cr(const video_vdma_s2mm_t *vdma);
u32 video_vdma_s2mm_status(const video_vdma_s2mm_t *vdma);
UINTPTR video_vdma_frame_addr(u32 index);
/* Returns 1 for a new completed frame, 0 if unchanged, -1 on DMA error.
 * Caller must consume promptly and validate writer position after copying. */
int video_vdma_latest_complete(video_vdma_s2mm_t *vdma, u32 *index, u32 *writer);

#endif
