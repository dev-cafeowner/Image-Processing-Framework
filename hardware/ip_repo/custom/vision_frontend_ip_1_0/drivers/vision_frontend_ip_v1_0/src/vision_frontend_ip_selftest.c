
/***************************** Include Files *******************************/
#include "vision_frontend_ip.h"
#include "xparameters.h"
#include "stdio.h"
#include "xil_io.h"

/************************** Constant Definitions ***************************/
/************************** Function Definitions ***************************/
/**
 *
 * Run a self-test on the driver/device. Note this may be a destructive test if
 * resets of the device are performed.
 *
 * If the hardware system is not built correctly, this function may never
 * return to the caller.
 *
 * @param   baseaddr_p is the base address of the VISION_FRONTEND_IPinstance to be worked on.
 *
 * @return
 *
 *    - XST_SUCCESS   if all self-test code passed
 *    - XST_FAILURE   if any self-test code failed
 *
 * @note    Caching must be turned off for this function to work.
 * @note    Self test may fail if data memory and device are not on the same bus.
 *
 */
XStatus VISION_FRONTEND_IP_Reg_SelfTest(void * baseaddr_p)
{
	u32 baseaddr;
	u32 saved_mode;
	u32 saved_thresh;
	u32 saved_geom;

	baseaddr = (u32) baseaddr_p;

	xil_printf("******************************\n\r");
	xil_printf("* User Peripheral Self Test\n\r");
	xil_printf("******************************\n\n\r");

	xil_printf("Vision Front-End AXI4-Lite register test...\n\r");

	if (VISION_FRONTEND_IP_mReadReg(
		    baseaddr, VISION_FRONTEND_IP_VERSION_OFFSET) !=
	    VISION_FRONTEND_IP_VERSION_VALUE) {
		xil_printf("Unexpected IP version at address %x\n\r",
			   (int)baseaddr + VISION_FRONTEND_IP_VERSION_OFFSET);
		return XST_FAILURE;
	}

	/*
	 * Do not write CTRL: STAT_CLEAR is a one-cycle command and intentionally
	 * does not read back. Preserve and restore the three ordinary RW
	 * configuration registers.
	 */
	saved_mode = VISION_FRONTEND_IP_mReadReg(
		baseaddr, VISION_FRONTEND_IP_FE_MODE_OFFSET);
	saved_thresh = VISION_FRONTEND_IP_mReadReg(
		baseaddr, VISION_FRONTEND_IP_THRESH_OFFSET);
	saved_geom = VISION_FRONTEND_IP_mReadReg(
		baseaddr, VISION_FRONTEND_IP_GEOM_OFFSET);

	VISION_FRONTEND_IP_mWriteReg(
		baseaddr, VISION_FRONTEND_IP_FE_MODE_OFFSET, 0x00000015U);
	VISION_FRONTEND_IP_mWriteReg(
		baseaddr, VISION_FRONTEND_IP_THRESH_OFFSET, 0x000005A5U);
	VISION_FRONTEND_IP_mWriteReg(
		baseaddr, VISION_FRONTEND_IP_GEOM_OFFSET, 0x01E00280U);

	if ((VISION_FRONTEND_IP_mReadReg(
		     baseaddr, VISION_FRONTEND_IP_FE_MODE_OFFSET) != 0x00000015U) ||
	    (VISION_FRONTEND_IP_mReadReg(
		     baseaddr, VISION_FRONTEND_IP_THRESH_OFFSET) != 0x000005A5U) ||
	    (VISION_FRONTEND_IP_mReadReg(
		     baseaddr, VISION_FRONTEND_IP_GEOM_OFFSET) != 0x01E00280U)) {
		xil_printf("AXI4-Lite configuration register test failed\n\r");
		VISION_FRONTEND_IP_mWriteReg(
			baseaddr, VISION_FRONTEND_IP_FE_MODE_OFFSET, saved_mode);
		VISION_FRONTEND_IP_mWriteReg(
			baseaddr, VISION_FRONTEND_IP_THRESH_OFFSET, saved_thresh);
		VISION_FRONTEND_IP_mWriteReg(
			baseaddr, VISION_FRONTEND_IP_GEOM_OFFSET, saved_geom);
		return XST_FAILURE;
	}

	VISION_FRONTEND_IP_mWriteReg(
		baseaddr, VISION_FRONTEND_IP_FE_MODE_OFFSET, saved_mode);
	VISION_FRONTEND_IP_mWriteReg(
		baseaddr, VISION_FRONTEND_IP_THRESH_OFFSET, saved_thresh);
	VISION_FRONTEND_IP_mWriteReg(
		baseaddr, VISION_FRONTEND_IP_GEOM_OFFSET, saved_geom);

	xil_printf("   - version and configuration registers passed\n\n\r");

	return XST_SUCCESS;
}
