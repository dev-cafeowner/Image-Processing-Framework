#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "qr_pipeline_trace.h"
void XTime_GetTime(XTime *t) {*t=0;}
void runtime_log_printf(const char *format,...) {(void)format;}
int main(void)
{
    qr_pipeline_trace_t p;u32 spans[10];int i;
    qr_pipeline_arm(&p,1000,41);
    qr_pipeline_image_observe(&p,1100,1);assert(!p.image_done);
    qr_pipeline_observe(&p,2000,QR_STATUS_RESULT_READY|QR_STATUS_FRONTEND_FRAME_READY,41);
    assert(p.seen==(1U<<QR_PIPE_ARM)); /* Old status cannot invent a new frame. */
    qr_pipeline_observe(&p,3000,0,42);
    qr_pipeline_image_observe(&p,3100,0);assert(!p.image_done);
    qr_pipeline_image_observe(&p,33900,1);assert(p.image_done==33900);
    qr_pipeline_image_observe(&p,34000,1);assert(p.image_done==33900);
    qr_pipeline_observe(&p,34000,QR_STATUS_FRONTEND_FRAME_READY|QR_STATUS_IMAGE_TX_DONE|QR_STATUS_PROCESSING_BUSY,42);
    qr_pipeline_observe(&p,44000,QR_STATUS_FRONTEND_FRAME_READY|QR_STATUS_RESULT_READY,42);
    for(i=QR_PIPE_STREAM;i<QR_PIPE_EVENT_COUNT;++i)qr_pipeline_mark(&p,(enum qr_pipe_event)i,44000+(i-3)*100);
    assert(qr_pipeline_measure(&p,42,spans));
    assert(spans[0]==2000 && spans[1]==31000 && spans[2]==10000);
    assert(p.sof_gap_us==1000 && p.fe_gap_us==31000 && p.result_gap_us==10000);
    for(i=3;i<10;++i)assert(spans[i]==100);
    assert(!qr_pipeline_measure(&p,43,spans));
    p.t[QR_PIPE_ACK]=1;assert(!qr_pipeline_measure(&p,42,spans));
    qr_pipeline_arm(&p,1000,41);qr_pipeline_observe(&p,2000,0,43);
    assert(p.sequence_bad && !qr_pipeline_measure(&p,43,spans));
    qr_pipeline_arm(&p,1000,0xffffffffUL);qr_pipeline_observe(&p,2000,0,0);
    assert(!p.sequence_bad); /* 32-bit accepted-frame ID wrap. */
    qr_pipeline_observe(&p,3000,0,1);assert(p.sequence_bad);
    memset(&p,0,sizeof(p));assert(!qr_pipeline_measure(&p,0,spans));
    puts("PASS: pipeline phase partition, first observations, frame identity/wrap, incomplete and reordered rejection");
    return 0;
}
