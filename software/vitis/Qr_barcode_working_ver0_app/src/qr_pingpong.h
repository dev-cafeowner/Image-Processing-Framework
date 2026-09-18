#ifndef QR_PINGPONG_H
#define QR_PINGPONG_H
#include "qr_dma.h"
int qr_pingpong_init(qr_dma_s2mm_t *dma, u8 *buffers, u32 bytes);
void qr_pingpong_service(void);
int qr_pingpong_failed(void);
int qr_pingpong_take(u32 frame_id, u8 **image);
int qr_pingpong_release(void);
void qr_pingpong_dispatch(void);
void qr_pingpong_report(u32 capture_skips);
#endif
