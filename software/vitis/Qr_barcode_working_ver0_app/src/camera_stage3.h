#ifndef CAMERA_STAGE3_H
#define CAMERA_STAGE3_H
#include "ov7670.h"
int camera_stage3_check(void);
int camera_stage3_sensor_check(ov7670_t *camera);
int camera_stage3_validate_input(void);
void camera_stage3_report(void);
void camera_stage3_pattern_report(const u8 *gray, u32 frame);
#endif
