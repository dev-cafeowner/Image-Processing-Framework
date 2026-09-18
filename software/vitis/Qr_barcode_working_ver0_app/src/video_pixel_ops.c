#include "video_pixel_ops.h"
#include <string.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

int video_pixel_ops_uses_neon(void)
{
#if defined(__ARM_NEON)
    return 1;
#else
    return 0;
#endif
}

void video_bgr888_to_gray_rgb888(uint8_t *dst, const uint8_t *src, size_t pixels)
{
#if defined(__ARM_NEON)
    const uint8x8_t cb = vdup_n_u8(29), cg = vdup_n_u8(150), cr = vdup_n_u8(77);
    for (; pixels >= 8; pixels -= 8, src += 24, dst += 24) {
        uint8x8x3_t color = vld3_u8(src), gray;
        uint16x8_t sum = vmull_u8(color.val[0], cb);
        sum = vmlal_u8(sum, color.val[1], cg);
        sum = vmlal_u8(sum, color.val[2], cr);
        gray.val[0] = vshrn_n_u16(sum, 8);
        gray.val[1] = gray.val[0];
        gray.val[2] = gray.val[0];
        vst3_u8(dst, gray);
    }
#endif
    for (; pixels; --pixels, src += 3, dst += 3) {
        uint8_t gray = (uint8_t)((29U*src[0] + 150U*src[1] + 77U*src[2]) >> 8);
        dst[0] = gray; dst[1] = gray; dst[2] = gray;
    }
}

void video_gray8_to_rgb888(uint8_t *dst, const uint8_t *src, size_t pixels)
{
#if defined(__ARM_NEON)
    for (; pixels >= 8; pixels -= 8, src += 8, dst += 24) {
        uint8x8x3_t gray;
        gray.val[0] = vld1_u8(src);
        gray.val[1] = gray.val[0];
        gray.val[2] = gray.val[0];
        vst3_u8(dst, gray);
    }
#endif
    for (; pixels; --pixels, ++src, dst += 3) {
        dst[0] = *src; dst[1] = *src; dst[2] = *src;
    }
}

/* Runs on both host and board; on Cortex-A9 it tests the actual SIMD code.
 * Every RGB888 value plus unaligned buffers, vector tails and guard bytes.
 * Invoked only in the diagnostic build, never in the streaming loop. */
int video_pixel_ops_self_test(void)
{
    uint8_t src[256*3+2], dst[256*3+2], gray[256];
    uint32_t base, i, count;
    for (base = 0; base < 0x1000000U; base += 256) {
        for (i = 0; i < 256; ++i) {
            src[1+3*i] = (uint8_t)(base+i);
            src[2+3*i] = (uint8_t)((base+i) >> 8);
            src[3+3*i] = (uint8_t)((base+i) >> 16);
        }
        memset(dst, 0xa5, sizeof(dst));
        video_bgr888_to_gray_rgb888(dst+1, src+1, 256);
        for (i = 0; i < 256; ++i) {
            gray[i] = (uint8_t)((29U*src[1+3*i] + 150U*src[2+3*i] +
                                  77U*src[3+3*i]) >> 8);
            if (dst[1+3*i] != gray[i] || dst[2+3*i] != gray[i] ||
                dst[3+3*i] != gray[i]) return 1;
        }
        if (dst[0] != 0xa5 || dst[sizeof(dst)-1] != 0xa5) return 2;
    }
    for (count = 0; count <= 256; ++count) {
        memset(dst, 0xa5, sizeof(dst));
        video_gray8_to_rgb888(dst+1, gray, count);
        for (i = 0; i < count*3; ++i) if (dst[i+1] != gray[i/3]) return 3;
        for (i = count*3+1; i < sizeof(dst); ++i) if (dst[i] != 0xa5) return 4;
        if (dst[0] != 0xa5) return 5;
        memset(dst, 0xa5, sizeof(dst));
        video_bgr888_to_gray_rgb888(dst+1, src+1, count);
        for (i = 0; i < count*3; ++i) if (dst[i+1] != gray[i/3]) return 6;
        for (i = count*3+1; i < sizeof(dst); ++i) if (dst[i] != 0xa5) return 7;
        if (dst[0] != 0xa5) return 8;
    }
    return 0;
}
