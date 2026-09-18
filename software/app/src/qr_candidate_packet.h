#ifndef QR_CANDIDATE_PACKET_H
#define QR_CANDIDATE_PACKET_H
#include <stdint.h>
#include <stddef.h>

#define QR_CANDIDATE_MAX 16U
typedef struct {
    uint32_t label, hits, min_x, max_x, min_y, max_y, sum_x, sum_y;
} qr_candidate_t;
typedef struct {
    uint32_t frame_id, count;
    qr_candidate_t items[QR_CANDIDATE_MAX];
} qr_candidate_packet_t;
enum {
    QR_PACKET_OK=0, QR_PACKET_LENGTH=1, QR_PACKET_SCHEMA=2,
    QR_PACKET_FRAME=3, QR_PACKET_COUNT=4, QR_PACKET_PL_ERROR=5,
    QR_PACKET_RECORD=6, QR_PACKET_COORDINATE=7, QR_PACKET_SUM=8
};

/* Strict current QRP1 ABI, Gray8 frame-aligned only. A candidate's box encloses
 * sparse finder-center HITs; it is NOT the QR symbol's bounding box or ROI.
 * On failure, count stays zero: callers must never consume partial records. */
static inline int qr_candidate_packet_parse(const uint32_t *w, size_t words,
    uint32_t expected_frame, uint32_t csr_count, qr_candidate_packet_t *out)
{
    uint32_t n, i, total_hits=0, previous_label=0;
    if (!out) return QR_PACKET_RECORD;
    out->count=0;
    out->frame_id=0;
    if (!w || words<5U || words>5U+5U*QR_CANDIDATE_MAX)
        return QR_PACKET_LENGTH;
    if (w[0]!=0x51525031U || w[1]!=0x01050500U || (w[3]&255U)!=1U)
        return QR_PACKET_SCHEMA;
    if (w[2]!=expected_frame) return QR_PACKET_FRAME;
    n=(w[3]>>8)&255U;
    if (n>QR_CANDIDATE_MAX || n!=csr_count || words!=5U+5U*n || (w[3]>>16)!=words)
        return QR_PACKET_COUNT;
    if (w[4]) return QR_PACKET_PL_ERROR;
    for (i=0;i<n;++i) {
        const uint32_t *r=w+5U+5U*i;
        qr_candidate_t *c=&out->items[i];
        c->label=r[0]&31U;
        c->hits=r[0]>>13;
        c->min_x=r[1]&1023U; c->max_x=(r[1]>>10)&1023U;
        c->min_y=(r[1]>>20)&511U; c->max_y=r[2]&511U;
        c->sum_x=r[3]&0x0fffffffU; c->sum_y=r[4]&0x0fffffffU;
        if ((r[0]&0x1fe0U) || (r[1]>>29) || (r[2]>>9) ||
            (r[3]>>28) || (r[4]>>28) || c->hits<3U || c->hits>256U ||
            (i && c->label<=previous_label)) return QR_PACKET_RECORD;
        previous_label=c->label;
        total_hits+=c->hits;
        if (total_hits>256U) return QR_PACKET_RECORD;
        if (c->min_x>c->max_x || c->max_x>=640U ||
            c->min_y>c->max_y || c->max_y>=480U) return QR_PACKET_COORDINATE;
        if (c->sum_x<c->min_x*c->hits || c->sum_x>c->max_x*c->hits ||
            c->sum_y<c->min_y*c->hits || c->sum_y>c->max_y*c->hits)
            return QR_PACKET_SUM;
    }
    out->frame_id=w[2]; out->count=n;
    return QR_PACKET_OK;
}
#endif
