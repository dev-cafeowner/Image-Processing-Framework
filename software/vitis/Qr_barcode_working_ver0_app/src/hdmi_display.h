#ifndef HDMI_DISPLAY_H
#define HDMI_DISPLAY_H

#include "xil_types.h"
#include "xstatus.h"

#include "display_ctrl/display_ctrl.h"
#include "video_vdma.h"


#define HDMI_DISPLAY_WIDTH            640U
#define HDMI_DISPLAY_HEIGHT           480U
#define HDMI_DISPLAY_BYTES_PER_PIXEL  3U

#define HDMI_DISPLAY_STRIDE           \
    (HDMI_DISPLAY_WIDTH * HDMI_DISPLAY_BYTES_PER_PIXEL)

#define HDMI_DISPLAY_FRAME_BYTES      \
    (HDMI_DISPLAY_STRIDE * HDMI_DISPLAY_HEIGHT)


typedef struct
{
    DisplayCtrl display;
    int initialized;
    int render_frame; /* -1: no CPU reservation; single-threaded renderer only. */

} hdmi_display_t;


/*
 * video_vdma_s2mm_init_start()로 이미 초기화된
 * 동일 AXI VDMA instance의 MM2S/READ 채널을 HDMI용으로 사용한다.
 */
int hdmi_display_init(
    hdmi_display_t *hdmi,
    video_vdma_s2mm_t *video_vdma
);


/*
 * 640x480 Gray8 이미지를 RGB888 framebuffer로 변환해서 표시한다.
 */
int hdmi_display_show_gray8(
    hdmi_display_t *hdmi,
    const u8 *gray
);

/* Reserve a buffer that is neither scanned out nor pending. Render, then
 * commit (flush + schedule), or cancel if the capture source changed.
 * No writes to VDMA-owned capture/scanout buffers are permitted.
 */
u8 *hdmi_display_begin_frame(hdmi_display_t *hdmi);
int hdmi_display_commit_frame(hdmi_display_t *hdmi);
void hdmi_display_cancel_frame(hdmi_display_t *hdmi);


/*
 * Most recently submitted HDMI framebuffer address (switches at frame end).
 */
UINTPTR hdmi_display_frame_addr(void);


#endif
