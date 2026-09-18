#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "video_pixel_ops.h"

static uint8_t src[640U * 480U * 3U + 2U];
static uint8_t gray[640U * 480U];
static uint8_t expected[sizeof(src)];
static uint8_t actual[sizeof(src)];

static int check(size_t pixels, size_t offset)
{
    size_t i;
    memset(expected, 0xa5, sizeof(expected));
    memset(actual, 0xa5, sizeof(actual));
    /* Original implementation: BGR -> Gray8 -> RGB888, two passes. */
    for (i = 0; i < pixels; ++i) {
        const uint8_t *p = src + offset + i * 3;
        gray[i] = (uint8_t)((29U * p[0] + 150U * p[1] + 77U * p[2]) >> 8);
    }
    for (i = 0; i < pixels; ++i) {
        expected[offset + i * 3] = gray[i];
        expected[offset + i * 3 + 1] = gray[i];
        expected[offset + i * 3 + 2] = gray[i];
    }
    video_bgr888_to_gray_rgb888(actual + offset, src + offset, pixels);
    if (memcmp(actual, expected, sizeof(actual))) return 1;
    memset(actual, 0xa5, sizeof(actual));
    video_gray8_to_rgb888(actual + offset, gray, pixels);
    return memcmp(actual, expected, sizeof(actual)) != 0;
}

int main(void)
{
    uint32_t base, i, state = 12345U;
    if (video_pixel_ops_self_test()) return 3;
    /* All 16,777,216 possible RGB888 inputs, plus boundary/unaligned buffers. */
    for (base = 0; base < 0x1000000U; base += 65536U) {
        for (i = 0; i < 65536U; ++i) {
            uint32_t p = base + i;
            src[1 + i * 3] = (uint8_t)p;
            src[2 + i * 3] = (uint8_t)(p >> 8);
            src[3 + i * 3] = (uint8_t)(p >> 16);
        }
        if (check(65536U, 1U)) return 1;
    }
    for (i = 0; i < sizeof(src); ++i) {
        state = 1664525U * state + 1013904223U;
        src[i] = (uint8_t)(state >> 24);
    }
    if (check(0, 1) || check(1, 1) || check(37, 1) ||
        check(640U * 480U, 1) || check(640U * 416U, 0)) return 2;
    puts("PASS: all RGB888 colors, VGA frame, unaligned and boundary guards");
    return 0;
}
