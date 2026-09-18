#include "platform.h"

#include "xil_printf.h"
#include "xstatus.h"

#include "vision_runtime.h"
#include "runtime_log.h"


int main(void)
{
    int status;


    init_platform();


    status =
        vision_runtime_run();

    runtime_log_finish();


    xil_printf(
        "\r\n"
        "Runtime result: %s (%d)\r\n",
        (status == XST_SUCCESS)
            ? "PASS"
            : "FAIL",
        status
    );


    for (;;) {
    }


    return 0;
}
