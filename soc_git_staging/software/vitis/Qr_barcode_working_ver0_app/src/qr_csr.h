#ifndef QR_CSR_H
#define QR_CSR_H

#include "xil_types.h"

typedef struct {
    UINTPTR base_addr;
    u32 persistent_control;
} qr_csr_t;

/* Register offsets */
#define QR_CSR_CONTROL                  0x00U
#define QR_CSR_STATUS                   0x04U
#define QR_CSR_FRAME_ID_SEED            0x08U
#define QR_CSR_RESULT_WORDS             0x0CU
#define QR_CSR_CANDIDATE_COUNT          0x10U
#define QR_CSR_ERROR_FLAGS              0x14U
#define QR_CSR_IMAGE_BYTES              0x18U
#define QR_CSR_IMAGE_FORMAT             0x1CU
#define QR_CSR_FE_CONFIG                0x20U
#define QR_CSR_IMAGE_SIZE               0x24U
#define QR_CSR_IMAGE_STRIDE             0x28U
#define QR_CSR_IRQ_STATUS               0x2CU
#define QR_CSR_IRQ_ENABLE               0x30U
#define QR_CSR_ACTIVE_FRAME_ID          0x34U
#define QR_CSR_DROP_COUNT               0x38U
#define QR_CSR_IMAGE_FRAME_ID           0x3CU

/* Compatibility aliases */
#define QR_CSR_FRAME_ID                 QR_CSR_FRAME_ID_SEED
#define QR_CSR_CAND_COUNT               QR_CSR_CANDIDATE_COUNT
#define QR_CSR_ACTIVE_ID                QR_CSR_ACTIVE_FRAME_ID
#define QR_CSR_IMAGE_ID                 QR_CSR_IMAGE_FRAME_ID

/* CONTROL */
#define QR_CTRL_ENABLE                  (1U << 0)
#define QR_CTRL_MANUAL_START            (1U << 1)
#define QR_CTRL_SOFT_RESET              (1U << 2)
#define QR_CTRL_ERROR_CLEAR             (1U << 3)
#define QR_CTRL_STREAM_START            (1U << 4)
#define QR_CTRL_IMAGE_CAPTURE_ENABLE    (1U << 5)
#define QR_CTRL_FRAME_ACK               (1U << 6)
#define QR_CTRL_AUTO_START_ENABLE       (1U << 7)

#define QR_CTRL_PERSISTENT_MASK \
    (QR_CTRL_ENABLE | \
     QR_CTRL_IMAGE_CAPTURE_ENABLE | \
     QR_CTRL_AUTO_START_ENABLE)

#define QR_CTRL_PULSE_MASK \
    (QR_CTRL_MANUAL_START | \
     QR_CTRL_SOFT_RESET | \
     QR_CTRL_ERROR_CLEAR | \
     QR_CTRL_STREAM_START | \
     QR_CTRL_FRAME_ACK)

#define QR_CTRL_PERSISTENT_DEFAULT \
    (QR_CTRL_ENABLE | \
     QR_CTRL_IMAGE_CAPTURE_ENABLE | \
     QR_CTRL_AUTO_START_ENABLE)

#define QR_CTRL_PERSISTENT_DEFAULT_VALUE  0x000000A1U

/* STATUS */
#define QR_STATUS_PROCESSING_BUSY           (1U << 0)
#define QR_STATUS_RESULT_READY              (1U << 1)
#define QR_STATUS_IRQ                       (1U << 2)
#define QR_STATUS_COMBINED_ERROR            (1U << 3)
#define QR_STATUS_FEATURE_START_READY       (1U << 4)
#define QR_STATUS_STREAM_BUSY               (1U << 5)
#define QR_STATUS_FRONTEND_FRAME_READY      (1U << 6)
#define QR_STATUS_PACKET_TX_DONE            (1U << 7)
#define QR_STATUS_IMAGE_TX_DONE             (1U << 8)
#define QR_STATUS_FRAME_STUCK               (1U << 9)
#define QR_STATUS_IMAGE_OVERFLOW_ERROR      (1U << 10)
#define QR_STATUS_FRAME_ID_PROTOCOL_ERROR   (1U << 11)
#define QR_STATUS_FRAME_COMPLETE_PENDING    (1U << 12)

/* IRQ_STATUS / IRQ_ENABLE */
#define QR_IRQ_RESULT_READY                 (1U << 0)
#define QR_IRQ_PACKET_TX_DONE               (1U << 1)
#define QR_IRQ_IMAGE_TX_DONE                (1U << 2)
#define QR_IRQ_COMBINED_ERROR               (1U << 3)
#define QR_IRQ_FRAME_STUCK                  (1U << 4)
#define QR_IRQ_IMAGE_OVERFLOW_ERROR         (1U << 5)
#define QR_IRQ_FRAME_ID_PROTOCOL_ERROR      (1U << 6)
#define QR_IRQ_FRAME_COMPLETE_PENDING       (1U << 7)

#define QR_IRQ_NORMAL_MASK \
    (QR_IRQ_RESULT_READY | \
     QR_IRQ_PACKET_TX_DONE | \
     QR_IRQ_IMAGE_TX_DONE)

#define QR_IRQ_ERROR_MASK \
    (QR_IRQ_COMBINED_ERROR | \
     QR_IRQ_FRAME_STUCK | \
     QR_IRQ_IMAGE_OVERFLOW_ERROR | \
     QR_IRQ_FRAME_ID_PROTOCOL_ERROR)

#define QR_IRQ_ALL                          0x000000FFU

/* Fixed image contract */
#define QR_IMAGE_WIDTH_EXPECTED             640U
#define QR_IMAGE_HEIGHT_EXPECTED            480U
#define QR_IMAGE_BYTES_EXPECTED             307200U
#define QR_IMAGE_FORMAT_GRAY8               1U
#define QR_IMAGE_STRIDE_EXPECTED            640U
#define QR_IMAGE_SIZE_EXPECTED              0x01E00280U

/* Driver API */
void qr_csr_init(qr_csr_t *csr, UINTPTR base_addr);

u32  qr_csr_read(const qr_csr_t *csr, u32 offset);
void qr_csr_write(const qr_csr_t *csr, u32 offset, u32 value);

void qr_csr_set_persistent(
    qr_csr_t *csr,
    u32 persistent_control
);

void qr_csr_pulse(
    const qr_csr_t *csr,
    u32 pulse_mask
);

void qr_csr_clear_irq(
    const qr_csr_t *csr,
    u32 mask
);

void qr_csr_set_irq_enable(
    const qr_csr_t *csr,
    u32 mask
);

void qr_csr_set_frame_seed(
    const qr_csr_t *csr,
    u32 frame_id_seed
);

int qr_csr_probe_contract(
    const qr_csr_t *csr
);

#endif /* QR_CSR_H */