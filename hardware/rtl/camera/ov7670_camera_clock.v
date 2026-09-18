`timescale 1ns/1ps
// Separate camera clock; main AXI/PS clocks and existing pinout stay unchanged.
module ov7670_camera_clock (
    input wire refclk100, aresetn,
    output wire cam_xclk, locked
);
    wire feedback, feedback_buf, clock24, clock24_buf;
    MMCME2_BASE #(.CLKIN1_PERIOD(10.0),.CLKFBOUT_MULT_F(6.0),
        .DIVCLK_DIVIDE(1),.CLKOUT0_DIVIDE_F(25.0),.STARTUP_WAIT("FALSE")) mmcm (
        .CLKIN1(refclk100),.CLKFBIN(feedback_buf),.CLKFBOUT(feedback),
        .CLKOUT0(clock24),.LOCKED(locked),.RST(!aresetn),.PWRDWN(1'b0));
    BUFG fb_buf (.I(feedback),.O(feedback_buf));
    BUFG out_buf (.I(clock24),.O(clock24_buf));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"),.INIT(1'b0),.SRTYPE("ASYNC")) forward_clock (
        .C(clock24_buf),.CE(1'b1),.D1(1'b1),.D2(1'b0),.R(!locked),.S(1'b0),.Q(cam_xclk));
endmodule
