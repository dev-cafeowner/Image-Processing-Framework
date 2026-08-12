#ifndef QR_CAMERA_H
#define QR_CAMERA_H

#include "ov7670.h"


/*
 * Initialize and configure the OV7670 camera.
 *
 * Responsibilities:
 *
 *   - SCCB/I2C initialization
 *   - OV7670 PID/VER probe
 *   - VGA RGB565 configuration
 *   - Camera initialization retry
 *
 * Capture enable/disable is intentionally NOT handled here.
 * Camera streaming is controlled by the runtime because it is coupled
 * with DMA and frame ownership.
 */
int qr_camera_prepare(
    ov7670_t *camera
);


#endif
