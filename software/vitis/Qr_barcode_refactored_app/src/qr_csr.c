#include "qr_csr.h"

#include "xil_io.h"
#include "xstatus.h"


/* ============================================================================
 * Internal MMIO helpers
 * ========================================================================== */

static UINTPTR qr_csr_addr(const qr_csr_t *csr, u32 offset)
{
    return csr->base_addr + (UINTPTR)offset;
}


/* ============================================================================
 * Initialization
 * ========================================================================== */

void qr_csr_init(qr_csr_t *csr, UINTPTR base_addr)
{
    u32 control;

    csr->base_addr = base_addr;

    /*
     * Read the current PL CONTROL register so the software shadow starts from
     * the actual persistent hardware state.
     *
     * This matters during bring-up because resetting only the ARM processor
     * does not necessarily reset PL AXI-Lite registers.
     */
    control = Xil_In32(base_addr + (UINTPTR)QR_CSR_CONTROL);

    csr->persistent_control =
        control & QR_CTRL_PERSISTENT_MASK;
}


/* ============================================================================
 * Raw register access
 * ========================================================================== */

u32 qr_csr_read(const qr_csr_t *csr, u32 offset)
{
    return Xil_In32(qr_csr_addr(csr, offset));
}


void qr_csr_write(const qr_csr_t *csr, u32 offset, u32 value)
{
    Xil_Out32(
        qr_csr_addr(csr, offset),
        value
    );
}


/* ============================================================================
 * CONTROL persistent bits
 *
 * Persistent CONTROL fields:
 *
 *   bit0 ENABLE
 *   bit5 IMAGE_CAPTURE_ENABLE
 *   bit7 AUTO_START_ENABLE
 *
 * Any pulse bits accidentally present in persistent_control are masked out.
 * ========================================================================== */

void qr_csr_set_persistent(
    qr_csr_t *csr,
    u32 persistent_control
)
{
    u32 value;

    value =
        persistent_control & QR_CTRL_PERSISTENT_MASK;

    csr->persistent_control = value;

    qr_csr_write(
        csr,
        QR_CSR_CONTROL,
        value
    );
}


/* ============================================================================
 * CONTROL pulse
 *
 * IMPORTANT:
 *
 * CONTROL writes update the persistent fields too. Therefore a pulse must
 * always be issued together with the software shadow of the persistent bits.
 *
 * Example:
 *
 *   persistent = 0xA1
 *   ERROR_CLEAR = bit3
 *
 *   write CONTROL = 0xA9
 *
 * Hardware treats bit3 as a one-cycle pulse while bits7/5/0 remain enabled.
 * ========================================================================== */

void qr_csr_pulse(
    const qr_csr_t *csr,
    u32 pulse_mask
)
{
    u32 value;

    value =
        csr->persistent_control |
        (pulse_mask & QR_CTRL_PULSE_MASK);

    qr_csr_write(
        csr,
        QR_CSR_CONTROL,
        value
    );
}


/* ============================================================================
 * IRQ_STATUS
 *
 * IRQ_STATUS uses W1C semantics.
 * ========================================================================== */

void qr_csr_clear_irq(
    const qr_csr_t *csr,
    u32 mask
)
{
    qr_csr_write(
        csr,
        QR_CSR_IRQ_STATUS,
        mask & QR_IRQ_ALL
    );
}


/* ============================================================================
 * IRQ_ENABLE
 * ========================================================================== */

void qr_csr_set_irq_enable(
    const qr_csr_t *csr,
    u32 mask
)
{
    qr_csr_write(
        csr,
        QR_CSR_IRQ_ENABLE,
        mask & QR_IRQ_ALL
    );
}


/* ============================================================================
 * FRAME_ID_SEED
 * ========================================================================== */

void qr_csr_set_frame_seed(
    const qr_csr_t *csr,
    u32 frame_id_seed
)
{
    qr_csr_write(
        csr,
        QR_CSR_FRAME_ID_SEED,
        frame_id_seed
    );
}


/* ============================================================================
 * Runtime image contract probe
 *
 * Expected fixed image-side contract:
 *
 *   IMAGE_BYTES  = 307200
 *   IMAGE_FORMAT = 1       (Gray8)
 *   IMAGE_SIZE   = 0x01E00280
 *                  [31:16] height = 480
 *                  [15:0]  width  = 640
 *   IMAGE_STRIDE = 640
 *
 * No CONTROL state is modified by this function.
 * ========================================================================== */

int qr_csr_probe_contract(const qr_csr_t *csr)
{
    u32 image_bytes;
    u32 image_format;
    u32 image_size;
    u32 image_stride;

    image_bytes =
        qr_csr_read(
            csr,
            QR_CSR_IMAGE_BYTES
        );

    image_format =
        qr_csr_read(
            csr,
            QR_CSR_IMAGE_FORMAT
        );

    image_size =
        qr_csr_read(
            csr,
            QR_CSR_IMAGE_SIZE
        );

    image_stride =
        qr_csr_read(
            csr,
            QR_CSR_IMAGE_STRIDE
        );


    if (image_bytes != QR_IMAGE_BYTES_EXPECTED) {

        return XST_FAILURE;
    }


    if (image_format != QR_IMAGE_FORMAT_GRAY8) {

        return XST_FAILURE;
    }


    if (image_size != QR_IMAGE_SIZE_EXPECTED) {

        return XST_FAILURE;
    }


    if (image_stride != QR_IMAGE_STRIDE_EXPECTED) {

        return XST_FAILURE;
    }


    return XST_SUCCESS;
}