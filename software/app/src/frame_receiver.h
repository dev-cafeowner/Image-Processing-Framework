#ifndef QR_FRAME_RECEIVER_H
#define QR_FRAME_RECEIVER_H
#include "qr_dma.h"
int frame_receiver_init(qr_dma_s2mm_t *dma, u8 *buffers, u32 bytes);
void frame_receiver_service(void);
int frame_receiver_failed(void);
int frame_receiver_take(u32 frame_id, u8 **image);
int frame_receiver_release(void);
void frame_receiver_dispatch(void);
void frame_receiver_report(u32 capture_skips);
#endif
