#ifndef OV7670_H
#define OV7670_H

#include "xiicps.h"
#include "xil_types.h"
#include "xstatus.h"


/* ============================================================================
 * OV7670 SCCB address
 *
 * OV7670 8-bit SCCB address:
 *   WRITE = 0x42
 *   READ  = 0x43
 *
 * XIicPs uses the 7-bit address.
 * ========================================================================== */

#define OV7670_SCCB_ADDR_7BIT        0x21U


/* ============================================================================
 * Device identification
 * ========================================================================== */

#define OV7670_PID_EXPECTED          0x76U
#define OV7670_VER_EXPECTED          0x73U


/* ============================================================================
 * OV7670 register map
 * ========================================================================== */

#define OV7670_REG_GAIN              0x00U
#define OV7670_REG_BLUE              0x01U
#define OV7670_REG_RED               0x02U
#define OV7670_REG_VREF              0x03U
#define OV7670_REG_COM1              0x04U

#define OV7670_REG_PID               0x0AU
#define OV7670_REG_VER               0x0BU
#define OV7670_REG_COM3              0x0CU

#define OV7670_REG_CLKRC             0x11U
#define OV7670_REG_COM7              0x12U
#define OV7670_REG_COM8              0x13U
#define OV7670_REG_COM9              0x14U
#define OV7670_REG_COM10             0x15U

#define OV7670_REG_HSTART            0x17U
#define OV7670_REG_HSTOP             0x18U
#define OV7670_REG_VSTART            0x19U
#define OV7670_REG_VSTOP             0x1AU

#define OV7670_REG_HREF              0x32U

#define OV7670_REG_TSLB              0x3AU
#define OV7670_REG_COM13             0x3DU
#define OV7670_REG_COM14             0x3EU
#define OV7670_REG_COM15             0x40U
#define OV7670_REG_COM16             0x41U

#define OV7670_REG_RGB444            0x8CU


/* ============================================================================
 * COM7 values
 * ========================================================================== */

#define OV7670_COM7_RESET            0x80U

/*
 * VGA + RGB mode.
 */
#define OV7670_COM7_VGA_RGB          0x04U


/* ============================================================================
 * OV7670 handle
 * ========================================================================== */

typedef struct {

    XIicPs iic;

    UINTPTR iic_baseaddr;

    u32 sccb_clock_hz;

} ov7670_t;


/* ============================================================================
 * Low-level SCCB / PS-I2C access
 * ========================================================================== */

int ov7670_init(
    ov7670_t *camera,
    UINTPTR iic_baseaddr,
    u32 sccb_clock_hz
);


int ov7670_write_reg(
    ov7670_t *camera,
    u8 reg,
    u8 value
);


int ov7670_read_reg(
    ov7670_t *camera,
    u8 reg,
    u8 *value
);


/* ============================================================================
 * OV7670 control
 * ========================================================================== */

int ov7670_soft_reset(
    ov7670_t *camera
);


int ov7670_probe(
    ov7670_t *camera,
    u8 *pid,
    u8 *ver
);


/* ============================================================================
 * OV7670 configuration
 * ========================================================================== */

int ov7670_configure_vga_rgb565_baseline(
    ov7670_t *camera,
    u8 clkrc_value
);


/*
 * Complete camera preparation:
 *
 *   COM7 RESET
 *       ↓
 *   wait 10 ms
 *       ↓
 *   PID / VER check
 *       ↓
 *   VGA / RGB565 configuration
 *
 * Reset/probe sequence can retry.
 * Individual SCCB transactions can also retry.
 */
int ov7670_prepare_vga_rgb565(
    ov7670_t *camera,
    u8 clkrc_value,
    u8 *pid,
    u8 *ver
);


#endif