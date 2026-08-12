`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : threshold
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. Global threshold on 8bit grayscale.
//
//       out = (v > thr) ? 255 : 0
//
//   Strictly greater, matching OpenCV THRESH_BINARY and model/ref_model.py.
//   127 -> 0, 128 -> 0, 129 -> 255 for thr = 128.
//
//   Point operation, so there is no neighbourhood, no line buffer and no border
//   handling. window_gen is not involved and the output is aligned with the
//   input beat for beat.
//
//   The output is strictly {0x00, 0xFF}. Binary images keep the full 8 bit
//   width per docs/frontend_axis_spec.md section 3, so that the interface does
//   not have to be renegotiated when the mode changes.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module threshold #(
    parameter integer DW = 8
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // Threshold value. Sampled every beat; a mid-frame change simply applies
    // from that pixel on. The shadow register that holds it stable for a whole
    // frame lives in the control block, not here.
    input  wire [7:0]           cfg_thresh,

    // Slave : Gray8
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // Master : binary, 0x00 or 0xFF
    output reg  [DW-1:0]        m_axis_tdata,
    output reg                  m_axis_tvalid,
    input  wire                 m_axis_tready,
    output reg                  m_axis_tuser,
    output reg                  m_axis_tlast
);

    wire [DW-1:0] bin = (s_axis_tdata > cfg_thresh) ? 8'hFF : 8'h00;

    // --------------------------------------------------------- handshake
    // Same single register stage as grayscale.v.
    assign s_axis_tready = m_axis_tready | ~m_axis_tvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DW{1'b0}};
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else if (s_axis_tready) begin
            m_axis_tvalid <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                m_axis_tdata <= bin;
                m_axis_tuser <= s_axis_tuser;
                m_axis_tlast <= s_axis_tlast;
            end
        end
    end

endmodule
