`timescale 1 ns / 1 ps

// AXI4-Stream pass-through adapter for the OV7670 capture core.
//
// The AXI peripheral Wizard originally generated a counter-based example
// transmitter in this module. The camera pipeline already produces a complete
// AXI4-Stream transaction, so this module only forwards that transaction to
// the packaged IP's M00_AXIS interface.
//
// Stream convention:
//   TDATA  : RGB565 pixel
//   TUSER  : start of frame
//   TLAST  : end of line
//   TSTRB  : every byte of TDATA is valid
//   TREADY : propagated back to the camera FIFO

module ov7670_axis_master_stream_v1_0_M00_AXIS #
(
    parameter integer C_M_AXIS_TDATA_WIDTH = 16,

    // Retained temporarily for compatibility with the Wizard top-level
    // parameter list. It is not used by the pass-through implementation.
    parameter integer C_M_START_COUNT = 32
)
(
    // Stream produced by ov7670_axis_top.
    input  wire                                  CORE_TVALID,
    input  wire [C_M_AXIS_TDATA_WIDTH-1 : 0]    CORE_TDATA,
    output wire                                  CORE_TREADY,
    input  wire                                  CORE_TUSER,
    input  wire                                  CORE_TLAST,

    // AXI4-Stream interface clock and active-low reset.
    input  wire                                  M_AXIS_ACLK,
    input  wire                                  M_AXIS_ARESETN,

    // Packaged IP AXI4-Stream master interface.
    output wire                                  M_AXIS_TVALID,
    output wire [C_M_AXIS_TDATA_WIDTH-1 : 0]    M_AXIS_TDATA,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] M_AXIS_TSTRB,
    output wire                                  M_AXIS_TUSER,
    output wire                                  M_AXIS_TLAST,
    input  wire                                  M_AXIS_TREADY
);

    // No buffering is required here because ov7670_axis_top already contains
    // the elastic FIFO. Hold both directions inactive while reset is asserted.
    assign M_AXIS_TVALID = CORE_TVALID && M_AXIS_ARESETN;
    assign M_AXIS_TDATA  = CORE_TDATA;
    assign M_AXIS_TSTRB  = {(C_M_AXIS_TDATA_WIDTH/8){1'b1}};
    assign M_AXIS_TUSER  = CORE_TUSER;
    assign M_AXIS_TLAST  = CORE_TLAST;

    assign CORE_TREADY   = M_AXIS_TREADY && M_AXIS_ARESETN;

    // M_AXIS_ACLK is intentionally not used by sequential logic. All stream
    // signals are generated in this same clock domain by ov7670_axis_top.

endmodule
