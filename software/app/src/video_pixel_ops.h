#ifndef VIDEO_PIXEL_OPS_H
#define VIDEO_PIXEL_OPS_H

#include <stddef.h>
#include <stdint.h>

/* Common display operation, independent of the selected recognition feature.
 * RGB888 AXIS words are stored as B,G,R bytes by the little-endian VDMA.
 * Exactly matches the previous Gray8 intermediate (no rounding change).
 * Source and destination must be separate, CPU-owned/readable buffers.
 */
void video_bgr888_to_gray_rgb888(uint8_t *dst, const uint8_t *src, size_t pixels);
void video_gray8_to_rgb888(uint8_t *dst, const uint8_t *src, size_t pixels);
int video_pixel_ops_self_test(void);
int video_pixel_ops_uses_neon(void);

#endif
