#ifndef QR_PIPELINE_TRACE_H
#define QR_PIPELINE_TRACE_H
#include "qr_perf.h"
#include "qr_csr.h"

enum qr_pipe_event {
    QR_PIPE_ARM, QR_PIPE_SOF, QR_PIPE_FE, QR_PIPE_RESULT, QR_PIPE_STREAM,
    QR_PIPE_RDMA, QR_PIPE_IDMA, QR_PIPE_CACHE, QR_PIPE_ACK, QR_PIPE_RELEASE,
    QR_PIPE_NEXT_ARM, QR_PIPE_EVENT_COUNT
};
typedef struct {
    XTime t[QR_PIPE_EVENT_COUNT], last_poll, image_done, busy;
    u32 seen, previous_id, active_id, sequence_bad;
    u32 sof_gap_us, fe_gap_us, result_gap_us, max_poll_gap_us;
    int armed;
} qr_pipeline_trace_t;
/* Host-testable recorder. Timestamps are first PS observations, not PL-edge
 * timestamps. Per-event sample gaps bound the observation uncertainty. */
void qr_pipeline_arm(qr_pipeline_trace_t *p, XTime now, u32 previous_id);
void qr_pipeline_observe(qr_pipeline_trace_t *p, XTime now, u32 status, u32 id);
/* Use the persistent DMA idle bit: the runtime IMAGE_TX_DONE is only a pulse. */
void qr_pipeline_image_observe(qr_pipeline_trace_t *p, XTime now, int dma_idle);
void qr_pipeline_mark(qr_pipeline_trace_t *p, enum qr_pipe_event event, XTime now);
int qr_pipeline_measure(const qr_pipeline_trace_t *p, u32 frame_id, u32 spans[10]);
void qr_pipeline_accumulate(qr_pipeline_trace_t *p, XTime next_arm, u32 frame_id);
void qr_pipeline_report(void);
#endif
