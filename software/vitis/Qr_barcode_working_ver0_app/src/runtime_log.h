#ifndef RUNTIME_LOG_H
#define RUNTIME_LOG_H
#include <stdint.h>

/* Single PS task only; not ISR-safe. Startup defaults to blocking, streaming
 * mode queues complete messages and never waits for a full UART TX FIFO. */
void runtime_log_set_async(int enable);
void runtime_log_printf(const char *format, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;
void runtime_log_service(void); /* maximum 32 bytes per invocation */
uint32_t runtime_log_dropped(void);
void runtime_log_finish(void); /* blocking drain, only on application exit */
#endif
