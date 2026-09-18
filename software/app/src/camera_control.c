#include "camera_control.h"
#include "qr_perf.h"
#include "xil_io.h"
#include "xparameters.h"
#include "runtime_log.h"
#include "sleep.h"

#ifndef QR_CAMERA_DRIVE
#define QR_CAMERA_DRIVE 1
#endif
#if QR_CAMERA_DRIVE < 0 || QR_CAMERA_DRIVE > 3
#error "Invalid COM2 output drive setting"
#endif

static u32 rd(u32 offset) { return Xil_In32(XPAR_OV7670_AXIS_0_BASEADDR + offset); }
static XTime last;
static u32 prev_ticks, prev_frames, prev_pixels;

int camera_control_check(void)
{
    const u32 expected_version =
#if QR_CAMERA_CLEAN_PCLK
        0x00030000U;
#else
        0x00020000U;
#endif
    if (rd(0x0cU) != expected_version || rd(0x10U) != 0x43414d33U || !(rd(0x30U)&1U)) {
        runtime_log_printf("[FAIL] CAM3/24MHz clock hardware missing; sensor speed unchanged\r\n");
        return XST_FAILURE;
    }
    return XST_SUCCESS;
}

int camera_control_sensor_check(ov7670_t *camera)
{
    u8 com10, com11, com14, pll, ysc, com2;
    if (ov7670_read_reg(camera, 0x15U, &com10) ||
        ov7670_read_reg(camera, 0x3bU, &com11) ||
        ov7670_read_reg(camera, 0x3eU, &com14) ||
        ov7670_read_reg(camera, 0x6bU, &pll) ||
        ov7670_read_reg(camera, 0x71U, &ysc) ||
        ov7670_read_reg(camera, 0x09U, &com2)) return XST_FAILURE;
    // Continuous, normal-polarity PCLK; no night frame extension/scaling.
    // Preserve the DBLV regulator bits: never overwrite the complete register.
    if ((com10 & 0x32U) || (com11 & 0x80U) || (com14 & 0x18U) || (pll & 0xc0U)) {
        runtime_log_printf("[FAIL] Unexpected camera sensor timing registers\r\n");
        return XST_FAILURE;
    }
#if QR_CAMERA_COLORBARS
    if (ov7670_write_reg(camera, 0x71U, ysc | 0x80U) ||
        ov7670_read_reg(camera, 0x71U, &ysc) || !(ysc & 0x80U)) return XST_FAILURE;
#endif
    /* Only documented drive bits change; preserve sleep/reserved bits. */
    if (ov7670_write_reg(camera, 0x09U, (com2 & 0xfcU) | QR_CAMERA_DRIVE) ||
        ov7670_read_reg(camera, 0x09U, &com2) ||
        (com2 & 3U) != QR_CAMERA_DRIVE) return XST_FAILURE;
#if QR_CAMERA_CLEAN_PCLK
    /* Arm only once the returned PCLK is in the validated 24MHz profile.
     * Main camera-clock lock is independent and was checked before SCCB. */
    {
        u8 clkrc;
        if (ov7670_read_reg(camera, 0x11U, &clkrc) || clkrc != 0x80U)
            return XST_FAILURE;
        Xil_Out32(XPAR_OV7670_AXIS_0_BASEADDR + 0x34U, 1U);
    }
#endif
    runtime_log_printf("[CAM3 CONFIG] xclk_hz=24000000 com10=%02x com11=%02x com14=%02x dblv=%02x ysc=%02x com2=%02x pattern=%lu\r\n",
        com10,com11,com14,pll,ysc,com2,(u32)QR_CAMERA_COLORBARS);
    prev_ticks=rd(0x14U); prev_frames=rd(0x18U); prev_pixels=rd(0x1cU); last=qr_perf_now();
    return XST_SUCCESS;
}

int camera_control_validate_input(void)
{
    /* Receiver measures even with capture disabled. Reject malformed sensor
     * lines before arming video; do not clear evidence to hide an error. */
    u32 frames=rd(0x18U), lost=rd(0x20U), bad=rd(0x24U), status;
    usleep(500000U);
    frames=rd(0x18U)-frames; lost=rd(0x20U)-lost; bad=rd(0x24U)-bad;
    status=rd(4U);
#if QR_CAMERA_CLEAN_PCLK
    runtime_log_printf("[RXCLK] status=%08lx losses=%lu\r\n",rd(0x34U),rd(0x38U));
    if (rd(0x34U) != 3U || rd(0x38U) != 0U) {
        runtime_log_printf("[FAIL] Returned PCLK not stably locked; camera stream stays disabled\r\n");
        return XST_FAILURE;
    }
#endif
    runtime_log_printf("[CAM3 PREFLIGHT] frames=%lu lost=%lu bad_lines=%lu status=%08lx\r\n",frames,lost,bad,status);
    if (frames < 3U || lost || bad || (status & 0x01ffffffU) != 0x001e0280U || !(rd(0x30U)&1U)) {
        runtime_log_printf("[FAIL] Camera input malformed before capture; camera stream stays disabled\r\n");
        return XST_FAILURE;
    }
    return XST_SUCCESS;
}

void camera_control_report(void)
{
    XTime now=qr_perf_now();
    u32 ticks=rd(0x14U), frames=rd(0x18U), pixels=rd(0x1cU);
    // Sequential MMIO read skew is tiny versus a ~1-second window, not zero.
    runtime_log_printf("[CAM3] window_us=%lu pclk_edges=%lu sensor_frames=%lu pixels=%lu total_frames=%lu lost_tokens=%lu bad_lines=%lu fifo_peak=%lu status=%08lx period_cycles=%lu max_period_cycles=%lu clock=%lu\r\n",
        qr_perf_us(last,now),ticks-prev_ticks,frames-prev_frames,pixels-prev_pixels,frames,
        rd(0x20U),rd(0x24U),rd(8U)>>16,rd(4U),rd(0x28U),rd(0x2cU),rd(0x30U)&1U);
    last=now; prev_ticks=ticks; prev_frames=frames; prev_pixels=pixels;
#if QR_CAMERA_CLEAN_PCLK
    runtime_log_printf("[RXCLK] status=%08lx losses=%lu\r\n",rd(0x34U),rd(0x38U));
#endif
}

void camera_control_pattern_report(const u8 *gray, u32 frame)
{
#if QR_CAMERA_COLORBARS
    // Diagnostic only. This observes the immutable, frame-ID checked QR DMA
    // snapshot; it never alters input pixels or skips the normal QR pipeline.
    u32 x,y,crc=2166136261U,row_mismatches=0;
    for(y=0;y<480U;++y) for(x=0;x<640U;++x) {
        u8 v=gray[y*640U+x]; crc=(crc^v)*16777619U;
        if(v!=gray[x]) ++row_mismatches;
    }
    if(frame<10U || frame%30U==0U)
        runtime_log_printf("[PATTERN] n=%lu hash=%08lx row_mismatch_pixels=%lu samples=%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu\r\n",
            frame,crc,row_mismatches,(u32)gray[40],(u32)gray[120],(u32)gray[200],(u32)gray[280],
            (u32)gray[360],(u32)gray[440],(u32)gray[520],(u32)gray[600]);
#else
    (void)gray; (void)frame;
#endif
}
