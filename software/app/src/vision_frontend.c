#include "vision_frontend.h"

#include <stddef.h>

#include "xil_io.h"

void qr_frontend_init(qr_frontend_t *frontend, UINTPTR base)
{
    if (frontend == NULL) {
        return;
    }
    frontend->base = base;
    frontend->persistent_control = 0U;
}

u32 qr_frontend_read(const qr_frontend_t *frontend, u32 offset)
{
    if (frontend == NULL) {
        return 0U;
    }
    return Xil_In32(frontend->base + (UINTPTR)offset);
}

void qr_frontend_write(const qr_frontend_t *frontend, u32 offset, u32 value)
{
    if (frontend == NULL) {
        return;
    }
    Xil_Out32(frontend->base + (UINTPTR)offset, value);
}

int qr_frontend_probe(const qr_frontend_t *frontend)
{
    if (frontend == NULL) {
        return XST_FAILURE;
    }
    return qr_frontend_read(frontend, QR_FE_VERSION_OFFSET) ==
           QR_FE_VERSION_EXPECTED ? XST_SUCCESS : XST_FAILURE;
}

void qr_frontend_quiesce(qr_frontend_t *frontend)
{
    if (frontend == NULL) {
        return;
    }
    frontend->persistent_control = 0U;
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET, 0U);
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET,
                      QR_FE_CTRL_SOFT_RESET | QR_FE_CTRL_STAT_CLEAR);
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET, 0U);
}

void qr_frontend_set_mode(qr_frontend_t *frontend, u32 mode)
{
    if (frontend == NULL) {
        return;
    }
    qr_frontend_write(frontend, QR_FE_MODE_OFFSET, mode);
}

void qr_frontend_set_threshold(qr_frontend_t *frontend, u32 threshold)
{
    if (frontend == NULL) {
        return;
    }
    qr_frontend_write(frontend, QR_FE_THRESH_OFFSET, threshold);
}

void qr_frontend_set_geometry(qr_frontend_t *frontend, u32 geometry)
{
    if (frontend == NULL) {
        return;
    }
    qr_frontend_write(frontend, QR_FE_GEOM_OFFSET, geometry);
}

void qr_frontend_enable(qr_frontend_t *frontend, int fb_invert)
{
    if (frontend == NULL) {
        return;
    }
    frontend->persistent_control = QR_FE_CTRL_ENABLE;
    if (fb_invert) {
        frontend->persistent_control |= QR_FE_CTRL_FB_INVERT;
    }
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET,
                      frontend->persistent_control | QR_FE_CTRL_STAT_CLEAR);
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET,
                      frontend->persistent_control);
}

void qr_frontend_release_frame(qr_frontend_t *frontend)
{
    if (frontend == NULL) {
        return;
    }
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET,
                      frontend->persistent_control | QR_FE_CTRL_FRAME_RELEASE);
    qr_frontend_write(frontend, QR_FE_CTRL_OFFSET,
                      frontend->persistent_control);
}
