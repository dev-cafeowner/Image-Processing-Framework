`timescale 1ns/1ps
// Experimental VGA30 returned-clock conditioner. Only enable after the sensor
// is configured for continuous 24MHz PCLK. 24 * 32 = 768MHz VCO; output /32.
// LOW bandwidth filters phase jitter but is not an electrical wiring repair.
// The 90-degree offset samples later in the byte eye; STA and board tests are
// required. No performance claim follows from the MMCM locking alone.
module ov7670_pclk_clean_clock (
    input wire pclk_in, enable,
    output wire pclk_out, locked
);
    wire feedback, feedback_buf, cleaned;
    MMCME2_BASE #(.BANDWIDTH("LOW"), .CLKIN1_PERIOD(41.666667),
        .CLKFBOUT_MULT_F(32.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(32.0), .CLKOUT0_PHASE(90.0),
        .STARTUP_WAIT("FALSE")) mmcm (
        .CLKIN1(pclk_in), .CLKFBIN(feedback_buf), .CLKFBOUT(feedback),
        .CLKOUT0(cleaned), .LOCKED(locked), .RST(!enable), .PWRDWN(1'b0));
    BUFG fb_buf (.I(feedback), .O(feedback_buf));
    BUFG out_buf (.I(cleaned), .O(pclk_out));
endmodule
