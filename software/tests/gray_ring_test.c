#include "qr_gray_ring.h"
#include <assert.h>
#include <stdio.h>
int main(void)
{
    qr_gray_ring_t r; uint32_t id=0xfffffffeU; int a,b;
    qr_gray_ring_init(&r);
    assert(qr_gray_ring_take(&r,id)<0 && qr_gray_ring_release(&r)<0);
    for(unsigned n=0;n<10000;n++,id+=2) {
        a=qr_gray_ring_reserve(&r,id); assert(a>=0);
        assert(qr_gray_ring_reserve(&r,id+1)<0);
        assert(qr_gray_ring_complete(&r,id+1)<0); // mismatched DMA stays owned
        assert(r.state[a]==QR_SLOT_DMA);
        assert(qr_gray_ring_complete(&r,id)==a);
        b=qr_gray_ring_reserve(&r,id+1); assert(b>=0 && b!=a);
        assert(qr_gray_ring_take(&r,id)==a);
        assert(qr_gray_ring_complete(&r,id+1)==b);
        // Long CPU/fallback stalls: never overwrite either CPU or READY storage.
        for(int k=0;k<10;k++) assert(qr_gray_ring_reserve(&r,id+2)<0);
        assert(r.state[a]==QR_SLOT_CPU && r.state[b]==QR_SLOT_READY);
        assert(qr_gray_ring_take(&r,id+1)<0);
        assert(qr_gray_ring_release(&r)==a);
        assert(qr_gray_ring_take(&r,id)<0); // never repeat a stale payload
        assert(qr_gray_ring_take(&r,id+1)==b);
        assert(qr_gray_ring_release(&r)==b);
    }
    puts("PASS: 20000 Gray8 frames, wrap, delayed CPU, no overwrite, mismatch/stale rejection");
    return 0;
}
