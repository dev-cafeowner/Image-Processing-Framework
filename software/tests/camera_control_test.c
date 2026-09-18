#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "camera_control.h"
#include "xiltimer.h"
static u32 regs[15], delta_frames, delta_lost, delta_bad;
static u8 sensor[256];
static int read_fail, write_fail;
u32 Xil_In32(UINTPTR address) {
    assert(address>=0x40010000U && address<=0x40010038U && !(address&3));
    return regs[(address-0x40010000U)/4];
}
void Xil_Out32(UINTPTR address, u32 value) {
    assert(address==0x40010034U && value==1U);
    regs[13]=3U;
}
void usleep(unsigned long us) {
    assert(us==500000U);
    regs[6]+=delta_frames; regs[8]+=delta_lost; regs[9]+=delta_bad;
}
void XTime_GetTime(XTime *t) {*t=1000000U;}
void runtime_log_printf(const char *format,...) {(void)format;}
int ov7670_read_reg(ov7670_t *c,u8 reg,u8 *value) {
    (void)c; *value=sensor[reg]; return read_fail;
}
int ov7670_write_reg(ov7670_t *c,u8 reg,u8 value) {
    (void)c; if(!write_fail) sensor[reg]=value; return write_fail;
}
static void good(void) {
    memset(regs,0,sizeof(regs));
    regs[1]=0x021e0280U; regs[3]=0x00020000U; regs[4]=0x43414d33U; regs[12]=1;
#if QR_CAMERA_CLEAN_PCLK
    regs[3]=0x00030000U; regs[13]=3U;
#endif
    delta_frames=15; delta_lost=0; delta_bad=0;
}
int main(void) {
    ov7670_t camera;
    assert(sizeof(u32)==4);
    good(); assert(camera_control_check()==XST_SUCCESS);
    regs[4]=0; assert(camera_control_check()==XST_FAILURE);
    good(); regs[12]=0; assert(camera_control_check()==XST_FAILURE);
    good(); assert(camera_control_validate_input()==XST_SUCCESS);
    good(); regs[6]=0xfffffff8UL; assert(camera_control_validate_input()==XST_SUCCESS);
    good(); delta_frames=2; assert(camera_control_validate_input()==XST_FAILURE);
    good(); delta_lost=1; assert(camera_control_validate_input()==XST_FAILURE);
    good(); delta_bad=1; assert(camera_control_validate_input()==XST_FAILURE);
    good(); regs[1]|=0x01000000U; assert(camera_control_validate_input()==XST_FAILURE);
    good(); regs[1]--; assert(camera_control_validate_input()==XST_FAILURE);
    good(); regs[1]-=0x1000U; assert(camera_control_validate_input()==XST_FAILURE);
    good(); regs[12]=0; assert(camera_control_validate_input()==XST_FAILURE);
#if QR_CAMERA_CLEAN_PCLK
    good(); regs[13]=1; assert(camera_control_validate_input()==XST_FAILURE);
    good(); regs[13]=7; assert(camera_control_validate_input()==XST_FAILURE);
    good(); regs[14]=1; assert(camera_control_validate_input()==XST_FAILURE);
    good();
#endif
    memset(sensor,0,sizeof(sensor)); sensor[9]=0xacU; sensor[0x6b]=0x0a;
    sensor[0x11]=0x80;
    assert(camera_control_sensor_check(&camera)==XST_SUCCESS);
    assert(sensor[9]==(0xacU|QR_CAMERA_DRIVE)); assert(sensor[0x6b]==0x0a);
    assert(sensor[0x71]==(QR_CAMERA_COLORBARS ? 0x80U : 0U));
    sensor[0x15]=0x10; assert(camera_control_sensor_check(&camera)==XST_FAILURE); sensor[0x15]=0;
    sensor[0x3b]=0x80; assert(camera_control_sensor_check(&camera)==XST_FAILURE); sensor[0x3b]=0;
    sensor[0x3e]=0x08; assert(camera_control_sensor_check(&camera)==XST_FAILURE); sensor[0x3e]=0;
    sensor[0x6b]=0x4a; assert(camera_control_sensor_check(&camera)==XST_FAILURE); sensor[0x6b]=0x0a;
#if QR_CAMERA_CLEAN_PCLK
    sensor[0x11]=0x81; assert(camera_control_sensor_check(&camera)==XST_FAILURE); sensor[0x11]=0x80;
#endif
    read_fail=1; assert(camera_control_sensor_check(&camera)==XST_FAILURE); read_fail=0;
    write_fail=1; assert(camera_control_sensor_check(&camera)==XST_FAILURE);
    puts("PASS: CAM3 signature/lock, malformed-input gate, counter wrap, COM2 masked write, sensor timing/read/write failures");
    return 0;
}
