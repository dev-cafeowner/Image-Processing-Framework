#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "runtime_log.h"

static char output[32768];
static unsigned int length;
static int full;
int runtime_log_test_full(void) { return full; }
void runtime_log_test_write(unsigned char value)
{
    assert(length + 1 < sizeof(output));
    output[length++] = (char)value;
    output[length] = 0;
}

int main(void)
{
    char long_line[800];
    unsigned int before, i;
    runtime_log_printf("startup %d\r\n", 1);
    assert(strcmp(output, "startup 1\r\n") == 0);
    runtime_log_set_async(1);
    full = 1;
    runtime_log_printf("one\r\n");
    runtime_log_printf("two\r\n");
    before = length;
    runtime_log_service();
    assert(length == before); /* Full TX never blocks. */
    full = 0;
    runtime_log_service();
    assert(strcmp(output + before, "one\r\ntwo\r\n") == 0);
    memset(long_line, 'a', sizeof(long_line));
    long_line[sizeof(long_line)-1] = 0;
    runtime_log_printf("%s", long_line);
    assert(runtime_log_dropped() == 1); /* Oversized line rejected as a whole. */
    full = 1;
    for (i = 0; i < 10; ++i) runtime_log_printf("%0600u", i);
    assert(runtime_log_dropped() == 5); /* 6*600B fit, 4 entire lines rejected. */
    before = length;
    full = 0;
    runtime_log_service();
    assert(length == before + 32); /* Work is bounded even when FIFO is empty. */
    runtime_log_finish();
    assert(length == before + 3600);
    /* Repeated wrap-around and ordered records. */
    runtime_log_set_async(1);
    before = length;
    for (i = 0; i < 2000; ++i) {
        runtime_log_printf("%04u\n", i);
        runtime_log_service();
    }
    runtime_log_finish();
    for (i = 0; i < 2000; ++i) {
        char expected[8];
        snprintf(expected, sizeof(expected), "%04u\n", i);
        assert(memcmp(output + before + 5*i, expected, 5) == 0);
    }
    assert(runtime_log_dropped() == 5);
    puts("PASS: bounded UART service, full TX, overflow, truncation, wrap, ordering");
    return 0;
}
