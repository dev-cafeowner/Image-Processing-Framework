#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include "video_overlay.h"
#include "xiltimer.h"
static u32 signature=0x50525631, config=2, pending_command, writes;
static u32 memory[4096];
static u64 timer;
static unsigned char pixels[VIDEO_OVERLAY_WIDTH*VIDEO_OVERLAY_HEIGHT+2];
u32 Xil_In32(UINTPTR a) {
    assert(a>=VIDEO_OVERLAY_BASE && a<VIDEO_OVERLAY_BASE+0x38);
    if(a==VIDEO_OVERLAY_BASE) return signature;
    if(a==VIDEO_OVERLAY_BASE+4) return config;
    return 0;
}
void Xil_Out32(UINTPTR a,u32 value) {
    if(a==VIDEO_OVERLAY_BASE+8) {
        assert(!(config&8)); assert(writes==1280);
        pending_command=value;config|=8;return;
    }
    assert(a>=VIDEO_OVERLAY_BASE+0x2000 && a<VIDEO_OVERLAY_BASE+0x6000 && !(a&3));
    assert(!(config&8));
    u32 offset=(u32)(a-VIDEO_OVERLAY_BASE-0x2000);
    assert((offset/0x2000)!=((config>>2)&1));
    memory[offset/4]=value;++writes;
}
void XTime_GetTime(XTime *t) { *t=timer++; }
void runtime_log_printf(const char *fmt,...) { (void)fmt; }
static void check_bank(unsigned bank) {
    for(unsigned p=0;p<VIDEO_OVERLAY_WIDTH*VIDEO_OVERLAY_HEIGHT;++p)
        assert(((memory[bank*2048+p/32]>>(p%32))&1)==(pixels[1+p]>=128));
}
int main(void) {
    assert(sizeof(u32)==4);
    signature=0;assert(video_overlay_init()!=0);assert(!video_overlay_ready());
    signature=0x50525631;assert(video_overlay_init()==0);
    assert(video_overlay_submit(NULL)!=0);
    pixels[0]=0xA5;pixels[sizeof(pixels)-1]=0x5A;
    for(unsigned p=0;p<sizeof(pixels)-2;++p) pixels[p+1]=(unsigned char)(p*37);
    assert(video_overlay_submit(pixels+1)==0);assert(pending_command==7);check_bank(1);
    assert(!video_overlay_ready());assert(video_overlay_submit(pixels+1)!=0);assert(writes==1280);
    config=pending_command;writes=0;
    memset(pixels+1,127,sizeof(pixels)-2);
    pixels[1]=128;pixels[sizeof(pixels)-2]=255;
    assert(video_overlay_submit(pixels+1)==0);assert(pending_command==3);check_bank(0);
    assert(pixels[0]==0xA5 && pixels[sizeof(pixels)-1]==0x5A);
    puts("PASS: HUD signature, busy/null rejection, inactive bank, 40960 pixels bit order/threshold, commit after 1280 writes, guards");
    return 0;
}
