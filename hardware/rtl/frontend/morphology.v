`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : morphology
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. Opening or Closing, built from two morph_op stages.
//
//       cfg_close = 0   Opening = Erosion then Dilation   removes small noise
//       cfg_close = 1   Closing = Dilation then Erosion   repairs broken edges
//
//   Only the order changes, so the two stages take opposite cfg_op and nothing
//   else differs. Chaining the atom instead of writing a fused block means the
//   erode and dilate golden vectors already cover the arithmetic; the open and
//   close vectors then only have to confirm the composition.
//
//   Cost of being a chain, and it matters downstream:
//     latency          two window stages, about two rows
//     frame occupancy  each stage adds W*2 beats of flush
//     valid margin     replicate padding grows 1 px per stage, so 2 px here
//
//   The last item is the one the feature extraction side must know about; see
//   VALID_MARGIN in docs/extractor_handoff_spec.md section 8.
//
//   Morphology needs a binary input. Running it on grayscale is a well defined
//   min/max filter but has no golden vector and is not what the chain means,
//   which is why FE_MODE rejects morph_en without thresh_en (rule R2).
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module morphology #(
    parameter integer DW    = 8,
    parameter integer MAX_W = 640
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [11:0]          cfg_width,
    input  wire [11:0]          cfg_height,
    input  wire                 cfg_close,      // 0 = opening, 1 = closing

    // Slave : binary
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // Master : binary
    output wire [DW-1:0]        m_axis_tdata,
    output wire                 m_axis_tvalid,
    input  wire                 m_axis_tready,
    output wire                 m_axis_tuser,
    output wire                 m_axis_tlast
);

    // Opening erodes first, Closing dilates first. Stage 2 is always the other.
    wire op1 =  cfg_close;
    wire op2 = ~cfg_close;

    wire [DW-1:0] mid_tdata;
    wire          mid_tvalid, mid_tready, mid_tuser, mid_tlast;

    morph_op #(
        .DW    (DW),
        .MAX_W (MAX_W)
    ) u_stage1 (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .cfg_width     (cfg_width),
        .cfg_height    (cfg_height),
        .cfg_op        (op1),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tuser  (s_axis_tuser),
        .s_axis_tlast  (s_axis_tlast),
        .m_axis_tdata  (mid_tdata),
        .m_axis_tvalid (mid_tvalid),
        .m_axis_tready (mid_tready),
        .m_axis_tuser  (mid_tuser),
        .m_axis_tlast  (mid_tlast)
    );

    morph_op #(
        .DW    (DW),
        .MAX_W (MAX_W)
    ) u_stage2 (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .cfg_width     (cfg_width),
        .cfg_height    (cfg_height),
        .cfg_op        (op2),
        .s_axis_tdata  (mid_tdata),
        .s_axis_tvalid (mid_tvalid),
        .s_axis_tready (mid_tready),
        .s_axis_tuser  (mid_tuser),
        .s_axis_tlast  (mid_tlast),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tuser  (m_axis_tuser),
        .m_axis_tlast  (m_axis_tlast)
    );

endmodule
