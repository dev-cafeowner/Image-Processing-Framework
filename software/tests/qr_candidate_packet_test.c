#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "qr_candidate_packet.h"
static uint32_t w[85];
static qr_candidate_packet_t p;
static void fixture(unsigned n) {
    unsigned i;
    memset(w,0,sizeof(w));
    w[0]=0x51525031U; w[1]=0x01050500U; w[2]=42;
    w[3]=((5+5*n)<<16)|(n<<8)|1;
    for(i=0;i<n;++i) {
        w[5+5*i]=(3U<<13)|i;
        w[6+5*i]=(10U<<20)|(12U<<10)|10U;
        w[7+5*i]=12; w[8+5*i]=33; w[9+5*i]=33;
    }
}
static void reject(int reason) {
    p.count=99;
    assert(qr_candidate_packet_parse(w,10,42,1,&p)==reason);
    assert(p.count==0);
}
int main(void) {
    unsigned i;
    for(i=0;i<=16;++i) {
        fixture(i);
        assert(qr_candidate_packet_parse(w,5+5*i,42,i,&p)==0);
        assert(p.count==i && p.frame_id==42);
    }
    fixture(1); w[0]^=1; reject(QR_PACKET_SCHEMA);
    fixture(1); w[1]^=1; reject(QR_PACKET_SCHEMA);
    fixture(1); w[3]^=3; reject(QR_PACKET_SCHEMA);
    fixture(1); w[2]=43; reject(QR_PACKET_FRAME);
    fixture(1); w[3]^=1U<<16; reject(QR_PACKET_COUNT);
    fixture(1); w[4]=1; reject(QR_PACKET_PL_ERROR);
    fixture(1); w[5]|=1U<<5; reject(QR_PACKET_RECORD);
    fixture(1); w[6]|=1U<<29; reject(QR_PACKET_RECORD);
    fixture(1); w[7]|=1U<<9; reject(QR_PACKET_RECORD);
    fixture(1); w[8]|=1U<<28; reject(QR_PACKET_RECORD);
    fixture(1); w[5]=2U<<13; reject(QR_PACKET_RECORD);
    fixture(1); w[5]=257U<<13; reject(QR_PACKET_RECORD);
    fixture(1); w[6]=(10U<<20)|(640U<<10)|10U; reject(QR_PACKET_COORDINATE);
    fixture(1); w[7]=480; reject(QR_PACKET_COORDINATE);
    fixture(1); w[7]=9; reject(QR_PACKET_COORDINATE);
    fixture(1); w[8]=29; reject(QR_PACKET_SUM);
    fixture(1); w[9]=37; reject(QR_PACKET_SUM);
    fixture(2); w[10]&=~31U;
    assert(qr_candidate_packet_parse(w,15,42,2,&p)==QR_PACKET_RECORD && !p.count);
    fixture(1);
    for(i=0;i<5;++i) assert(qr_candidate_packet_parse(w,i,42,1,&p)==QR_PACKET_LENGTH);
    assert(qr_candidate_packet_parse(w,86,42,1,&p)==QR_PACKET_LENGTH);
    assert(qr_candidate_packet_parse(NULL,10,42,1,&p)==QR_PACKET_LENGTH);
    assert(qr_candidate_packet_parse(w,10,42,1,NULL)==QR_PACKET_RECORD);
    assert(qr_candidate_packet_parse(w,10,42,0,&p)==QR_PACKET_COUNT);
    puts("PASS: QRP1 count/length/schema/frame/errors/labels/bounds/sums and empty/max records");
    return 0;
}
