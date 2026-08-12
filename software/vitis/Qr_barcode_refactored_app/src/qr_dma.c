#include "qr_dma.h"

#include "xaxidma_hw.h"

#include <stddef.h>

int qr_dma_s2mm_init(qr_dma_s2mm_t *dma, UINTPTR baseaddr)
{
    XAxiDma_Config *config;
    int status;

    if (dma == NULL) {
        return XST_FAILURE;
    }

    config = XAxiDma_LookupConfig(baseaddr);
    if (config == NULL) {
        return XST_FAILURE;
    }
    if ((config->HasS2Mm == 0) || (config->HasSg != 0)) {
        return XST_FAILURE;
    }

    status = XAxiDma_CfgInitialize(&dma->instance, config);
    if (status != XST_SUCCESS) {
        return status;
    }
    if (XAxiDma_HasSg(&dma->instance)) {
        return XST_FAILURE;
    }

    dma->baseaddr = baseaddr;
    XAxiDma_IntrDisable(&dma->instance,
                        XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);
    return XST_SUCCESS;
}

int qr_dma_s2mm_arm(qr_dma_s2mm_t *dma, UINTPTR buffer, u32 byte_count)
{
    if ((dma == NULL) || (buffer == (UINTPTR)0U) || (byte_count == 0U)) {
        return XST_FAILURE;
    }
    return XAxiDma_SimpleTransfer(&dma->instance,
                                  buffer,
                                  byte_count,
                                  XAXIDMA_DEVICE_TO_DMA);
}

int qr_dma_s2mm_busy(const qr_dma_s2mm_t *dma)
{
    if (dma == NULL) {
        return 0;
    }
    return XAxiDma_Busy((XAxiDma *)&dma->instance,
                        XAXIDMA_DEVICE_TO_DMA);
}

u32 qr_dma_s2mm_status(const qr_dma_s2mm_t *dma)
{
    if (dma == NULL) {
        return 0U;
    }
    return XAxiDma_ReadReg(dma->instance.RegBase,
                           XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);
}

int qr_dma_s2mm_has_error(const qr_dma_s2mm_t *dma)
{
    return (qr_dma_s2mm_status(dma) & XAXIDMA_ERR_ALL_MASK) != 0U;
}

int qr_dma_s2mm_reset(qr_dma_s2mm_t *dma, u32 timeout_count)
{
    if (dma == NULL) {
        return XST_FAILURE;
    }

    XAxiDma_Reset(&dma->instance);
    while (timeout_count != 0U) {
        if (XAxiDma_ResetIsDone(&dma->instance)) {
            XAxiDma_IntrDisable(&dma->instance,
                                XAXIDMA_IRQ_ALL_MASK,
                                XAXIDMA_DEVICE_TO_DMA);
            return XST_SUCCESS;
        }
        --timeout_count;
    }
    return XST_FAILURE;
}
