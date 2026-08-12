#include "qr_camera.h"

#include "sleep.h"

#include "xil_printf.h"
#include "xstatus.h"

#include "qr_hw_config.h"


/* ============================================================================
 * Camera configuration
 * ========================================================================== */

#define QR_CAMERA_STARTUP_US        100000U
#define QR_CAMERA_OUTER_RETRIES     5U


/* ============================================================================
 * Camera complete initialization
 *
 * SCCB is still intermittent.
 * Therefore retry the entire camera initialization sequence.
 * ========================================================================== */

int qr_camera_prepare(
    ov7670_t *camera
)
{
    u32 attempt;

    u8 pid;
    u8 ver;

    int status;


    if (camera == NULL) {

        return XST_FAILURE;
    }


    pid = 0U;
    ver = 0U;


    for (attempt = 1U;
         attempt <= QR_CAMERA_OUTER_RETRIES;
         ++attempt) {

        xil_printf(
            "[CAMERA] setup attempt %u/%u\r\n",
            (unsigned int)attempt,
            (unsigned int)QR_CAMERA_OUTER_RETRIES
        );


        status =
            ov7670_init(
                camera,
                QR_HW_I2C0_BASEADDR,
                QR_HW_I2C_SCLK_HZ
            );


        if (status !=
            XST_SUCCESS) {

            xil_printf(
                "[WARN] Camera I2C init failed\r\n"
            );


            usleep(
                100000U
            );


            continue;
        }


        /*
         * Let SCCB controller / camera settle.
         */
        usleep(
            QR_CAMERA_STARTUP_US
        );


        status =
            ov7670_prepare_vga_rgb565(
                camera,
                (u8)QR_HW_OV7670_CLKRC_BRINGUP,
                &pid,
                &ver
            );


        if (status ==
            XST_SUCCESS) {

            xil_printf(
                "[PASS] Camera ready "
                "PID=0x%02x VER=0x%02x\r\n",
                pid,
                ver
            );


            return XST_SUCCESS;
        }


        xil_printf(
            "[WARN] Camera setup retry\r\n"
        );


        usleep(
            100000U
        );
    }


    xil_printf(
        "[FAIL] Camera setup failed\r\n"
    );


    return XST_FAILURE;
}


