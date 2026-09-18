#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "qr_candidate_geometry.h"
#include "qr_decode.h"
#include "qr_perf.h"

/* Deterministic version-3 fixture, generated with reportlab QrCodeWidget,
 * error level L, payload below. No external fixture dependency at test time. */
static const char *matrix[29] = {
"11111110111101110110101111111", "10000010000111110011001000001",
"10111010010101100011001011101", "10111010001100110101101011101",
"10111010001111010100001011101", "10000010010101100010101000001",
"11111110101010101010101111111", "00000000110010100010000000000",
"11011010010011111100001000001", "00100000101000100010000111100",
"01111111010010100100101011000", "11111100100000110101010011011",
"10011110111001101001001100000", "01000100111010000011001110101",
"10010110101000111101000100011", "11111000100011110000111111101",
"10010111000110000000100110001", "11101000111100010101000010101",
"11100010010011110011001110101", "11100001101101011011110010100",
"11000110001101001100111111111", "00000000100011010011100011111",
"11111110010101011101101010100", "10000010000111001101100011011",
"10111010111111001001111111011", "10111010110001111001010000101",
"10111010001111010111000010011", "10000010111100011001011011101",
"11111110110000111001110010000"};
static const char payload[] = "PL-guided Geometry ROI regression";
static unsigned char gray[640*480];
#ifndef QR_BENCH_BOARD
static XTime ticks;
void XTime_GetTime(XTime *t) {*t = ++ticks;}
#endif
void runtime_log_printf(const char *format, ...) {(void)format;}

static qr_candidate_t candidate(int x, int y, int label) {
    qr_candidate_t c;
    memset(&c, 0, sizeof(c));
    c.label=label;c.hits=9;c.min_x=x-1;c.max_x=x+1;
    c.min_y=y-4;c.max_y=y+4;c.sum_x=x*9;c.sum_y=y*9;
    return c;
}
static qr_candidate_packet_t render(double a,double b,double c,double d,int ox,int oy) {
    const double sx[3]={3.5,25.5,3.5},sy[3]={3.5,3.5,25.5};
    qr_candidate_packet_t p;
    double det=a*d-b*c;
    int x,y,i;
    memset(gray,255,sizeof(gray));memset(&p,0,sizeof(p));p.frame_id=42;p.count=3;
    for(y=0;y<480;++y) for(x=0;x<640;++x) {
        int u=(int)floor((d*(x-ox+0.5)-b*(y-oy+0.5))/det);
        int v=(int)floor((-c*(x-ox+0.5)+a*(y-oy+0.5))/det);
        if(u>=0 && v>=0 && u<29 && v<29 && matrix[v][u]=='1')gray[y*640+x]=0;
    }
    for(i=0;i<3;++i)p.items[i]=candidate((int)(ox+a*sx[i]+b*sy[i]),
                                        (int)(oy+c*sx[i]+d*sy[i]),i);
    return p;
}
static void expect_guided(qr_candidate_packet_t *p) {
    char result[256];qr_decode_box_t full,box;int i;
    assert(qr_decode_frame(gray,result,sizeof(result),&full)==QR_DECODE_OK);
    assert(!strcmp(result,payload));
    assert(qr_decode_guided_frame(gray,p,42,result,sizeof(result),&box)==QR_DECODE_OK);
    assert(!strcmp(result,payload));
    assert(qr_decode_last_profile()->guided_pass==1);
    assert(qr_decode_last_profile()->fallback_attempts==0);
    for(i=0;i<4;++i) {
        assert(abs(box.corner[i].x-full.corner[i].x)<=2);
        assert(abs(box.corner[i].y-full.corner[i].y)<=2);
    }
}
int main(void) {
    const int permutations[6][3]={{0,1,2},{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}};
    qr_geometry_proposal_t proposal[2];qr_candidate_packet_t p,t;
    char result[256];qr_decode_box_t box;int i,j,attempts=0,skips=0;
    p=render(6,0,0,6,210,140);
    assert(qr_candidate_geometry(&p,42,proposal)>0);
    assert(proposal[0].roi.x0>0 && proposal[0].roi.y0>0);
    for(i=0;i<6;++i) {
        t=p;for(j=0;j<3;++j)t.items[j]=p.items[permutations[i][j]];
        expect_guided(&t);
    }
    p=render(10,0,0,10,170,60);expect_guided(&p);
    p=render(4,0,0,4,310,230);expect_guided(&p);
    p=render(0,-7,7,0,430,100);expect_guided(&p);
    p=render(-7,0,0,-7,430,330);expect_guided(&p);
    p=render(7,1,0.5,7,160,90);expect_guided(&p);
    p=render(6,0,0,6,210,140);
    p.items[0].sum_x+=18;p.items[1].sum_y-=18;expect_guided(&p);
    p.items[3]=p.items[0];p.items[3].label=3;p.count=4;expect_guided(&p);
    p.items[3]=candidate(40,35,3);expect_guided(&p);
#if QR_GUIDED_SEED_RADIUS_MIN >= 8
    p=render(6,0,0,6,210,140);
    for(i=0;i<3;++i) {
        p.items[i].sum_x+=5*p.items[i].hits;
        p.items[i].min_x+=5; p.items[i].max_x+=5;
    }
    expect_guided(&p);
    puts("PASS: five-pixel PL centroid bias recovered inside bounded seed tolerance");
#endif
    t=p;t.frame_id=41;assert(qr_candidate_geometry(&t,42,proposal)==0);
    t=p;t.count=17;assert(qr_candidate_geometry(&t,42,proposal)==0);
    t=p;t.items[0].hits=0;assert(qr_candidate_geometry(&t,42,proposal)==0);
    t=p;t.count=2;assert(qr_candidate_geometry(&t,42,proposal)==0);
    t=p;t.count=3;for(i=0;i<3;++i)t.items[i]=candidate(100+i*50,100, i);
    assert(qr_candidate_geometry(&t,42,proposal)==0);
    for(i=0;i<3;++i)t.items[i]=candidate(100+i,100+i,i);
    assert(qr_candidate_geometry(&t,42,proposal)==0);
    /* Missing packet: exactly 2 whole-frame scans in 12 calls. Skipped
     * frames must not return the last successful payload/coordinates. */
    qr_decode_deinit();
    for(i=0;i<12;++i) {
        int status=qr_decode_guided_frame(gray,NULL,42,result,sizeof(result),&box);
        const qr_decode_profile_t *pr=qr_decode_last_profile();
        attempts+=pr->fallback_attempts;skips+=pr->fallback_skipped;
        assert(pr->packet_reject==1 && pr->guided_attempts==0);
        if(pr->fallback_attempts)assert(status==QR_DECODE_OK && !strcmp(result,payload));
        else assert(status!=QR_DECODE_OK && result[0]==0 && box.corner[0].x==0);
    }
    assert(attempts==2 && skips==10);
    qr_decode_deinit();
#if QR_GUIDED_EARLY_DECODE
    /* Keep all finder/timing/alignment patterns, destroy enough payload cells
     * to force the refinement retry and then the bounded full-frame fallback. */
    p=render(6,0,0,6,210,140);
    for(i=140+9*6;i<140+21*6;++i)
        memset(gray+i*640+210+9*6,0,12*6);
    assert(qr_decode_guided_frame(gray,&p,42,result,sizeof(result),&box)!=QR_DECODE_OK);
    assert(qr_decode_last_profile()->refine_attempts==1);
    assert(qr_decode_last_profile()->fallback_attempts==1);
#if QR_FALLBACK_EARLY_DECODE
    assert(qr_decode_last_profile()->fallback_refine_attempts==1);
    assert(qr_decode_last_profile()->fallback_early_pass==0);
#endif
    assert(result[0]==0);
    qr_decode_deinit();
#endif
    memset(gray,255,sizeof(gray));
    assert(qr_decode_guided_frame(gray,&p,42,result,sizeof(result),&box)!=QR_DECODE_OK);
    assert(result[0]==0 && qr_decode_last_profile()->guided_attempts<=2);
    assert(qr_decode_last_profile()->fallback_attempts==1);
    qr_decode_deinit();
    {
        struct quirc *q=quirc_new();struct quirc_seeded_roi roi;
        assert(q && quirc_resize(q,640,480)==0);
        memset(&roi,0,sizeof(roi));
        memset(quirc_begin(q,NULL,NULL),255,sizeof(gray));
        assert(quirc_end_seeded(q,&roi,0)==0);
        assert(quirc_end_seeded(q,NULL,0)==0);
        assert(quirc_end_seeded(NULL,&roi,0)==0);
        quirc_refine_grid(q,-1);quirc_refine_grid(q,0);quirc_refine_grid(NULL,0);
        quirc_destroy(q);
    }
    puts("PASS: 14 guided/full-frame equivalence cases, geometry guards, blank image, bounded fallback and stale-output guards");
    {
        const double transforms[5][6]={{6,0,0,6,210,140},{4,0,0,4,310,230},
            {0,-7,7,0,430,100},{-7,0,0,-7,430,330},{7,1,0.5,7,160,90}};
        for(i=0;i<5;++i) {
            qr_decode_box_t full;qr_geometry_diagnostics_t diag;
            const double *t=transforms[i];
            qr_decode_deinit();p=render(t[0],t[1],t[2],t[3],(int)t[4],(int)t[5]);
            assert(qr_decode_frame(gray,result,sizeof(result),&full)==QR_DECODE_OK);
            p.count=2;
            assert(qr_candidate_geometry_ex(&p,42,proposal,&diag)==0);
            assert(diag.input_count==2 && diag.triplets==0 && !diag.invalid);
            assert(qr_decode_guided_frame(gray,&p,42,result,sizeof(result),&box)==QR_DECODE_OK);
            assert(!strcmp(result,payload) && qr_decode_last_profile()->fallback_attempts==1);
            assert(qr_decode_last_profile()->fallback_pass==1 && qr_decode_last_profile()->geometry_reject==1);
#if QR_FALLBACK_EARLY_DECODE
            assert(qr_decode_last_profile()->fallback_early_pass+qr_decode_last_profile()->fallback_refine_attempts==1);
#endif
            for(j=0;j<4;++j) {
                assert(abs(full.corner[j].x-box.corner[j].x)<=2);
                assert(abs(full.corner[j].y-box.corner[j].y)<=2);
            }
        }
        qr_decode_deinit();memset(gray,255,sizeof(gray));
        assert(qr_decode_guided_frame(gray,&p,42,result,sizeof(result),&box)!=QR_DECODE_OK);
        assert(result[0]==0 && box.corner[0].x==0 && !qr_decode_last_profile()->fallback_pass);
    }
    puts("PASS: five missing-candidate fallback equivalence cases and blank/stale rejection");
    return 0;
}
