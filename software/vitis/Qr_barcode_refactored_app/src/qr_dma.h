#ifndef QR_DMA_H
#define QR_DMA_H

#include "xaxidma.h"
#include "xil_types.h"
#include "xstatus.h"

typedef struct {
    XAxiDma instance;
    UINTPTR baseaddr;
} qr_dma_s2mm_t;

int qr_dma_s2mm_init(qr_dma_s2mm_t *dma, UINTPTR baseaddr);
int qr_dma_s2mm_arm(qr_dma_s2mm_t *dma, UINTPTR buffer, u32 byte_count);
int qr_dma_s2mm_busy(const qr_dma_s2mm_t *dma);
u32 qr_dma_s2mm_status(const qr_dma_s2mm_t *dma);
int qr_dma_s2mm_has_error(const qr_dma_s2mm_t *dma);
int qr_dma_s2mm_reset(qr_dma_s2mm_t *dma, u32 timeout_count);

#endif
