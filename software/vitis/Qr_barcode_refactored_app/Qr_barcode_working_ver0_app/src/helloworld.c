#include "platform.h"

#include "xil_printf.h"
#include "xstatus.h"

#include "stage6_qr_runtime.h"


int main(void)
{
    int status;


    init_platform();


    status =
        stage6_qr_runtime_run();


    xil_printf(
        "\r\n"
        "Stage 6 result: %s (%d)\r\n",
        (status == XST_SUCCESS)
            ? "PASS"
            : "FAIL",
        status
    );


    for (;;) {
    }


    return 0;
}