#ifndef QR_VISION_FRONTEND_H
#define QR_VISION_FRONTEND_H

#include "xil_types.h"
#include "xstatus.h"

#define QR_FE_CTRL_OFFSET         0x00U
#define QR_FE_MODE_OFFSET         0x04U
#define QR_FE_THRESH_OFFSET       0x08U
#define QR_FE_GEOM_OFFSET         0x0CU
#define QR_FE_STATUS_OFFSET       0x10U
#define QR_FE_FRAME_CNT_OFFSET    0x14U
#define QR_FE_META_OFFSET         0x18U
#define QR_FE_VERSION_OFFSET      0x1CU

#define QR_FE_CTRL_ENABLE         0x00000001U
#define QR_FE_CTRL_SOFT_RESET     0x00000002U
#define QR_FE_CTRL_FRAME_RELEASE  0x00000004U
#define QR_FE_CTRL_FB_INVERT      0x00000008U
#define QR_FE_CTRL_STAT_CLEAR     0x00000010U

#define QR_FE_STATUS_BUSY          0x00000001U
#define QR_FE_STATUS_FRAME_READY   0x00000002U
#define QR_FE_VERSION_EXPECTED     0x00010000U

typedef struct {
    UINTPTR base;
    u32 persistent_control;
} qr_frontend_t;

void qr_frontend_init(qr_frontend_t *frontend, UINTPTR base);
u32 qr_frontend_read(const qr_frontend_t *frontend, u32 offset);
void qr_frontend_write(const qr_frontend_t *frontend, u32 offset, u32 value);
int qr_frontend_probe(const qr_frontend_t *frontend);
void qr_frontend_quiesce(qr_frontend_t *frontend);
void qr_frontend_set_mode(qr_frontend_t *frontend, u32 mode);
void qr_frontend_set_threshold(qr_frontend_t *frontend, u32 threshold);
void qr_frontend_set_geometry(qr_frontend_t *frontend, u32 geometry);
void qr_frontend_enable(qr_frontend_t *frontend, int fb_invert);
void qr_frontend_release_frame(qr_frontend_t *frontend);

#endif
