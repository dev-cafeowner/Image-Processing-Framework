#ifndef QR_DECODE_H
#define QR_DECODE_H

#include "xil_types.h"


/* ============================================================================
 * QR software decoder configuration
 * ========================================================================== */

#define QR_DECODE_WIDTH        640
#define QR_DECODE_HEIGHT       480

#define QR_DECODE_RESULT_MAX   256


/* ============================================================================
 * Return codes
 * ========================================================================== */

#define QR_DECODE_OK           0
#define QR_DECODE_NOT_FOUND    1
#define QR_DECODE_FAIL         2


/* ============================================================================
 * QR position
 * ========================================================================== */

typedef struct {

    int x;
    int y;

} qr_decode_point_t;


typedef struct {

    qr_decode_point_t corner[4];

} qr_decode_box_t;


/* ============================================================================
 * API
 * ========================================================================== */

/*
 * Initialize quirc once.
 *
 * Internally allocates the 640x480 processing buffer.
 */
int qr_decode_init(void);


/*
 * Decode one 640x480 Gray8 frame.
 *
 * gray:
 *   640 x 480
 *   1 byte / pixel
 *
 * result:
 *   decoded text
 *
 * box:
 *   four QR corners when decode succeeds
 */
int qr_decode_frame(
    const u8 *gray,
    char *result,
    u32 result_size,
    qr_decode_box_t *box
);


/*
 * Release decoder memory.
 */
void qr_decode_deinit(void);


#endif