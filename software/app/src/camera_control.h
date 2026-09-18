#ifndef CAMERA_CONTROL_H
#define CAMERA_CONTROL_H
#include "ov7670.h"
int camera_control_check(void);
int camera_control_sensor_check(ov7670_t *camera);
int camera_control_validate_input(void);
void camera_control_report(void);
void camera_control_pattern_report(const u8 *gray, u32 frame);
#endif
