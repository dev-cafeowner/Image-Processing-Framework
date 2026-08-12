#include "qr_decode.h"

#include <stdint.h>
#include <string.h>

#include "quirc.h"

#include "xil_printf.h"


/* ============================================================================
 * Configuration
 * ========================================================================== */

/*
 * 0 : final / fast runtime
 * 1 : detailed quirc debug
 */
#define QR_DECODE_VERBOSE               0


/*
 * Fast-path binary threshold.
 *
 * This value is expressed in normalized 0~255 space.
 */
#define QR_FAST_THRESHOLD_NORM          160U


/*
 * After this many consecutive unsuccessful frames,
 * run additional threshold scans.
 */
#define QR_ROBUST_AFTER_MISSES          3U


/*
 * Additional thresholds used by the robust fallback.
 */
#define QR_ROBUST_THRESHOLD_1           96U
#define QR_ROBUST_THRESHOLD_2           128U
#define QR_ROBUST_THRESHOLD_3           192U


/* ============================================================================
 * Scan modes
 * ========================================================================== */

#define QR_SCAN_ORIGINAL                0
#define QR_SCAN_BINARY                  1


/* ============================================================================
 * quirc objects
 *
 * Keep large objects outside the bare-metal stack.
 * ========================================================================== */

static struct quirc *g_quirc = NULL;

static int g_quirc_initialized = 0;


static struct quirc_code g_quirc_code;

static struct quirc_data g_quirc_data;


/*
 * Consecutive frame miss counter.
 *
 * Reset immediately after a successful payload decode.
 */
static u32 g_qr_consecutive_miss = 0U;


/* ============================================================================
 * Gray8 min / max
 * ========================================================================== */

static void qr_find_min_max(
    const u8 *gray,
    u8 *min_value,
    u8 *max_value
)
{
    u32 i;

    u8 min_v;
    u8 max_v;


    min_v = 255U;
    max_v = 0U;


    for (i = 0U;
         i < (u32)(QR_DECODE_WIDTH * QR_DECODE_HEIGHT);
         ++i) {

        u8 value;


        value = gray[i];


        if (value < min_v) {
            min_v = value;
        }


        if (value > max_v) {
            max_v = value;
        }
    }


    *min_value = min_v;
    *max_value = max_v;
}


/* ============================================================================
 * Convert normalized threshold to raw Gray8 threshold
 *
 * normalized =
 *
 *     (pixel - min) * 255
 *     -------------------
 *         max - min
 *
 * Instead of normalizing every pixel with division,
 * calculate one raw threshold and then only compare pixels.
 * ========================================================================== */

static u8 qr_make_raw_threshold(
    u8 min_value,
    u8 max_value,
    u8 normalized_threshold
)
{
    u32 range;

    u32 raw_threshold;


    if (max_value <= min_value) {

        return normalized_threshold;
    }


    range =
        (u32)max_value -
        (u32)min_value;


    raw_threshold =
        (u32)min_value +
        (
            (
                range *
                (u32)normalized_threshold
            ) +
            127U
        ) /
        255U;


    if (raw_threshold > 255U) {

        raw_threshold = 255U;
    }


    return (u8)raw_threshold;
}


/* ============================================================================
 * Fill quirc input image
 * ========================================================================== */

static void qr_fill_quirc_image(
    uint8_t *dst,
    const u8 *src,
    int mode,
    u8 raw_threshold
)
{
    u32 i;


    /* ========================================================================
     * Original Gray8
     * ====================================================================== */

    if (mode == QR_SCAN_ORIGINAL) {

        memcpy(
            dst,
            src,
            (size_t)(
                QR_DECODE_WIDTH *
                QR_DECODE_HEIGHT
            )
        );


        return;
    }


    /* ========================================================================
     * Binary threshold
     * ====================================================================== */

    for (i = 0U;
         i < (u32)(QR_DECODE_WIDTH * QR_DECODE_HEIGHT);
         ++i) {

        if (src[i] < raw_threshold) {

            dst[i] = 0U;
        }
        else {

            dst[i] = 255U;
        }
    }
}


/* ============================================================================
 * Store successful payload
 * ========================================================================== */

static int qr_store_result(
    const struct quirc_code *code,
    const struct quirc_data *data,
    char *result,
    u32 result_size,
    qr_decode_box_t *box
)
{
    u32 copy_length;

    int i;


    if ((code == NULL) ||
        (data == NULL) ||
        (result == NULL) ||
        (result_size == 0U)) {

        return QR_DECODE_FAIL;
    }


    copy_length =
        (u32)data->payload_len;


    if (copy_length >= result_size) {

        copy_length =
            result_size - 1U;
    }


    memcpy(
        result,
        data->payload,
        copy_length
    );


    result[copy_length] =
        '\0';


    if (box != NULL) {

        for (i = 0;
             i < 4;
             ++i) {

            box->corner[i].x =
                code->corners[i].x;


            box->corner[i].y =
                code->corners[i].y;
        }
    }


    xil_printf(
        "[QR PASS] %s\r\n",
        result
    );


#if QR_DECODE_VERBOSE

    xil_printf(
        "Version        : %d\r\n",
        data->version
    );


    xil_printf(
        "ECC level      : %d\r\n",
        data->ecc_level
    );


    xil_printf(
        "Mask           : %d\r\n",
        data->mask
    );


    xil_printf(
        "Payload length : %d\r\n",
        data->payload_len
    );


    if (box != NULL) {

        xil_printf(
            "Corners        : "
            "(%d,%d) "
            "(%d,%d) "
            "(%d,%d) "
            "(%d,%d)\r\n",

            box->corner[0].x,
            box->corner[0].y,

            box->corner[1].x,
            box->corner[1].y,

            box->corner[2].x,
            box->corner[2].y,

            box->corner[3].x,
            box->corner[3].y
        );
    }

#endif


    return QR_DECODE_OK;
}


/* ============================================================================
 * Decode regions detected by quirc
 *
 * Return:
 *
 * QR_DECODE_OK
 *     Payload successfully decoded.
 *
 * QR_DECODE_NOT_FOUND
 *     No QR region identified.
 *
 * QR_DECODE_FAIL
 *     QR region identified but payload decode failed.
 * ========================================================================== */

static int qr_decode_detected(
    char *result,
    u32 result_size,
    qr_decode_box_t *box
)
{
    int count;

    int index;


    count =
        quirc_count(
            g_quirc
        );


#if QR_DECODE_VERBOSE

    xil_printf(
        "[QR] detected codes : %d\r\n",
        count
    );

#endif


    if (count <= 0) {

        return QR_DECODE_NOT_FOUND;
    }


    for (index = 0;
         index < count;
         ++index) {

        quirc_decode_error_t error;

        quirc_decode_error_t flip_error;


        memset(
            &g_quirc_code,
            0,
            sizeof(g_quirc_code)
        );


        memset(
            &g_quirc_data,
            0,
            sizeof(g_quirc_data)
        );


        quirc_extract(
            g_quirc,
            index,
            &g_quirc_code
        );


#if QR_DECODE_VERBOSE

        xil_printf(
            "[QR] code[%d] size=%d\r\n",
            index,
            g_quirc_code.size
        );


        xil_printf(
            "[QR] corners="
            "(%d,%d) "
            "(%d,%d) "
            "(%d,%d) "
            "(%d,%d)\r\n",

            g_quirc_code.corners[0].x,
            g_quirc_code.corners[0].y,

            g_quirc_code.corners[1].x,
            g_quirc_code.corners[1].y,

            g_quirc_code.corners[2].x,
            g_quirc_code.corners[2].y,

            g_quirc_code.corners[3].x,
            g_quirc_code.corners[3].y
        );

#endif


        /* ====================================================================
         * Normal decode
         * ================================================================== */

        error =
            quirc_decode(
                &g_quirc_code,
                &g_quirc_data
            );


        if (error == QUIRC_SUCCESS) {

            return qr_store_result(
                &g_quirc_code,
                &g_quirc_data,
                result,
                result_size,
                box
            );
        }


#if QR_DECODE_VERBOSE

        xil_printf(
            "[QR] normal decode failed: %s\r\n",
            quirc_strerror(error)
        );

#endif


        /* ====================================================================
         * Mirror retry
         *
         * This is cheap compared with another complete 640x480 detection pass.
         * ================================================================== */

        if ((error == QUIRC_ERROR_FORMAT_ECC) ||
            (error == QUIRC_ERROR_DATA_ECC)) {

            quirc_flip(
                &g_quirc_code
            );


            memset(
                &g_quirc_data,
                0,
                sizeof(g_quirc_data)
            );


            flip_error =
                quirc_decode(
                    &g_quirc_code,
                    &g_quirc_data
                );


            if (flip_error == QUIRC_SUCCESS) {

                return qr_store_result(
                    &g_quirc_code,
                    &g_quirc_data,
                    result,
                    result_size,
                    box
                );
            }


#if QR_DECODE_VERBOSE

            xil_printf(
                "[QR] flip decode failed: %s\r\n",
                quirc_strerror(flip_error)
            );

#endif
        }
    }


    /*
     * At least one QR region existed,
     * but none produced a valid payload.
     */
    return QR_DECODE_FAIL;
}


/* ============================================================================
 * Run one complete quirc scan
 * ========================================================================== */

static int qr_run_scan(
    const u8 *gray,
    int mode,
    u8 raw_threshold,
    char *result,
    u32 result_size,
    qr_decode_box_t *box
)
{
    uint8_t *quirc_image;

    int width;
    int height;


    width = 0;
    height = 0;


    quirc_image =
        quirc_begin(
            g_quirc,
            &width,
            &height
        );


    if (quirc_image == NULL) {

        xil_printf(
            "[QR FAIL] quirc_begin()\r\n"
        );


        return QR_DECODE_FAIL;
    }


    if ((width != QR_DECODE_WIDTH) ||
        (height != QR_DECODE_HEIGHT)) {

        xil_printf(
            "[QR FAIL] unexpected image size %dx%d\r\n",
            width,
            height
        );


        return QR_DECODE_FAIL;
    }


    qr_fill_quirc_image(
        quirc_image,
        gray,
        mode,
        raw_threshold
    );


    /*
     * Finder/grid identification.
     */
    quirc_end(
        g_quirc
    );


    return qr_decode_detected(
        result,
        result_size,
        box
    );
}


/* ============================================================================
 * Initialize quirc
 * ========================================================================== */

int qr_decode_init(void)
{
    int status;


    if (g_quirc_initialized != 0) {

        return QR_DECODE_OK;
    }


    xil_printf(
        "\r\n"
        "[QR] Initializing quirc...\r\n"
    );


    g_quirc =
        quirc_new();


    if (g_quirc == NULL) {

        xil_printf(
            "[QR FAIL] quirc_new()\r\n"
        );


        return QR_DECODE_FAIL;
    }


    status =
        quirc_resize(
            g_quirc,
            QR_DECODE_WIDTH,
            QR_DECODE_HEIGHT
        );


    if (status < 0) {

        xil_printf(
            "[QR FAIL] quirc_resize(%d,%d)\r\n",
            QR_DECODE_WIDTH,
            QR_DECODE_HEIGHT
        );


        quirc_destroy(
            g_quirc
        );


        g_quirc =
            NULL;


        return QR_DECODE_FAIL;
    }


    g_qr_consecutive_miss =
        0U;


    g_quirc_initialized =
        1;


    xil_printf(
        "[PASS] quirc ready : %dx%d\r\n",
        QR_DECODE_WIDTH,
        QR_DECODE_HEIGHT
    );


    return QR_DECODE_OK;
}


/* ============================================================================
 * Decode one Gray8 frame
 *
 * FAST PATH - every frame:
 *
 *   1. Original Gray8
 *   2. Binary threshold 160
 *
 * ROBUST PATH - after 3 consecutive misses:
 *
 *   3. Binary threshold 96
 *   4. Binary threshold 128
 *   5. Binary threshold 192
 *
 * Successful decode:
 *
 *   consecutive_miss = 0
 *
 * Robust attempt finished without success:
 *
 *   consecutive_miss = 0
 *
 * Therefore the normal pattern becomes:
 *
 *   Frame A : fast
 *   Frame B : fast
 *   Frame C : fast + robust
 *   Frame D : fast
 *   ...
 * ========================================================================== */

int qr_decode_frame(
    const u8 *gray,
    char *result,
    u32 result_size,
    qr_decode_box_t *box
)
{
    u8 min_value;
    u8 max_value;

    u8 threshold_160;

    u8 threshold_96;
    u8 threshold_128;
    u8 threshold_192;

    int status;

    int saw_qr_region;


    /* ========================================================================
     * Parameter check
     * ====================================================================== */

    if ((gray == NULL) ||
        (result == NULL) ||
        (result_size == 0U)) {

        return QR_DECODE_FAIL;
    }


    result[0] =
        '\0';


    saw_qr_region =
        0;


    /* ========================================================================
     * Ensure decoder initialized
     * ====================================================================== */

    if (g_quirc_initialized == 0) {

        status =
            qr_decode_init();


        if (status != QR_DECODE_OK) {

            return QR_DECODE_FAIL;
        }
    }


    /* ========================================================================
     * Per-frame Gray8 range
     * ====================================================================== */

    qr_find_min_max(
        gray,
        &min_value,
        &max_value
    );


    threshold_160 =
        qr_make_raw_threshold(
            min_value,
            max_value,
            QR_FAST_THRESHOLD_NORM
        );


#if QR_DECODE_VERBOSE

    xil_printf(
        "\r\n"
        "[QR] min=%u max=%u "
        "fast_threshold=%u "
        "miss=%u\r\n",

        (unsigned int)min_value,
        (unsigned int)max_value,
        (unsigned int)threshold_160,
        (unsigned int)g_qr_consecutive_miss
    );

#endif


    /* ========================================================================
     * FAST SCAN 1
     *
     * Original Gray8
     * ====================================================================== */

#if QR_DECODE_VERBOSE

    xil_printf(
        "[QR] FAST 1 : original\r\n"
    );

#endif


    status =
        qr_run_scan(
            gray,
            QR_SCAN_ORIGINAL,
            0U,
            result,
            result_size,
            box
        );


    if (status == QR_DECODE_OK) {

        g_qr_consecutive_miss =
            0U;


        return QR_DECODE_OK;
    }


    if (status == QR_DECODE_FAIL) {

        saw_qr_region =
            1;
    }


    /* ========================================================================
     * FAST SCAN 2
     *
     * Binary threshold 160
     * ====================================================================== */

#if QR_DECODE_VERBOSE

    xil_printf(
        "[QR] FAST 2 : threshold 160 "
        "(raw=%u)\r\n",
        (unsigned int)threshold_160
    );

#endif


    status =
        qr_run_scan(
            gray,
            QR_SCAN_BINARY,
            threshold_160,
            result,
            result_size,
            box
        );


    if (status == QR_DECODE_OK) {

        g_qr_consecutive_miss =
            0U;


        return QR_DECODE_OK;
    }


    if (status == QR_DECODE_FAIL) {

        saw_qr_region =
            1;
    }


    /* ========================================================================
     * Current frame fast path failed
     * ====================================================================== */

    ++g_qr_consecutive_miss;


    /* ========================================================================
     * ROBUST FALLBACK
     *
     * Only after several consecutive failed frames.
     * ====================================================================== */

    if (g_qr_consecutive_miss >=
        QR_ROBUST_AFTER_MISSES) {

        /* ====================================================================
         * Prepare additional thresholds
         * ================================================================== */

        threshold_96 =
            qr_make_raw_threshold(
                min_value,
                max_value,
                QR_ROBUST_THRESHOLD_1
            );


        threshold_128 =
            qr_make_raw_threshold(
                min_value,
                max_value,
                QR_ROBUST_THRESHOLD_2
            );


        threshold_192 =
            qr_make_raw_threshold(
                min_value,
                max_value,
                QR_ROBUST_THRESHOLD_3
            );


#if QR_DECODE_VERBOSE

        xil_printf(
            "[QR] ROBUST fallback "
            "96=%u 128=%u 192=%u\r\n",

            (unsigned int)threshold_96,
            (unsigned int)threshold_128,
            (unsigned int)threshold_192
        );

#endif


        /* ====================================================================
         * ROBUST 1
         *
         * Threshold 96
         * ================================================================== */

        status =
            qr_run_scan(
                gray,
                QR_SCAN_BINARY,
                threshold_96,
                result,
                result_size,
                box
            );


        if (status == QR_DECODE_OK) {

            g_qr_consecutive_miss =
                0U;


            return QR_DECODE_OK;
        }


        if (status == QR_DECODE_FAIL) {

            saw_qr_region =
                1;
        }


        /* ====================================================================
         * ROBUST 2
         *
         * Threshold 128
         * ================================================================== */

        status =
            qr_run_scan(
                gray,
                QR_SCAN_BINARY,
                threshold_128,
                result,
                result_size,
                box
            );


        if (status == QR_DECODE_OK) {

            g_qr_consecutive_miss =
                0U;


            return QR_DECODE_OK;
        }


        if (status == QR_DECODE_FAIL) {

            saw_qr_region =
                1;
        }


        /* ====================================================================
         * ROBUST 3
         *
         * Threshold 192
         * ================================================================== */

        status =
            qr_run_scan(
                gray,
                QR_SCAN_BINARY,
                threshold_192,
                result,
                result_size,
                box
            );


        if (status == QR_DECODE_OK) {

            g_qr_consecutive_miss =
                0U;


            return QR_DECODE_OK;
        }


        if (status == QR_DECODE_FAIL) {

            saw_qr_region =
                1;
        }


        /*
         * Robust cycle completed.
         *
         * Start the next miss sequence from zero so that
         * the expensive robust path is not executed every frame.
         */
        g_qr_consecutive_miss =
            0U;
    }


    /* ========================================================================
     * Diagnostic classification
     *
     * REGION / ECC FAIL
     *
     * quirc identified at least one QR-like grid,
     * but payload decoding failed.
     *
     * NO REGION
     *
     * quirc did not identify a QR grid in any attempted scan.
     * ====================================================================== */

    if (saw_qr_region != 0) {

        xil_printf(
            "[QR MISS] REGION / ECC FAIL\r\n"
        );


        return QR_DECODE_FAIL;
    }


    xil_printf(
        "[QR MISS] NO REGION\r\n"
    );


    return QR_DECODE_NOT_FOUND;
}


/* ============================================================================
 * Deinitialize
 * ========================================================================== */

void qr_decode_deinit(void)
{
    if (g_quirc != NULL) {

        quirc_destroy(
            g_quirc
        );


        g_quirc =
            NULL;
    }


    g_qr_consecutive_miss =
        0U;


    g_quirc_initialized =
        0;
}