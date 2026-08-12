#include "ov7670_axis_ctrl.h"

#include "xparameters.h"
#include "xil_io.h"

/* ============================================================
 * OV7670 AXIS register map
 *
 * BASE + 0x00 : CONTROL
 *               bit0 = capture_en
 *               bit1 = stat_clear
 *
 * BASE + 0x04 : CAM_STATUS
 * BASE + 0x08 : FIFO_STATUS
 * BASE + 0x0C : IP_VERSION
 *
 * IP_VERSION expected:
 *     0x00010000
 * ============================================================ */

#define OV7670_AXIS_BASEADDR \
    XPAR_OV7670_AXIS_0_BASEADDR

#define OV7670_AXIS_REG_CONTROL      0x00U
#define OV7670_AXIS_REG_CAM_STATUS   0x04U
#define OV7670_AXIS_REG_FIFO_STATUS  0x08U
#define OV7670_AXIS_REG_VERSION      0x0CU

#define OV7670_AXIS_CTRL_CAPTURE_EN  (1U << 0)
#define OV7670_AXIS_CTRL_STAT_CLEAR  (1U << 1)


/* ============================================================
 * Internal register access
 * ============================================================ */

static u32 ov7670_axis_read_reg(u32 offset)
{
    return Xil_In32(
        OV7670_AXIS_BASEADDR + offset
    );
}


static void ov7670_axis_write_reg(
    u32 offset,
    u32 value
)
{
    Xil_Out32(
        OV7670_AXIS_BASEADDR + offset,
        value
    );
}


/* ============================================================
 * Public register reads
 * ============================================================ */

u32 ov7670_axis_read_control(void)
{
    return ov7670_axis_read_reg(
        OV7670_AXIS_REG_CONTROL
    );
}


u32 ov7670_axis_read_cam_status(void)
{
    return ov7670_axis_read_reg(
        OV7670_AXIS_REG_CAM_STATUS
    );
}


u32 ov7670_axis_read_fifo_status(void)
{
    return ov7670_axis_read_reg(
        OV7670_AXIS_REG_FIFO_STATUS
    );
}


u32 ov7670_axis_read_version(void)
{
    return ov7670_axis_read_reg(
        OV7670_AXIS_REG_VERSION
    );
}


/* ============================================================
 * Capture Disable
 *
 * CONTROL bit0 = 0
 *
 * Important:
 * ARM processor reset does not necessarily reset PL AXI
 * registers, so Stage 4-B explicitly calls this first.
 * ============================================================ */

void ov7670_axis_capture_disable(void)
{
    u32 control;

    control = ov7670_axis_read_control();

    control &= ~OV7670_AXIS_CTRL_CAPTURE_EN;

    /*
     * Do not accidentally generate stat_clear while disabling.
     */
    control &= ~OV7670_AXIS_CTRL_STAT_CLEAR;

    ov7670_axis_write_reg(
        OV7670_AXIS_REG_CONTROL,
        control
    );
}


/* ============================================================
 * Capture Enable
 *
 * CONTROL bit0 = 1
 *
 * Readback is checked immediately.
 * ============================================================ */

int ov7670_axis_capture_enable(void)
{
    u32 control;

    control = ov7670_axis_read_control();

    control |= OV7670_AXIS_CTRL_CAPTURE_EN;
    control &= ~OV7670_AXIS_CTRL_STAT_CLEAR;

    ov7670_axis_write_reg(
        OV7670_AXIS_REG_CONTROL,
        control
    );


    /*
     * Verify that the hardware register actually latched bit0.
     *
     * This is equivalent to the XSDB test:
     *
     *   mwr 0x40010000 0x1
     *   mrd 0x40010000 1
     */
    control = ov7670_axis_read_control();

    if ((control & OV7670_AXIS_CTRL_CAPTURE_EN) == 0U) {

        return XST_FAILURE;
    }

    return XST_SUCCESS;
}


/* ============================================================
 * Statistics/status clear pulse
 *
 * Preserve current capture_en state while pulsing bit1.
 * ============================================================ */

void ov7670_axis_stat_clear(void)
{
    u32 control;

    control = ov7670_axis_read_control();

    /*
     * Only persistent bit that must be preserved here is
     * capture_en.
     */
    control &= OV7670_AXIS_CTRL_CAPTURE_EN;

    ov7670_axis_write_reg(
        OV7670_AXIS_REG_CONTROL,
        control | OV7670_AXIS_CTRL_STAT_CLEAR
    );

    /*
     * Return CONTROL to the persistent capture state.
     *
     * Even if RTL already treats stat_clear as a pulse, doing
     * this explicitly leaves the software-visible state clean.
     */
    ov7670_axis_write_reg(
        OV7670_AXIS_REG_CONTROL,
        control
    );
}