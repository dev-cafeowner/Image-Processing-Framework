#include "qr_pipeline_trace.h"
#include "runtime_log.h"
#include <string.h>

static struct {
    u32 n, bad, max[10], gaps[4], periods, busy_n, image_n;
    u64 sum[10], period_sum, image_sum, busy_sum;
} window;
static XTime previous_sof;
static u32 total;

void qr_pipeline_mark(qr_pipeline_trace_t *p, enum qr_pipe_event e, XTime now)
{
    if (!p || !p->armed || (unsigned)e >= QR_PIPE_EVENT_COUNT || (p->seen & (1U<<e))) return;
    p->t[e]=now;p->seen|=1U<<e;
}
void qr_pipeline_arm(qr_pipeline_trace_t *p, XTime now, u32 previous_id)
{
    memset(p,0,sizeof(*p));p->armed=1;p->previous_id=previous_id;p->last_poll=now;
    qr_pipeline_mark(p,QR_PIPE_ARM,now);
}
void qr_pipeline_observe(qr_pipeline_trace_t *p, XTime now, u32 status, u32 id)
{
    u32 gap;
    if(!p || !p->armed) return;
    gap=qr_perf_us(p->last_poll,now);p->last_poll=now;
    if(gap>p->max_poll_gap_us)p->max_poll_gap_us=gap;
    if(!(p->seen & (1U<<QR_PIPE_SOF))) {
        if(id==p->previous_id)return;
        p->sequence_bad=(id!=(u32)(p->previous_id+1U));p->active_id=id;
        qr_pipeline_mark(p,QR_PIPE_SOF,now);p->sof_gap_us=gap;
    } else if(id!=p->active_id) p->sequence_bad=1;
    if((status & QR_STATUS_FRONTEND_FRAME_READY) && !(p->seen & (1U<<QR_PIPE_FE))) {
        qr_pipeline_mark(p,QR_PIPE_FE,now);p->fe_gap_us=gap;
    }
    if((status & QR_STATUS_PROCESSING_BUSY) && !p->busy)p->busy=now;
    if((status & QR_STATUS_RESULT_READY) && !(p->seen & (1U<<QR_PIPE_RESULT))) {
        qr_pipeline_mark(p,QR_PIPE_RESULT,now);p->result_gap_us=gap;
    }
}
void qr_pipeline_image_observe(qr_pipeline_trace_t *p, XTime now, int dma_idle)
{
    if(p && p->armed && (p->seen & (1U<<QR_PIPE_SOF)) && dma_idle && !p->image_done)
        p->image_done=now;
}
int qr_pipeline_measure(const qr_pipeline_trace_t *p, u32 frame_id, u32 spans[10])
{
    unsigned i;
    if(!p || !spans || !p->armed || p->sequence_bad || p->active_id!=frame_id ||
       p->seen!=((1U<<QR_PIPE_EVENT_COUNT)-1U))return 0;
    for(i=0;i<10;++i) {
        if(p->t[i+1]<p->t[i])return 0;
        spans[i]=qr_perf_us(p->t[i],p->t[i+1]);
    }
    return 1;
}
void qr_pipeline_accumulate(qr_pipeline_trace_t *p, XTime next_arm, u32 frame_id)
{
    u32 spans[10],gaps[4],i,period=0;
    if(!p->armed)return; /* Startup frame has no previous rearm timestamp. */
    qr_pipeline_mark(p,QR_PIPE_NEXT_ARM,next_arm);
    if(!qr_pipeline_measure(p,frame_id,spans)) {
        ++window.bad;previous_sof=0;p->armed=0;return;
    }
    ++window.n;++total;
    for(i=0;i<10;++i) {
        window.sum[i]+=spans[i];if(spans[i]>window.max[i])window.max[i]=spans[i];
    }
    gaps[0]=p->sof_gap_us;gaps[1]=p->fe_gap_us;
    gaps[2]=p->result_gap_us;gaps[3]=p->max_poll_gap_us;
    for(i=0;i<4;++i)if(gaps[i]>window.gaps[i])window.gaps[i]=gaps[i];
    if(previous_sof) {
        period=qr_perf_us(previous_sof,p->t[QR_PIPE_SOF]);
        window.period_sum+=period;++window.periods;
    }
    previous_sof=p->t[QR_PIPE_SOF];
    if(p->image_done>=p->t[QR_PIPE_SOF] && p->image_done) {
        window.image_sum+=qr_perf_us(p->t[QR_PIPE_SOF],p->image_done);++window.image_n;
    }
    if(p->busy>=p->t[QR_PIPE_FE] && p->busy) {
        window.busy_sum+=qr_perf_us(p->t[QR_PIPE_FE],p->busy);++window.busy_n;
    }
    if(total<=3 || total%30==0)
        runtime_log_printf("[PIPEFRAME] id=%lu arm_sof_us=%lu capture_us=%lu pl_us=%lu dma_setup_us=%lu result_wait_us=%lu image_tail_us=%lu cache_us=%lu validate_us=%lu ack_us=%lu rearm_us=%lu period_us=%lu sof_gap_us=%lu fe_gap_us=%lu result_gap_us=%lu\r\n",
            frame_id,spans[0],spans[1],spans[2],spans[3],spans[4],spans[5],spans[6],spans[7],spans[8],spans[9],period,gaps[0],gaps[1],gaps[2]);
    p->armed=0;
}
void qr_pipeline_report(void)
{
    u32 a[10]={0},i;
    for(i=0;i<10;++i)if(window.n)a[i]=(u32)(window.sum[i]/window.n);
    runtime_log_printf("[PIPE] n=%lu bad=%lu arm_sof_us=%lu capture_us=%lu pl_us=%lu dma_setup_us=%lu result_wait_us=%lu image_tail_us=%lu cache_us=%lu validate_us=%lu ack_us=%lu rearm_us=%lu\r\n",
        window.n,window.bad,a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7],a[8],a[9]);
    runtime_log_printf("[PIPEMAX] n=%lu arm_sof_us=%lu capture_us=%lu pl_us=%lu dma_setup_us=%lu result_wait_us=%lu image_tail_us=%lu cache_us=%lu validate_us=%lu ack_us=%lu rearm_us=%lu\r\n",
        window.n,window.max[0],window.max[1],window.max[2],window.max[3],window.max[4],window.max[5],window.max[6],window.max[7],window.max[8],window.max[9]);
    runtime_log_printf("[PIPEOBS] n=%lu periods=%lu period_us=%lu image_n=%lu image_done_us=%lu busy_n=%lu busy_delay_us=%lu sof_gap_us=%lu fe_gap_us=%lu result_gap_us=%lu poll_gap_us=%lu\r\n",
        window.n,window.periods,window.periods?(u32)(window.period_sum/window.periods):0U,
        window.image_n,window.image_n?(u32)(window.image_sum/window.image_n):0U,
        window.busy_n,window.busy_n?(u32)(window.busy_sum/window.busy_n):0U,
        window.gaps[0],window.gaps[1],window.gaps[2],window.gaps[3]);
    memset(&window,0,sizeof(window));
}
