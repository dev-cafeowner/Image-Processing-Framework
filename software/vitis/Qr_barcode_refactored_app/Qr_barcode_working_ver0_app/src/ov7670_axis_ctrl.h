#ifndef OV7670_AXIS_CTRL_H
#define OV7670_AXIS_CTRL_H

#include "xil_types.h"
#include "xstatus.h"

/* ---------------------------------------------------------
 * OV7670 AXIS control
 * --------------------------------------------------------- */

/* Capture producer ON/OFF */
int  ov7670_axis_capture_enable(void);
void ov7670_axis_capture_disable(void);

/* Sticky/statistics clear pulse */
void ov7670_axis_stat_clear(void);

/* Register readback */
u32 ov7670_axis_read_control(void);
u32 ov7670_axis_read_cam_status(void);
u32 ov7670_axis_read_fifo_status(void);
u32 ov7670_axis_read_version(void);

#endif /* OV7670_AXIS_CTRL_H */