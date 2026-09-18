#ifndef VIDEO_OVERLAY_H
#define VIDEO_OVERLAY_H
#include "xil_types.h"
// Common bitmap HUD ABI, not a QR feature interface. No DDR framebuffer writes.
#define VIDEO_OVERLAY_BASE 0x43C30000U
#define VIDEO_OVERLAY_WIDTH 640U
#define VIDEO_OVERLAY_HEIGHT 64U
int video_overlay_init(void);
int video_overlay_ready(void);
int video_overlay_submit(const u8 *gray);
void video_overlay_cpu_time(u32 us);
void video_overlay_report(u32 mm2s_status);
#endif
