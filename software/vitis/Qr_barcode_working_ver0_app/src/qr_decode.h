#ifndef QR_DECODE_H
#define QR_DECODE_H

/* Optional cooperative preview service, called between complete QR scans. */
void qr_decode_set_progress_callback(void (*callback)(void));

#include "xil_types.h"
#ifndef QR_FALLBACK_EARLY_DECODE
#define QR_FALLBACK_EARLY_DECODE 0
#endif
#if QR_PL_GUIDED
#include "qr_candidate_packet.h"
#endif


/* ============================================================================
 * QR software decoder configuration
 * ========================================================================== */

#define QR_DECODE_WIDTH        640
#define QR_DECODE_HEIGHT       480

#define QR_DECODE_RESULT_MAX   256

/* Per-call wall time; identify may include the cooperative display callback. */
typedef struct {
    u32 scans;
    u32 range_us;
    u32 fill_us;
    u32 identify_us;
    u32 payload_us;
#if QR_PL_GUIDED
    u32 guided_attempts, guided_pass, geometry_reject, packet_reject;
    u32 fallback_attempts, fallback_pass, fallback_skipped;
    u32 proposal_us, guided_us, fallback_us, roi_pixels;
    u32 early_pass, refine_attempts, refine_pass, refine_us;
    u32 fallback_early_pass, fallback_refine_attempts, fallback_refine_us;
#endif
} qr_decode_profile_t;
const qr_decode_profile_t *qr_decode_last_profile(void);
#if QR_CANDIDATE_AUDIT
/* Read-only diagnostics for the final quirc scan of this frame (not a union
 * across fallback thresholds). Does not change the decoding decision. */
void qr_decode_audit_finders(u32 frame_id, int decode_status);
#endif


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

#if QR_PL_GUIDED
int qr_decode_guided_frame(const u8 *gray, const qr_candidate_packet_t *packet,
    u32 frame_id, char *result, u32 result_size, qr_decode_box_t *box);
#endif


#endif
