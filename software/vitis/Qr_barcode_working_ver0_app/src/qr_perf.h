#ifndef QR_PERF_H
#define QR_PERF_H

#include "xiltimer.h"

#ifndef QR_PREVIEW_FUSED
#define QR_PREVIEW_FUSED 1
#endif
#ifndef QR_PER_FRAME_LOGS
#define QR_PER_FRAME_LOGS 0
#endif

/* CPU timer, not host UART arrival timestamps. */
static inline XTime qr_perf_now(void)
{
    XTime ticks;
    XTime_GetTime(&ticks);
    return ticks;
}

static inline u32 qr_perf_us(XTime begin, XTime end)
{
    return (u32)(((end - begin) * 1000000ULL) / (COUNTS_PER_SECOND));
}

#endif
