#include "qr_pingpong.h"
#include "xiltimer.h"
#include "xil_cache.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
static u32 regfile[16],sr,arms,credits,dispatches,flushes,invalidates;
static int busy,arm_error; static UINTPTR destination; static u32 length;
static u8 buffers[2][64]; static qr_dma_s2mm_t dma;
static unsigned cleaned[2];
u32 Xil_In32(UINTPTR addr){assert(addr>=0x43c40000U && addr<0x43c40040U); return regfile[(addr-0x43c40000U)/4];}
void Xil_Out32(UINTPTR addr,u32 value){
    assert(addr==0x43c40008U);
    if(value&1){assert(busy && !credits); credits=1;}
    if(value&2) ++dispatches;
}
void Xil_DCacheFlushRange(INTPTR addr,u32 bytes){assert((!busy || (UINTPTR)addr!=destination) && bytes==64); ++flushes;}
void Xil_DCacheInvalidateRange(INTPTR addr,u32 bytes){
    assert((!busy || (UINTPTR)addr!=destination) && bytes==64); ++invalidates;
    cleaned[((UINTPTR)addr-(UINTPTR)buffers)/64]=1;
}
void XTime_GetTime(XTime *t){static XTime now; *t=++now;}
void runtime_log_printf(const char *format,...){(void)format;}
int qr_dma_s2mm_arm(qr_dma_s2mm_t *d,UINTPTR addr,u32 bytes){
    assert(d==&dma && !busy && !credits && cleaned[(addr-(UINTPTR)buffers)/64]);
    if(arm_error)return XST_FAILURE;
    ++arms; cleaned[(addr-(UINTPTR)buffers)/64]=0; destination=addr; length=bytes; busy=1; return XST_SUCCESS;
}
int qr_dma_s2mm_busy(const qr_dma_s2mm_t *d){assert(d==&dma);return busy;}
u32 qr_dma_s2mm_status(const qr_dma_s2mm_t *d){assert(d==&dma);return sr;}
static void reset(void){
    memset(regfile,0,sizeof(regfile)); regfile[0]=0x51505031;regfile[1]=0x10000;regfile[11]=0x01e00280;
    memset(buffers,0,sizeof(buffers));memset(cleaned,0,sizeof(cleaned));sr=arms=credits=dispatches=flushes=invalidates=0;busy=arm_error=0;
}
static void capture_complete(u8 value){
    assert(credits && busy);credits=0;
    regfile[5]=regfile[4]++; ++regfile[6]; ++regfile[7];
    memset((void *)destination,value,length);busy=0;
}
int main(void){
    u8 *cpu; reset();
    assert(qr_pingpong_init(&dma,&buffers[0][0],64)==XST_SUCCESS && arms==1 && credits==1 && dispatches==1);
    capture_complete(0x31);qr_pingpong_service();
    assert(arms==2 && credits==1); // rearmed BEFORE any candidate take or ACK
    assert(qr_pingpong_take(0,&cpu)==XST_SUCCESS && cpu==buffers[0]);
    capture_complete(0x42);
    for(int k=0;k<100;k++){qr_pingpong_service(); assert(arms==2 && !credits);}
    for(int i=0;i<64;i++) assert(cpu[i]==0x31);
    assert(qr_pingpong_release()==XST_SUCCESS && arms==3 && credits==1);
    assert(qr_pingpong_take(1,&cpu)==XST_SUCCESS && cpu==buffers[1]);
    capture_complete(0x53);qr_pingpong_service();
    for(int i=0;i<64;i++)assert(cpu[i]==0x42);
    assert(qr_pingpong_release()==XST_SUCCESS && arms==4);
    assert(qr_pingpong_take(2,&cpu)==XST_SUCCESS && cpu==buffers[0] && cpu[0]==0x53);
    for(int fault=0;fault<5;fault++){
        reset(); assert(qr_pingpong_init(&dma,&buffers[0][0],64)==XST_SUCCESS);
        capture_complete(7);
        if(fault==0)regfile[5]=99; // wrong physical image ID
        if(fault==1)regfile[7]=2;  // missing completion
        if(fault==2)sr=0x10;      // DMA error
        if(fault==3)regfile[9]=8; // hardware ownership error
        if(fault==4)arm_error=1;  // rearm must not grant camera credit
        qr_pingpong_service();
        assert(qr_pingpong_failed() && arms==1 && credits==0);
        assert(qr_pingpong_take(0,&cpu)==XST_FAILURE);
    }
    reset();regfile[0]=0;assert(qr_pingpong_init(&dma,&buffers[0][0],64)==XST_FAILURE && arms==0);
    puts("PASS: actual PS receiver, immediate rearm, cache preparation, delayed CPU ownership, pairing, DMA/count/ID/ABI failures");
    return 0;
}
