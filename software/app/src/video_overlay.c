#include "video_overlay.h"
#include "xil_io.h"
#include "xstatus.h"
#include "runtime_log.h"
#include "qr_perf.h"
#include "xaxivdma_hw.h"

static u32 last_camera, last_scan, last_ticks, hud_updates;
static u64 hud_total_us;
static u32 hud_max_us;
static u64 hud_cpu_total_us;
static u32 hud_cpu_max_us;
static int initialized;
static u32 rd(u32 offset) { return Xil_In32(VIDEO_OVERLAY_BASE + offset); }

int video_overlay_init(void)
{
    initialized = 0;
    if (rd(0) != 0x50525631U) return XST_FAILURE;
    last_camera = rd(0x10); last_scan = rd(0x14); last_ticks = rd(0x34);
    hud_updates = hud_max_us = 0; hud_total_us = 0;
    hud_cpu_total_us = 0; hud_cpu_max_us = 0;
    initialized = 1;
    return XST_SUCCESS;
}

int video_overlay_ready(void)
{
    return initialized && !(rd(4) & 8U);
}

int video_overlay_submit(const u8 *gray)
{
    u32 status, bank, word, bit, value, us;
    XTime start;
    if (!initialized || !gray) return XST_FAILURE;
    status = rd(4);
    if (status & 8U) return XST_FAILURE;
    bank = ((status >> 2) & 1U) ^ 1U;
    start = qr_perf_now();
    for (word = 0; word < VIDEO_OVERLAY_WIDTH * VIDEO_OVERLAY_HEIGHT / 32U; ++word) {
        value = 0;
        for (bit = 0; bit < 32; ++bit)
            value |= (u32)(gray[word*32U + bit] >= 128U) << bit;
        Xil_Out32(VIDEO_OVERLAY_BASE + 0x2000U + bank*0x2000U + word*4U, value);
    }
    // Device writes complete before publishing bank ownership to the stream.
#if defined(__arm__)
    __asm__ volatile ("dsb sy" ::: "memory");
#else
    __sync_synchronize(); /* Native MMIO-mock regression; same ordering intent. */
#endif
    Xil_Out32(VIDEO_OVERLAY_BASE + 8U, 3U | (bank << 2));
    us = qr_perf_us(start, qr_perf_now());
    ++hud_updates; hud_total_us += us;
    if (us > hud_max_us) hud_max_us = us;
    return XST_SUCCESS;
}

void video_overlay_cpu_time(u32 us)
{
    hud_cpu_total_us += us;
    if (us > hud_cpu_max_us) hud_cpu_max_us = us;
}

void video_overlay_report(u32 mm2s_status)
{
    u32 camera, scan, ticks, elapsed;
    if (!initialized) return;
    camera = rd(0x10); scan = rd(0x14); ticks = rd(0x34);
    elapsed = (u32)(((u64)(u32)(ticks-last_ticks)*2U)/125U);
    // scan_sof includes repeats at HDMI cadence: NEVER label it camera fps.
    runtime_log_printf("[VIDEO] window_us=%lu camera_sof=%lu scan_sof=%lu total_camera=%lu total_scan=%lu camera_gap_max_us=%lu scan_gap_max_us=%lu geometry_errors=%lu rejected=%lu mm2s_err=%08lx hud=%lu hud_avg_us=%lu hud_max_us=%lu hud_cpu_avg_us=%lu hud_cpu_max_us=%lu\r\n",
        elapsed, camera-last_camera, scan-last_scan, camera, scan,
        (u32)(((u64)rd(0x20)*2U)/125U), (u32)(((u64)rd(0x24)*2U)/125U),
        rd(0x2c), rd(0x28), mm2s_status & (XAXIVDMA_SR_ERR_ALL_MASK | XAXIVDMA_SR_HALTED_MASK), hud_updates,
        hud_updates ? (u32)(hud_total_us/hud_updates) : 0U, hud_max_us,
        hud_updates ? (u32)(hud_cpu_total_us/hud_updates) : 0U, hud_cpu_max_us);
    last_camera=camera; last_scan=scan; last_ticks=ticks;
    hud_updates=hud_max_us=0; hud_total_us=0;
    hud_cpu_total_us=0; hud_cpu_max_us=0;
}
