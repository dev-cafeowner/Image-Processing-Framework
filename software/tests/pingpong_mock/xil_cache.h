#include "xil_types.h"
typedef intptr_t INTPTR;
void Xil_DCacheFlushRange(INTPTR address,u32 bytes);
void Xil_DCacheInvalidateRange(INTPTR address,u32 bytes);
