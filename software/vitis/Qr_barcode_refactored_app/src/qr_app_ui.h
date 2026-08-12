#ifndef QR_APP_UI_H
#define QR_APP_UI_H

#include "xil_types.h"


/*
 * Initialize UI state.
 *
 * The stored QR result is cleared only at application startup.
 */
void qr_app_ui_init(void);


/*
 * Store a newly decoded QR payload.
 *
 * This API is called only when QR decoding succeeds.
 * Frames without a valid QR do not erase the previous result.
 */
void qr_app_ui_set_result(
    const char *result
);


/*
 * Draw the current UI state over a 640x480 Gray8 image.
 */
void qr_app_ui_draw(
    u8 *image,
    int detected
);


/*
 * Print the current UI state through UART.
 */
void qr_app_ui_print(
    int detected
);


#endif
