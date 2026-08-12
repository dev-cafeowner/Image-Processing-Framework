#include "qr_app_ui.h"

#include <string.h>

#include "xil_printf.h"

#include "qr_decode.h"


/* ============================================================================
 * Persistent application UI state
 *
 * The latest successful QR payload is retained across frames where no QR is
 * detected. A new successful decode replaces this value.
 * ========================================================================== */

static char s_last_result[
    QR_DECODE_RESULT_MAX
];


/* ============================================================================
 * Initialize UI state
 * ========================================================================== */

void qr_app_ui_init(void)
{
    s_last_result[0] =
        '\0';
}


/* ============================================================================
 * Update last successful QR payload
 * ========================================================================== */

void qr_app_ui_set_result(
    const char *result
)
{
    if ((result == NULL) ||
        (result[0] == '\0')) {

        return;
    }


    strncpy(
        s_last_result,
        result,
        sizeof(s_last_result) - 1U
    );


    s_last_result[
        sizeof(s_last_result) - 1U
    ] = '\0';
}


/* ============================================================================
 * UART application UI
 *
 * Final HDMI overlay will use exactly the same state.
 * ========================================================================== */
/* ============================================================================
 * HDMI UI
 *
 * 5 x 7 font
 * scale = 2
 *
 * Gray8 framebuffer 위에 직접 그린 뒤
 * hdmi_display_show_gray8()가 RGB888 HDMI framebuffer로 복사한다.
 * ========================================================================== */

#define QR_APP_UI_WIDTH              640U
#define QR_APP_UI_HEIGHT             480U

#define QR_APP_UI_FONT_WIDTH         5U
#define QR_APP_UI_FONT_HEIGHT        7U

#define QR_APP_UI_FONT_SCALE         2U

#define QR_APP_UI_PANEL_HEIGHT       64U

#define QR_APP_UI_BG                 0U
#define QR_APP_UI_FG                 255U


/* ============================================================================
 * 5x7 character bitmap
 *
 * bit4 = left pixel
 * bit0 = right pixel
 * ========================================================================== */

static void qr_app_ui_font5x7(
    char c,
    u8 rows[7]
)
{
    u32 i;


    for (i = 0U; i < 7U; ++i) {
        rows[i] = 0U;
    }


    /* lowercase -> uppercase */
    if ((c >= 'a') && (c <= 'z')) {
        c = (char)(c - 'a' + 'A');
    }


    switch (c) {

    case 'A':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1FU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'B':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1EU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x1EU;
        break;

    case 'C':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x10U;
        rows[3]=0x10U; rows[4]=0x10U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case 'D':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x1EU;
        break;

    case 'E':
        rows[0]=0x1FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x1FU;
        break;

    case 'F':
        rows[0]=0x1FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x10U;
        break;

    case 'G':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x10U;
        rows[3]=0x17U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0FU;
        break;

    case 'H':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1FU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'I':
        rows[0]=0x1FU; rows[1]=0x04U; rows[2]=0x04U;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x1FU;
        break;

    case 'J':
        rows[0]=0x07U; rows[1]=0x02U; rows[2]=0x02U;
        rows[3]=0x02U; rows[4]=0x12U; rows[5]=0x12U;
        rows[6]=0x0CU;
        break;

    case 'K':
        rows[0]=0x11U; rows[1]=0x12U; rows[2]=0x14U;
        rows[3]=0x18U; rows[4]=0x14U; rows[5]=0x12U;
        rows[6]=0x11U;
        break;

    case 'L':
        rows[0]=0x10U; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x10U; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x1FU;
        break;

    case 'M':
        rows[0]=0x11U; rows[1]=0x1BU; rows[2]=0x15U;
        rows[3]=0x15U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'N':
        rows[0]=0x11U; rows[1]=0x19U; rows[2]=0x15U;
        rows[3]=0x13U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'O':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case 'P':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1EU; rows[4]=0x10U; rows[5]=0x10U;
        rows[6]=0x10U;
        break;

    case 'Q':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x15U; rows[5]=0x12U;
        rows[6]=0x0DU;
        break;

    case 'R':
        rows[0]=0x1EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x1EU; rows[4]=0x14U; rows[5]=0x12U;
        rows[6]=0x11U;
        break;

    case 'S':
        rows[0]=0x0FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x0EU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x1EU;
        break;

    case 'T':
        rows[0]=0x1FU; rows[1]=0x04U; rows[2]=0x04U;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x04U;
        break;

    case 'U':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case 'V':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x11U; rows[4]=0x11U; rows[5]=0x0AU;
        rows[6]=0x04U;
        break;

    case 'W':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x15U; rows[4]=0x15U; rows[5]=0x15U;
        rows[6]=0x0AU;
        break;

    case 'X':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x0AU;
        rows[3]=0x04U; rows[4]=0x0AU; rows[5]=0x11U;
        rows[6]=0x11U;
        break;

    case 'Y':
        rows[0]=0x11U; rows[1]=0x11U; rows[2]=0x0AU;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x04U;
        break;

    case 'Z':
        rows[0]=0x1FU; rows[1]=0x01U; rows[2]=0x02U;
        rows[3]=0x04U; rows[4]=0x08U; rows[5]=0x10U;
        rows[6]=0x1FU;
        break;


    case '0':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x13U;
        rows[3]=0x15U; rows[4]=0x19U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case '1':
        rows[0]=0x04U; rows[1]=0x0CU; rows[2]=0x04U;
        rows[3]=0x04U; rows[4]=0x04U; rows[5]=0x04U;
        rows[6]=0x0EU;
        break;

    case '2':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x01U;
        rows[3]=0x02U; rows[4]=0x04U; rows[5]=0x08U;
        rows[6]=0x1FU;
        break;

    case '3':
        rows[0]=0x1EU; rows[1]=0x01U; rows[2]=0x01U;
        rows[3]=0x0EU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x1EU;
        break;

    case '4':
        rows[0]=0x02U; rows[1]=0x06U; rows[2]=0x0AU;
        rows[3]=0x12U; rows[4]=0x1FU; rows[5]=0x02U;
        rows[6]=0x02U;
        break;

    case '5':
        rows[0]=0x1FU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x1EU;
        break;

    case '6':
        rows[0]=0x0EU; rows[1]=0x10U; rows[2]=0x10U;
        rows[3]=0x1EU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case '7':
        rows[0]=0x1FU; rows[1]=0x01U; rows[2]=0x02U;
        rows[3]=0x04U; rows[4]=0x08U; rows[5]=0x08U;
        rows[6]=0x08U;
        break;

    case '8':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x0EU; rows[4]=0x11U; rows[5]=0x11U;
        rows[6]=0x0EU;
        break;

    case '9':
        rows[0]=0x0EU; rows[1]=0x11U; rows[2]=0x11U;
        rows[3]=0x0FU; rows[4]=0x01U; rows[5]=0x01U;
        rows[6]=0x0EU;
        break;


    case ':':
        rows[1]=0x04U;
        rows[2]=0x04U;
        rows[4]=0x04U;
        rows[5]=0x04U;
        break;

    case '-':
        rows[3]=0x0EU;
        break;

    case '.':
        rows[6]=0x04U;
        break;

    case '/':
        rows[0]=0x01U;
        rows[1]=0x02U;
        rows[2]=0x02U;
        rows[3]=0x04U;
        rows[4]=0x08U;
        rows[5]=0x08U;
        rows[6]=0x10U;
        break;

    case ' ':
        break;


    default:
        /* '?' */
        rows[0]=0x0EU;
        rows[1]=0x11U;
        rows[2]=0x01U;
        rows[3]=0x02U;
        rows[4]=0x04U;
        rows[6]=0x04U;
        break;
    }
}


/* ============================================================================
 * Fill rectangle on Gray8 image
 * ========================================================================== */

static void qr_app_ui_fill_rect(
    u8 *image,
    u32 x,
    u32 y,
    u32 width,
    u32 height,
    u8 value
)
{
    u32 px;
    u32 py;


    if (image == NULL) {
        return;
    }


    for (py = 0U; py < height; ++py) {

        if ((y + py) >= QR_APP_UI_HEIGHT) {
            break;
        }


        for (px = 0U; px < width; ++px) {

            if ((x + px) >= QR_APP_UI_WIDTH) {
                break;
            }


            image[
                ((y + py) * QR_APP_UI_WIDTH)
                + (x + px)
            ] = value;
        }
    }
}


/* ============================================================================
 * Draw one character
 * ========================================================================== */

static void qr_app_ui_draw_char(
    u8 *image,
    u32 x,
    u32 y,
    char c
)
{
    u8 rows[7];

    u32 row;
    u32 col;

    u32 sx;
    u32 sy;


    qr_app_ui_font5x7(
        c,
        rows
    );


    for (row = 0U;
         row < QR_APP_UI_FONT_HEIGHT;
         ++row) {

        for (col = 0U;
             col < QR_APP_UI_FONT_WIDTH;
             ++col) {

            if ((rows[row] &
                 (1U << (4U - col))) == 0U) {

                continue;
            }


            for (sy = 0U;
                 sy < QR_APP_UI_FONT_SCALE;
                 ++sy) {

                for (sx = 0U;
                     sx < QR_APP_UI_FONT_SCALE;
                     ++sx) {

                    u32 px;
                    u32 py;


                    px =
                        x +
                        (col * QR_APP_UI_FONT_SCALE) +
                        sx;


                    py =
                        y +
                        (row * QR_APP_UI_FONT_SCALE) +
                        sy;


                    if ((px < QR_APP_UI_WIDTH) &&
                        (py < QR_APP_UI_HEIGHT)) {

                        image[
                            (py * QR_APP_UI_WIDTH) +
                            px
                        ] = QR_APP_UI_FG;
                    }
                }
            }
        }
    }
}


/* ============================================================================
 * Draw string
 * ========================================================================== */

static void qr_app_ui_draw_text(
    u8 *image,
    u32 x,
    u32 y,
    const char *text
)
{
    u32 cursor_x;

    u32 char_step;


    if ((image == NULL) ||
        (text == NULL)) {

        return;
    }


    cursor_x =
        x;


    char_step =
        (
            QR_APP_UI_FONT_WIDTH *
            QR_APP_UI_FONT_SCALE
        ) +
        QR_APP_UI_FONT_SCALE;


    while (*text != '\0') {

        if ((cursor_x +
             (
                 QR_APP_UI_FONT_WIDTH *
                 QR_APP_UI_FONT_SCALE
             )) >= QR_APP_UI_WIDTH) {

            break;
        }


        qr_app_ui_draw_char(
            image,
            cursor_x,
            y,
            *text
        );


        cursor_x +=
            char_step;


        ++text;
    }
}


/* ============================================================================
 * Draw final UI
 *
 * STATUS:
 *
 * Current frame recognition state.
 *
 * RESULT:
 *
 * Last successful QR payload.
 * It persists until another valid QR is decoded.
 * ========================================================================== */

void qr_app_ui_draw(
    u8 *image,
    int detected
)
{
    /*
     * Black banner over camera image.
     */
    qr_app_ui_fill_rect(
        image,
        0U,
        0U,
        QR_APP_UI_WIDTH,
        QR_APP_UI_PANEL_HEIGHT,
        QR_APP_UI_BG
    );


    /*
     * Line 1
     */
    qr_app_ui_draw_text(
        image,
        12U,
        8U,
        "STATUS:"
    );


    if (detected != 0) {

        qr_app_ui_draw_text(
            image,
            108U,
            8U,
            "DETECTED"
        );
    }
    else {

        qr_app_ui_draw_text(
            image,
            108U,
            8U,
            "SEARCHING"
        );
    }


    /*
     * Line 2
     */
    qr_app_ui_draw_text(
        image,
        12U,
        36U,
        "RESULT:"
    );


    if (s_last_result[0] != '\0') {

        qr_app_ui_draw_text(
            image,
            108U,
            36U,
            s_last_result
        );
    }
    else {

        qr_app_ui_draw_text(
            image,
            108U,
            36U,
            "--"
        );
    }
}

void qr_app_ui_print(
    int detected
)
{
    xil_printf(
        "\r\n"
        "----------------------------------------\r\n"
    );


    if (detected != 0) {

        xil_printf(
            "STATUS : DETECTED\r\n"
        );
    }
    else {

        xil_printf(
            "STATUS : SEARCHING\r\n"
        );
    }


    /*
     * IMPORTANT:
     *
     * s_last_result persists across frames where QR decode fails
     * or no QR is visible.
     */
    if (s_last_result[0] != '\0') {

        xil_printf(
            "RESULT : %s\r\n",
            s_last_result
        );
    }
    else {

        xil_printf(
            "RESULT : --\r\n"
        );
    }


    xil_printf(
        "----------------------------------------\r\n"
    );
}


