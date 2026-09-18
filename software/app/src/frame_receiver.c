#include "frame_receiver.h"
#include "qr_gray_ring.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xaxidma_hw.h"
#include "qr_perf.h"
#include "runtime_log.h"
#define QBASE 0x43c40000U
#define RD(o) Xil_In32(QBASE+(o))
#define CMD(v) Xil_Out32(QBASE+8U,(v))
static qr_gray_ring_t ring;
static qr_dma_s2mm_t *rx;
static u8 *images;
static u32 image_bytes, received, taken, faults, no_slot, rearm_max;
static unsigned prepared[2];
static u32 prepare_max;
static int enabled, servicing;
static void fail(const char *why)
{
    if(!faults) runtime_log_printf("[FAIL] QPP1 %s errors=%08lx status=%08lx dma=%08lx\r\n",
        why,RD(0x24),RD(0x0c),qr_dma_s2mm_status(rx));
    faults=1; enabled=0;
}
static void prepare_free(int slot)
{
    XTime start=qr_perf_now();
    u32 elapsed;
    // Cleaning a FREE slot is safe while DMA uses the other slot. Do this
    // after CPU release, not in the camera's ~1.98ms inter-frame rearm window.
    Xil_DCacheFlushRange((INTPTR)(images+slot*image_bytes),image_bytes);
    Xil_DCacheInvalidateRange((INTPTR)(images+slot*image_bytes),image_bytes);
    prepared[slot]=1;
    elapsed=qr_perf_us(start,qr_perf_now());
    if(elapsed>prepare_max) prepare_max=elapsed;
}
int frame_receiver_init(qr_dma_s2mm_t *dma, u8 *buffers, u32 bytes)
{
    if(RD(0)!=0x51505031U || RD(4)!=0x00010000U || RD(0x2c)!=0x01e00280U ||
       RD(0x18)!=0 || RD(0x24)!=0 || RD(0x0c)!=0) return XST_FAILURE;
    rx=dma; images=buffers; image_bytes=bytes;
    qr_gray_ring_init(&ring);
    received=taken=faults=no_slot=rearm_max=prepare_max=0; servicing=0; enabled=1;
    prepare_free(0); prepare_free(1);
    frame_receiver_service();
    if(faults) return XST_FAILURE;
    frame_receiver_dispatch();
    runtime_log_printf("[BUILD QPP1] banks=2 gray_slots=2 credit=one-shot DMA_rearm=on_image_done\r\n");
    return XST_SUCCESS;
}
void frame_receiver_service(void)
{
    int slot; u32 elapsed;
    XTime start;
    if(!enabled || servicing) return;
    servicing=1;
    if(RD(0x24)) {fail("PL ownership"); goto done;}
    if(ring.dma>=0) {
        if(qr_dma_s2mm_status(rx)&XAXIDMA_ERR_ALL_MASK) {fail("image DMA"); goto done;}
        if(qr_dma_s2mm_busy(rx)) goto done;
        // Persistent DMA idle means all memory writes completed, not just TLAST.
        if(RD(0x1c)!=received+1U || qr_gray_ring_complete(&ring,RD(0x14))<0) {
            fail("image identity/count"); goto done;
        }
        ++received;
    }
    start=qr_perf_now();
    slot=qr_gray_ring_reserve(&ring,RD(0x10));
    if(slot<0) {++no_slot; goto done;}
    if(!prepared[slot]) {fail("unclean DMA slot"); goto done;}
    if(qr_dma_s2mm_arm(rx,(UINTPTR)(images+slot*image_bytes),image_bytes)!=XST_SUCCESS) {
        fail("rearm"); goto done;
    }
#ifndef QR_PINGPONG_HOST_TEST
    __asm__ volatile("dsb sy" ::: "memory");
#endif
    CMD(1U); // No subsequent physical SOF is allowed without this DMA credit.
    prepared[slot]=0;
    elapsed=qr_perf_us(start,qr_perf_now());
    if(elapsed>rearm_max) rearm_max=elapsed;
done:
    servicing=0;
}
int frame_receiver_failed(void) {return faults!=0;}
int frame_receiver_take(u32 frame_id,u8 **image)
{
    int slot;
    frame_receiver_service();
    if(faults) return XST_FAILURE;
    slot=qr_gray_ring_take(&ring,frame_id);
    if(slot<0) {fail("candidate/Gray8 pairing"); return XST_FAILURE;}
    *image=images+slot*image_bytes; ++taken;
    return XST_SUCCESS;
}
int frame_receiver_release(void)
{
    int slot=qr_gray_ring_release(&ring);
    if(slot<0) {fail("CPU release"); return XST_FAILURE;}
    prepare_free(slot);
    frame_receiver_service();
    return faults ? XST_FAILURE : XST_SUCCESS;
}
void frame_receiver_dispatch(void) {if(enabled) CMD(2U);}
void frame_receiver_report(u32 capture_skips)
{
    runtime_log_printf("[QUEUE] accepted=%lu image_done=%lu received=%lu taken=%lu released=%lu pl_err=%08lx ps_err=%lu no_slot_polls=%lu rearm_max_us=%lu next_id=%lu capture_skips_total=%lu prepare_max_us=%lu\r\n",
        RD(0x18),RD(0x1c),received,taken,RD(0x20),RD(0x24),faults,no_slot,rearm_max,RD(0x10),capture_skips,prepare_max);
    no_slot=rearm_max=prepare_max=0;
}
