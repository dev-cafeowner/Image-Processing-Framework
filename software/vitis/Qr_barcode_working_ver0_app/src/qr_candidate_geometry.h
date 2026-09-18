#ifndef QR_CANDIDATE_GEOMETRY_H
#define QR_CANDIDATE_GEOMETRY_H
#include "qr_candidate_packet.h"
#include "quirc.h"
#define QR_GEOMETRY_MAX_PROPOSALS 2
#ifndef QR_GUIDED_SEED_RADIUS_MIN
#define QR_GUIDED_SEED_RADIUS_MIN 4
#endif
/* Seed 0 is the proposed right-angle finder; seeds 1/2 are its arms.
 * ROI is a conservative search bound, NOT an asserted QR quadrilateral. */
typedef struct {
    struct quirc_seeded_roi roi;
    uint32_t labels[3];
    double score;
} qr_geometry_proposal_t;
typedef struct {
    uint32_t input_count, filtered_count, triplets, spacing_reject, span_reject, angle_reject, invalid;
} qr_geometry_diagnostics_t;
int qr_candidate_geometry_ex(const qr_candidate_packet_t *packet, uint32_t frame_id,
    qr_geometry_proposal_t proposals[QR_GEOMETRY_MAX_PROPOSALS], qr_geometry_diagnostics_t *diagnostics);
int qr_candidate_geometry(const qr_candidate_packet_t *packet, uint32_t frame_id,
    qr_geometry_proposal_t proposals[QR_GEOMETRY_MAX_PROPOSALS]);
#endif
