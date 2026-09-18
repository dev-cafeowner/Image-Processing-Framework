#ifndef QR_GRAY_RING_H
#define QR_GRAY_RING_H
#include <stdint.h>
#include <string.h>
enum { QR_SLOT_FREE, QR_SLOT_DMA, QR_SLOT_READY, QR_SLOT_CPU };
typedef struct {
    unsigned state[2]; uint32_t id[2]; int dma, cpu;
} qr_gray_ring_t;
static inline void qr_gray_ring_init(qr_gray_ring_t *r)
{ memset(r,0,sizeof(*r)); r->dma=-1; r->cpu=-1; }
static inline int qr_gray_ring_reserve(qr_gray_ring_t *r, uint32_t id)
{
    int i;
    if(r->dma>=0) return -1;
    for(i=0;i<2;i++) if(r->state[i]==QR_SLOT_FREE) {
        r->state[i]=QR_SLOT_DMA; r->id[i]=id; r->dma=i; return i;
    }
    return -1;
}
static inline int qr_gray_ring_complete(qr_gray_ring_t *r, uint32_t id)
{
    int i=r->dma;
    if(i<0 || r->state[i]!=QR_SLOT_DMA || r->id[i]!=id) return -1;
    r->state[i]=QR_SLOT_READY; r->dma=-1; return i;
}
static inline int qr_gray_ring_take(qr_gray_ring_t *r, uint32_t id)
{
    int i;
    if(r->cpu>=0) return -1;
    for(i=0;i<2;i++) if(r->state[i]==QR_SLOT_READY && r->id[i]==id) {
        r->state[i]=QR_SLOT_CPU; r->cpu=i; return i;
    }
    return -1;
}
static inline int qr_gray_ring_release(qr_gray_ring_t *r)
{
    int i=r->cpu;
    if(i<0 || r->state[i]!=QR_SLOT_CPU) return -1;
    r->state[i]=QR_SLOT_FREE; r->cpu=-1; return i;
}
#endif
