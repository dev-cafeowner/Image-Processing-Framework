#include "runtime_log.h"
#include <stdarg.h>
#include <stdio.h>

#ifdef RUNTIME_LOG_HOST_TEST
extern int runtime_log_test_full(void);
extern void runtime_log_test_write(unsigned char value);
#define TX_FULL() runtime_log_test_full()
#define TX_WRITE(v) runtime_log_test_write(v)
#else
#include "xparameters.h"
#include "xuartps_hw.h"
/* Matches the UART selected as stdout in this project's exported BSP. */
#define TX_FULL() XUartPs_IsTransmitFull(XPAR_XUARTPS_0_BASEADDR)
#define TX_WRITE(v) XUartPs_WriteReg(XPAR_XUARTPS_0_BASEADDR, XUARTPS_FIFO_OFFSET, (v))
#endif

#define LOG_CAPACITY 4096U
#define LOG_MESSAGE 768U
static unsigned char bytes[LOG_CAPACITY];
static unsigned int head, tail, used;
static uint32_t dropped;
static int async_mode;

void runtime_log_service(void)
{
    unsigned int budget = 32U;
    while (used && budget && !TX_FULL()) {
        TX_WRITE(bytes[tail]);
        tail = (tail + 1U) % LOG_CAPACITY;
        --used;
        --budget;
    }
}

void runtime_log_finish(void)
{
    /* Explicitly blocking: never call this on the normal streaming path. */
    while (used) runtime_log_service();
    async_mode = 0;
}

void runtime_log_set_async(int enable)
{
    if (!enable) runtime_log_finish();
    else async_mode = 1;
}

uint32_t runtime_log_dropped(void) { return dropped; }

void runtime_log_printf(const char *format, ...)
{
    char message[LOG_MESSAGE];
    va_list args;
    int length, i;
    va_start(args, format);
    length = vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    if (length < 0 || (unsigned int)length >= sizeof(message)) {
        ++dropped; /* Reject whole message, never publish a truncated record. */
        return;
    }
    if (!async_mode) {
        for (i = 0; i < length; ++i) {
            while (TX_FULL()) { }
            TX_WRITE((unsigned char)message[i]);
        }
        return;
    }
    runtime_log_service();
    if ((unsigned int)length > LOG_CAPACITY - used) {
        ++dropped;
        return;
    }
    for (i = 0; i < length; ++i) {
        bytes[head] = (unsigned char)message[i];
        head = (head + 1U) % LOG_CAPACITY;
    }
    used += (unsigned int)length;
    runtime_log_service();
}
