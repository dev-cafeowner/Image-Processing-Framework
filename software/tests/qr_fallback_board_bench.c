/* Isolated Cortex-A9 diagnostic. Synthetic fixture, NOT live camera throughput.
 * Reuse the exact regression renderer and payload; never feed a fake PL packet
 * into the live runtime. Camera/VDMA are not initialized in this executable. */
#define QR_BENCH_BOARD 1
#define main qr_regression_main
#include "qr_candidate_geometry_test.c"
#undef main
#include "platform.h"
#include "xil_cache.h"
#include "sleep.h"

int main(void)
{
    const double transforms[5][6]={{6,0,0,6,210,140},{4,0,0,4,310,230},
        {0,-7,7,0,430,100},{-7,0,0,-7,430,330},{7,1,0.5,7,160,90}};
    int fixture,rep;
    init_platform();
    Xil_ICacheEnable(); Xil_DCacheEnable();
    sleep(2);
    printf("[BENCH BEGIN] synthetic=1 live_pipeline=0 early_decode=%d repeats=30\r\n",
           QR_FALLBACK_EARLY_DECODE);
    assert(qr_regression_main()==0);
    qr_decode_deinit();
    for(fixture=0;fixture<7;++fixture) {
        const double *t=transforms[fixture<5?fixture:0];
        qr_candidate_packet_t p=render(t[0],t[1],t[2],t[3],(int)t[4],(int)t[5]);
        char result[256]; qr_decode_box_t box;
        if(fixture==5) memset(gray,255,sizeof(gray));
        if(fixture==6) {
            int y;
            for(y=140+9*6;y<140+21*6;++y)
                memset(gray+y*640+210+9*6,0,12*6);
        }
        /* Controlled insufficient-candidate path: no seeded search; preserve
         * real fallback, threshold, ECC, and refinement implementation. */
        p.count=2;
        for(rep=-1;rep<30;++rep) {
            XTime started; unsigned elapsed; int status;
            const qr_decode_profile_t *pr;
            /* Reset/init outside timing; one warmup per fixture is discarded.
             * These are independent calls, NOT a claim to bypass live throttle. */
            qr_decode_deinit(); assert(qr_decode_init()==QR_DECODE_OK);
            started=qr_perf_now();
            status=qr_decode_guided_frame(gray,&p,42,result,sizeof(result),&box);
            elapsed=qr_perf_us(started,qr_perf_now());
            pr=qr_decode_last_profile();
            assert(pr->fallback_attempts==1 && !pr->guided_attempts);
            if(fixture<5) assert(status==QR_DECODE_OK && !strcmp(result,payload));
            else assert(status!=QR_DECODE_OK && result[0]==0 && box.corner[0].x==0);
            if(rep>=0) printf("[BENCH] early_decode=%d fixture=%d rep=%d status=%d us=%u fallback_us=%lu early=%lu refined=%lu\r\n",
                QR_FALLBACK_EARLY_DECODE,fixture,rep,status,elapsed,
                pr->fallback_us,pr->fallback_early_pass,pr->fallback_refine_attempts);
        }
    }
    qr_decode_deinit();
    puts("[BENCH COMPLETE] regression=PASS samples=210 synthetic=1 live_pipeline=0");
    for(;;) {}
}
