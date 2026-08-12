#include "ov7670.h"

#include "sleep.h"

#include "xil_printf.h"
#include "xstatus.h"


/* ============================================================================
 * OV7670 SCCB
 * ========================================================================== */

#define OV7670_SCCB_ADDR                 0x21U

#define OV7670_REG_GAIN                  0x00U
#define OV7670_REG_BLUE                  0x01U
#define OV7670_REG_RED                   0x02U
#define OV7670_REG_VREF                  0x03U
#define OV7670_REG_COM1                  0x04U

#define OV7670_REG_PID                   0x0AU
#define OV7670_REG_VER                   0x0BU

#define OV7670_REG_COM3                  0x0CU
#define OV7670_REG_COM4                  0x0DU
#define OV7670_REG_COM5                  0x0EU
#define OV7670_REG_COM6                  0x0FU

#define OV7670_REG_AECH                  0x10U
#define OV7670_REG_CLKRC                 0x11U
#define OV7670_REG_COM7                  0x12U
#define OV7670_REG_COM8                  0x13U
#define OV7670_REG_COM9                  0x14U
#define OV7670_REG_COM10                 0x15U

#define OV7670_REG_HSTART                0x17U
#define OV7670_REG_HSTOP                 0x18U
#define OV7670_REG_VSTART                0x19U
#define OV7670_REG_VSTOP                 0x1AU
#define OV7670_REG_MVFP                  0x1EU

#define OV7670_REG_AEW                   0x24U
#define OV7670_REG_AEB                   0x25U
#define OV7670_REG_VPT                   0x26U

#define OV7670_REG_HREF                  0x32U

#define OV7670_REG_TSLB                  0x3AU
#define OV7670_REG_COM11                 0x3BU
#define OV7670_REG_COM12                 0x3CU
#define OV7670_REG_COM13                 0x3DU
#define OV7670_REG_COM14                 0x3EU

#define OV7670_REG_COM15                 0x40U
#define OV7670_REG_COM16                 0x41U
#define OV7670_REG_COM17                 0x42U

#define OV7670_REG_RGB444                0x8CU

#define OV7670_REG_SCALING_XSC           0x70U
#define OV7670_REG_SCALING_YSC           0x71U
#define OV7670_REG_SCALING_DCWCTR        0x72U
#define OV7670_REG_SCALING_PCLK_DIV      0x73U

#define OV7670_PID_VALUE                 0x76U
#define OV7670_VER_VALUE                 0x73U


/* ============================================================================
 * SCCB timing / retry
 * ========================================================================== */

#define OV7670_SCCB_RETRY_COUNT           3U

#define OV7670_SCCB_IDLE_TIMEOUT          100000U

#define OV7670_SCCB_REG_DELAY_US          1000U

#define OV7670_SCCB_RECOVERY_DELAY_US     2000U

#define OV7670_RESET_DELAY_US             10000U

#define OV7670_PREPARE_RETRY_DELAY_US     20000U


/* ============================================================================
 * Current requested SCCB clock
 *
 * Used again after XIicPs_Reset().
 * ========================================================================== */

static u32 g_ov7670_sccb_clock_hz = 50000U;


/* ============================================================================
 * Register table type
 * ========================================================================== */

typedef struct
{
    u8 reg;
    u8 value;

} ov7670_reg_pair_t;


/* ============================================================================
 * Wait until PS I2C bus becomes idle
 * ========================================================================== */

static int ov7670_wait_idle(
    ov7670_t *camera
)
{
    u32 timeout;


    if (camera == NULL) {
        return XST_FAILURE;
    }


    timeout = 0U;


    while (XIicPs_BusIsBusy(
               &camera->iic
           )) {

        ++timeout;


        if (timeout >=
            OV7670_SCCB_IDLE_TIMEOUT) {

            return XST_FAILURE;
        }
    }


    return XST_SUCCESS;
}


/* ============================================================================
 * SCCB recovery
 *
 * First try Abort.
 * If bus is still busy, reset PS I2C controller and restore SCLK.
 * ========================================================================== */

static void ov7670_sccb_recover(
    ov7670_t *camera,
    const char *reason
)
{
    if (camera == NULL) {
        return;
    }


    xil_printf(
        "[OV7670 SCCB] recover: %s\r\n",
        reason
    );


    XIicPs_Abort(
        &camera->iic
    );


    usleep(
        OV7670_SCCB_RECOVERY_DELAY_US
    );


    if (!XIicPs_BusIsBusy(
             &camera->iic
         )) {

        xil_printf(
            "[OV7670 SCCB] bus released after Abort\r\n"
        );

        return;
    }


    xil_printf(
        "[OV7670 SCCB] bus still busy -> XIicPs_Reset\r\n"
    );


    XIicPs_Reset(
        &camera->iic
    );


    usleep(
        OV7670_SCCB_RECOVERY_DELAY_US
    );


    /*
     * Restore SCCB clock after controller reset.
     */
    XIicPs_SetSClk(
        &camera->iic,
        g_ov7670_sccb_clock_hz
    );


    usleep(
        OV7670_SCCB_RECOVERY_DELAY_US
    );


    if (XIicPs_BusIsBusy(
            &camera->iic
        )) {

        xil_printf(
            "[OV7670 SCCB] bus remains busy after controller reset\r\n"
        );
    }
    else {

        xil_printf(
            "[OV7670 SCCB] bus released after controller reset\r\n"
        );
    }
}


/* ============================================================================
 * OV7670 / PS I2C initialize
 * ========================================================================== */

int ov7670_init(
    ov7670_t *camera,
    UINTPTR baseaddr,
    u32 sccb_clock_hz
)
{
    XIicPs_Config *config;

    int status;


    if (camera == NULL) {
        return XST_FAILURE;
    }


    g_ov7670_sccb_clock_hz =
        sccb_clock_hz;


    config =
        XIicPs_LookupConfig(
            baseaddr
        );


    if (config == NULL) {

        xil_printf(
            "[OV7670 INIT FAIL] XIicPs_LookupConfig\r\n"
        );

        return XST_FAILURE;
    }


    status =
        XIicPs_CfgInitialize(
            &camera->iic,
            config,
            config->BaseAddress
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[OV7670 INIT FAIL] XIicPs_CfgInitialize status=%d\r\n",
            status
        );

        return status;
    }


    status =
        XIicPs_SetSClk(
            &camera->iic,
            sccb_clock_hz
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[OV7670 INIT FAIL] XIicPs_SetSClk status=%d\r\n",
            status
        );

        return status;
    }


    xil_printf(
        "OV7670 SCCB clock : %u Hz\r\n",
        (unsigned int)
        XIicPs_GetSClk(
            &camera->iic
        )
    );


    return XST_SUCCESS;
}


/* ============================================================================
 * Write one OV7670 register
 * ========================================================================== */

int ov7670_write_reg(
    ov7670_t *camera,
    u8 reg,
    u8 value
)
{
    u8 buffer[2];

    u32 attempt;

    int status;


    if (camera == NULL) {
        return XST_FAILURE;
    }


    buffer[0] =
        reg;

    buffer[1] =
        value;


    for (attempt = 1U;
         attempt <= OV7670_SCCB_RETRY_COUNT;
         ++attempt) {

        /* --------------------------------------------------------------------
         * Bus must be idle before transaction.
         * ------------------------------------------------------------------ */

        if (ov7670_wait_idle(
                camera
            ) != XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] WRITE PRE_BUSY "
                "reg=0x%02x value=0x%02x attempt=%u\r\n",
                reg,
                value,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "WRITE_PRE_BUSY"
            );


            continue;
        }


        /* --------------------------------------------------------------------
         * Send register + value
         * ------------------------------------------------------------------ */

        status =
            XIicPs_MasterSendPolled(
                &camera->iic,
                buffer,
                2U,
                OV7670_SCCB_ADDR
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] WRITE SEND FAIL "
                "reg=0x%02x value=0x%02x status=%d attempt=%u\r\n",
                reg,
                value,
                status,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "WRITE_SEND"
            );


            continue;
        }


        /* --------------------------------------------------------------------
         * Wait transaction completion.
         * ------------------------------------------------------------------ */

        if (ov7670_wait_idle(
                camera
            ) != XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] WRITE POST_BUSY "
                "reg=0x%02x value=0x%02x attempt=%u\r\n",
                reg,
                value,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "WRITE_POST_BUSY"
            );


            continue;
        }


        /*
         * OV7670 SCCB register settling time.
         */
        usleep(
            OV7670_SCCB_REG_DELAY_US
        );


        return XST_SUCCESS;
    }


    xil_printf(
        "[OV7670 SCCB] WRITE FAILED "
        "reg=0x%02x value=0x%02x after %u attempts\r\n",
        reg,
        value,
        OV7670_SCCB_RETRY_COUNT
    );


    return XST_FAILURE;
}


/* ============================================================================
 * Read one OV7670 register
 * ========================================================================== */

int ov7670_read_reg(
    ov7670_t *camera,
    u8 reg,
    u8 *value
)
{
    u8 reg_buffer;

    u8 rx_buffer;

    u32 attempt;

    int status;


    if ((camera == NULL) ||
        (value == NULL)) {

        return XST_FAILURE;
    }


    reg_buffer =
        reg;


    for (attempt = 1U;
         attempt <= OV7670_SCCB_RETRY_COUNT;
         ++attempt) {

        /* --------------------------------------------------------------------
         * Pre-idle
         * ------------------------------------------------------------------ */

        if (ov7670_wait_idle(
                camera
            ) != XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] READ PRE_BUSY "
                "reg=0x%02x attempt=%u\r\n",
                reg,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "READ_PRE_BUSY"
            );


            continue;
        }


        /* --------------------------------------------------------------------
         * Send register address
         * ------------------------------------------------------------------ */

        status =
            XIicPs_MasterSendPolled(
                &camera->iic,
                &reg_buffer,
                1U,
                OV7670_SCCB_ADDR
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] READ ADDR SEND FAIL "
                "reg=0x%02x status=%d attempt=%u\r\n",
                reg,
                status,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "READ_ADDR_SEND"
            );


            continue;
        }


        if (ov7670_wait_idle(
                camera
            ) != XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] READ ADDR POST_BUSY "
                "reg=0x%02x attempt=%u\r\n",
                reg,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "READ_ADDR_POST_BUSY"
            );


            continue;
        }


        /* --------------------------------------------------------------------
         * Read data byte
         * ------------------------------------------------------------------ */

        rx_buffer =
            0U;


        status =
            XIicPs_MasterRecvPolled(
                &camera->iic,
                &rx_buffer,
                1U,
                OV7670_SCCB_ADDR
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] READ RECV FAIL "
                "reg=0x%02x status=%d attempt=%u\r\n",
                reg,
                status,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "READ_RECV"
            );


            continue;
        }


        if (ov7670_wait_idle(
                camera
            ) != XST_SUCCESS) {

            xil_printf(
                "[OV7670 SCCB] READ POST_BUSY "
                "reg=0x%02x attempt=%u\r\n",
                reg,
                (unsigned int)attempt
            );


            ov7670_sccb_recover(
                camera,
                "READ_POST_BUSY"
            );


            continue;
        }


        *value =
            rx_buffer;


        usleep(
            OV7670_SCCB_REG_DELAY_US
        );


        return XST_SUCCESS;
    }


    xil_printf(
        "[OV7670 SCCB] READ FAILED "
        "reg=0x%02x after %u attempts\r\n",
        reg,
        OV7670_SCCB_RETRY_COUNT
    );


    return XST_FAILURE;
}


/* ============================================================================
 * Software reset
 * ========================================================================== */

int ov7670_reset(
    ov7670_t *camera
)
{
    int status;


    status =
        ov7670_write_reg(
            camera,
            OV7670_REG_COM7,
            0x80U
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[OV7670 RESET FAIL] status=%d\r\n",
            status
        );

        return status;
    }


    /*
     * COM7 software reset requires delay before next SCCB access.
     */
    usleep(
        OV7670_RESET_DELAY_US
    );


    return XST_SUCCESS;
}


/* ============================================================================
 * Probe PID / VER
 * ========================================================================== */

int ov7670_probe(
    ov7670_t *camera,
    u8 *pid,
    u8 *ver
)
{
    int status;


    if ((camera == NULL) ||
        (pid == NULL) ||
        (ver == NULL)) {

        return XST_FAILURE;
    }


    *pid =
        0U;

    *ver =
        0U;


    status =
        ov7670_read_reg(
            camera,
            OV7670_REG_PID,
            pid
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    status =
        ov7670_read_reg(
            camera,
            OV7670_REG_VER,
            ver
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    xil_printf(
        "OV7670 ID      : PID=0x%02x VER=0x%02x\r\n",
        *pid,
        *ver
    );


    if ((*pid != OV7670_PID_VALUE) ||
        (*ver != OV7670_VER_VALUE)) {

        xil_printf(
            "[OV7670 PROBE FAIL] unexpected PID/VER\r\n"
        );

        return XST_FAILURE;
    }


    return XST_SUCCESS;
}


/* ============================================================================
 * Register table writer
 * ========================================================================== */

static int ov7670_write_table(
    ov7670_t *camera,
    const ov7670_reg_pair_t *table,
    u32 count,
    const char *name
)
{
    u32 i;

    int status;


    if ((camera == NULL) ||
        (table == NULL)) {

        return XST_FAILURE;
    }


    for (i = 0U;
         i < count;
         ++i) {

        status =
            ov7670_write_reg(
                camera,
                table[i].reg,
                table[i].value
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[OV7670 CFG FAIL] %s "
                "index=%u reg=0x%02x value=0x%02x status=%d\r\n",
                name,
                (unsigned int)i,
                table[i].reg,
                table[i].value,
                status
            );


            return status;
        }
    }


    xil_printf(
        "[PASS] OV7670 %s\r\n",
        name
    );


    return XST_SUCCESS;
}


/* ============================================================================
 * VGA geometry
 *
 * XSC/YSC bit7 = 0
 * => internal test pattern OFF.
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_vga_regs[] =
{
    { OV7670_REG_TSLB,             0x04U },

    /*
     * VGA base mode.
     * RGB mode is selected at the final format stage.
     */
    { OV7670_REG_COM7,             0x00U },

    { OV7670_REG_HSTART,           0x13U },
    { OV7670_REG_HSTOP,            0x01U },
    { OV7670_REG_HREF,             0xB6U },

    { OV7670_REG_VSTART,           0x02U },
    { OV7670_REG_VSTOP,            0x7AU },
    { OV7670_REG_VREF,             0x0AU },

    { OV7670_REG_COM3,             0x00U },
    { OV7670_REG_COM14,            0x00U },

    /*
     * Normal VGA scaling.
     *
     * bit7:
     *     XSC = 0
     *     YSC = 0
     *
     * => test pattern disabled.
     */
    { OV7670_REG_SCALING_XSC,      0x3AU },
    { OV7670_REG_SCALING_YSC,      0x35U },

    { OV7670_REG_SCALING_DCWCTR,   0x11U },
    { OV7670_REG_SCALING_PCLK_DIV, 0xF0U },

    { 0xA2U,                       0x02U },

    /*
     * Normal polarity.
     */
    { OV7670_REG_COM10,            0x00U },

    /*
     * DSP color bar OFF.
     */
    { OV7670_REG_COM17,            0x00U }
};


/* ============================================================================
 * Gamma curve
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_gamma_regs[] =
{
    { 0x7AU, 0x20U },
    { 0x7BU, 0x10U },
    { 0x7CU, 0x1EU },
    { 0x7DU, 0x35U },

    { 0x7EU, 0x5AU },
    { 0x7FU, 0x69U },
    { 0x80U, 0x76U },
    { 0x81U, 0x80U },

    { 0x82U, 0x88U },
    { 0x83U, 0x8FU },
    { 0x84U, 0x96U },
    { 0x85U, 0xA3U },

    { 0x86U, 0xAFU },
    { 0x87U, 0xC4U },
    { 0x88U, 0xD7U },
    { 0x89U, 0xE8U }
};


/* ============================================================================
 * AEC / AGC configuration
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_aec_agc_regs[] =
{
    /*
     * Automatic controls temporarily disabled
     * while operating parameters are configured.
     */
    { OV7670_REG_COM8, 0xE0U },

    { OV7670_REG_GAIN, 0x00U },
    { OV7670_REG_AECH, 0x00U },

    { OV7670_REG_COM4, 0x40U },

    /*
     * Gain ceiling.
     */
    { OV7670_REG_COM9, 0x38U },

    { 0xA5U, 0x05U },
    { 0xABU, 0x07U },

    { OV7670_REG_AEW, 0x95U },
    { OV7670_REG_AEB, 0x33U },
    { OV7670_REG_VPT, 0xE3U },

    { 0x9FU, 0x78U },
    { 0xA0U, 0x68U },
    { 0xA1U, 0x03U },

    { 0xA6U, 0xD8U },
    { 0xA7U, 0xD8U },
    { 0xA8U, 0xF0U },
    { 0xA9U, 0x90U },
    { 0xAAU, 0x94U }
};


/* ============================================================================
 * Sensor / DSP baseline
 *
 * PLL register 0x6B is deliberately not changed.
 *
 * The test-pattern test already proved that the current XCLK/PCLK
 * relationship works with the PL capture path.
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_sensor_regs[] =
{
    { OV7670_REG_COM5,  0x61U },
    { OV7670_REG_COM6,  0x4BU },

    { 0x16U,            0x02U },

    { OV7670_REG_MVFP,  0x07U },

    { 0x21U,            0x02U },
    { 0x22U,            0x91U },

    { 0x29U,            0x07U },

    { 0x33U,            0x0BU },
    { 0x35U,            0x0BU },

    { 0x37U,            0x1DU },
    { 0x38U,            0x71U },
    { 0x39U,            0x2AU },

    { OV7670_REG_COM12, 0x78U },

    { 0x4DU,            0x40U },
    { 0x4EU,            0x20U },

    { 0x69U,            0x00U },

    { 0x74U,            0x10U },

    { 0x8DU,            0x4FU },

    { 0x8EU,            0x00U },
    { 0x8FU,            0x00U },
    { 0x90U,            0x00U },
    { 0x91U,            0x00U },

    { 0x96U,            0x00U },

    { 0x9AU,            0x00U },

    { 0xB0U,            0x84U },
    { 0xB1U,            0x0CU },
    { 0xB2U,            0x0EU },
    { 0xB3U,            0x82U },

    { 0xB8U,            0x0AU }
};


/* ============================================================================
 * AWB baseline
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_awb_regs[] =
{
    { 0x43U, 0x0AU },
    { 0x44U, 0xF0U },

    { 0x45U, 0x34U },
    { 0x46U, 0x58U },

    { 0x47U, 0x28U },
    { 0x48U, 0x3AU },

    { 0x59U, 0x88U },
    { 0x5AU, 0x88U },

    { 0x5BU, 0x44U },
    { 0x5CU, 0x67U },

    { 0x5DU, 0x49U },
    { 0x5EU, 0x0EU },

    { 0x6CU, 0x0AU },
    { 0x6DU, 0x55U },

    { 0x6EU, 0x11U },
    { 0x6FU, 0x9FU },

    { 0x6AU, 0x40U },

    { OV7670_REG_BLUE, 0x40U },
    { OV7670_REG_RED,  0x60U }
};


/* ============================================================================
 * DSP baseline
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_dsp_regs[] =
{
    { OV7670_REG_COM16, 0x38U },

    { 0x3FU,            0x00U },

    { 0x75U,            0x05U },
    { 0x76U,            0xE1U },

    { 0x4CU,            0x00U },

    { 0x77U,            0x01U },

    { 0x4BU,            0x09U },

    { 0xC9U,            0x60U },

    /*
     * Contrast.
     */
    { 0x56U,            0x40U },

    { 0x34U,            0x11U },

    /*
     * Automatic 50/60 Hz behavior.
     */
    { OV7670_REG_COM11, 0x12U }
};


/* ============================================================================
 * RGB565 output configuration
 * ========================================================================== */

static const ov7670_reg_pair_t ov7670_rgb565_regs[] =
{
    /*
     * COM7:
     *
     * VGA + RGB output.
     */
    { OV7670_REG_COM7,   0x04U },

    /*
     * RGB444 OFF.
     */
    { OV7670_REG_RGB444, 0x00U },

    { OV7670_REG_COM1,   0x00U },

    /*
     * COM15:
     *
     * full range + RGB565
     */
    { OV7670_REG_COM15,  0xD0U },

    /*
     * Gain ceiling.
     */
    { OV7670_REG_COM9,   0x38U },

    /*
     * RGB color matrix.
     */
    { 0x4FU,             0xB3U },
    { 0x50U,             0xB3U },

    { 0x51U,             0x00U },

    { 0x52U,             0x3DU },
    { 0x53U,             0xA7U },
    { 0x54U,             0xE4U },

    { 0x58U,             0x9EU },

    /*
     * Gamma / UV saturation.
     */
    { OV7670_REG_COM13,  0xC0U },

    /*
     * AWB gain.
     */
    { OV7670_REG_COM16,  0x08U },

    /*
     * Automatic gain / AWB / exposure enabled LAST.
     */
    { OV7670_REG_COM8,   0xE7U },

    /*
     * Force test-pattern generator OFF.
     */
    { OV7670_REG_SCALING_XSC, 0x3AU },
    { OV7670_REG_SCALING_YSC, 0x35U },

    /*
     * DSP color bar OFF.
     */
    { OV7670_REG_COM17,  0x00U }
};


/* ============================================================================
 * Full VGA RGB565 configuration
 * ========================================================================== */

int ov7670_configure_vga_rgb565_baseline(
    ov7670_t *camera,
    u8 clkrc
)
{
    int status;


    if (camera == NULL) {
        return XST_FAILURE;
    }


    xil_printf(
        "OV7670 VGA/RGB565 full sensor configuration\r\n"
    );


    /* ========================================================================
     * Clock divider first
     * ====================================================================== */

    status =
        ov7670_write_reg(
            camera,
            OV7670_REG_CLKRC,
            clkrc
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[OV7670 CFG FAIL] initial CLKRC\r\n"
        );

        return status;
    }


    /* ========================================================================
     * VGA
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_vga_regs,
            sizeof(ov7670_vga_regs) /
            sizeof(ov7670_vga_regs[0]),
            "VGA geometry"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * Gamma
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_gamma_regs,
            sizeof(ov7670_gamma_regs) /
            sizeof(ov7670_gamma_regs[0]),
            "gamma"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * AEC / AGC
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_aec_agc_regs,
            sizeof(ov7670_aec_agc_regs) /
            sizeof(ov7670_aec_agc_regs[0]),
            "AEC/AGC"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * Sensor baseline
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_sensor_regs,
            sizeof(ov7670_sensor_regs) /
            sizeof(ov7670_sensor_regs[0]),
            "sensor baseline"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * AWB
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_awb_regs,
            sizeof(ov7670_awb_regs) /
            sizeof(ov7670_awb_regs[0]),
            "AWB"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * DSP
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_dsp_regs,
            sizeof(ov7670_dsp_regs) /
            sizeof(ov7670_dsp_regs[0]),
            "DSP"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /* ========================================================================
     * RGB565
     * ====================================================================== */

    status =
        ov7670_write_table(
            camera,
            ov7670_rgb565_regs,
            sizeof(ov7670_rgb565_regs) /
            sizeof(ov7670_rgb565_regs[0]),
            "RGB565"
        );


    if (status !=
        XST_SUCCESS) {

        return status;
    }


    /*
     * Rewrite clock divider last.
     */
    status =
        ov7670_write_reg(
            camera,
            OV7670_REG_CLKRC,
            clkrc
        );


    if (status !=
        XST_SUCCESS) {

        xil_printf(
            "[OV7670 CFG FAIL] final CLKRC\r\n"
        );

        return status;
    }


    usleep(
        10000U
    );


    /* ========================================================================
     * Essential readback
     * ====================================================================== */

    {
        u8 com7;
        u8 com15;
        u8 xsc;
        u8 ysc;


        com7 =
            0U;

        com15 =
            0U;

        xsc =
            0U;

        ysc =
            0U;


        status =
            ov7670_read_reg(
                camera,
                OV7670_REG_COM7,
                &com7
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        status =
            ov7670_read_reg(
                camera,
                OV7670_REG_COM15,
                &com15
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        status =
            ov7670_read_reg(
                camera,
                OV7670_REG_SCALING_XSC,
                &xsc
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        status =
            ov7670_read_reg(
                camera,
                OV7670_REG_SCALING_YSC,
                &ysc
            );


        if (status !=
            XST_SUCCESS) {

            return status;
        }


        xil_printf(
            "OV7670 readback: "
            "COM7=0x%02x COM15=0x%02x "
            "XSC=0x%02x YSC=0x%02x\r\n",
            com7,
            com15,
            xsc,
            ysc
        );


        /*
         * COM7[2:0] = RGB
         * COM15[5:4] = RGB565
         */
        if (((com7 & 0x07U) != 0x04U) ||
            ((com15 & 0x30U) != 0x10U)) {

            xil_printf(
                "[OV7670 CFG FAIL] RGB565 readback mismatch\r\n"
            );

            return XST_FAILURE;
        }


        /*
         * XSC[7] and YSC[7] must both be 0.
         *
         * This guarantees internal test pattern is OFF.
         */
        if (((xsc & 0x80U) != 0U) ||
            ((ysc & 0x80U) != 0U)) {

            xil_printf(
                "[OV7670 CFG FAIL] test pattern still enabled\r\n"
            );

            return XST_FAILURE;
        }
    }


    xil_printf(
        "[PASS] OV7670 VGA/RGB565 full configuration\r\n"
    );


    return XST_SUCCESS;
}


/* ============================================================================
 * Full reset + communication + VGA/RGB565 preparation
 * ========================================================================== */

int ov7670_prepare_vga_rgb565(
    ov7670_t *camera,
    u8 clkrc,
    u8 *pid,
    u8 *ver
)
{
    u32 attempt;

    int status;


    if ((camera == NULL) ||
        (pid == NULL) ||
        (ver == NULL)) {

        return XST_FAILURE;
    }


    for (attempt = 1U;
         attempt <= 3U;
         ++attempt) {

        xil_printf(
            "OV7670 init attempt %u\r\n",
            (unsigned int)attempt
        );


        /* --------------------------------------------------------------------
         * Software reset
         * ------------------------------------------------------------------ */

        status =
            ov7670_reset(
                camera
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[WARN] OV7670 software reset failed\r\n"
            );


            usleep(
                OV7670_PREPARE_RETRY_DELAY_US
            );


            continue;
        }


        /* --------------------------------------------------------------------
         * Probe
         * ------------------------------------------------------------------ */

        status =
            ov7670_probe(
                camera,
                pid,
                ver
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[WARN] OV7670 probe failed\r\n"
            );


            usleep(
                OV7670_PREPARE_RETRY_DELAY_US
            );


            continue;
        }


        xil_printf(
            "[PASS] OV7670 communication ready\r\n"
        );


        /* --------------------------------------------------------------------
         * Full sensor configuration
         * ------------------------------------------------------------------ */

        status =
            ov7670_configure_vga_rgb565_baseline(
                camera,
                clkrc
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[WARN] OV7670 VGA/RGB565 configuration failed "
                "on attempt %u\r\n",
                (unsigned int)attempt
            );


            /*
             * Recover controller before full retry.
             */
            ov7670_sccb_recover(
                camera,
                "FULL_CONFIG_RETRY"
            );


            usleep(
                OV7670_PREPARE_RETRY_DELAY_US
            );


            continue;
        }


        xil_printf(
            "[PASS] OV7670 VGA/RGB565\r\n"
        );


        return XST_SUCCESS;
    }


    xil_printf(
        "[FAIL] OV7670 communication/setup after 3 attempts\r\n"
    );


    return XST_FAILURE;
}