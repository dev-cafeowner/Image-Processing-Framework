`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : axis_reg_slice
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream register slice (full skid buffer). Breaks the combinational
//   tready chain: s_tready comes straight from a register, so timing paths
//   stop here in BOTH directions at the cost of one beat of latency.
//
//   Why it exists: every stage in the chain computes
//       s_tready = m_tready | ~m_tvalid
//   which is correct but combinational, and the five axis_bypass muxes stack
//   on top. Measured on the 1-stage case the path is 94 percent routing, so it
//   grows with distance, not logic - the fix is a register, not optimisation.
//   See docs/STATUS.md 3-3.
//
//   Hand-written rather than the Xilinx Register Slice IP so the harness can
//   keep compiling rtl/*.v directly, and so the behaviour is verifiable against
//   the golden model like everything else in this chain.
//
//   Operation: 'main' is the output register, 'skid' catches the one beat that
//   is already in flight when downstream stalls (s_tready is registered, so
//   upstream learns about the stall one cycle late - that beat lands in skid).
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module axis_reg_slice #(
    parameter integer DW = 8
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [DW-1:0]        s_tdata,
    input  wire                 s_tvalid,
    output wire                 s_tready,
    input  wire                 s_tuser,
    input  wire                 s_tlast,

    output reg  [DW-1:0]        m_tdata,
    output reg                  m_tvalid,
    input  wire                 m_tready,
    output reg                  m_tuser,
    output reg                  m_tlast
);

    reg [DW-1:0] skid_tdata;
    reg          skid_tuser, skid_tlast, skid_valid;

    // Registered: the whole point of the slice.
    assign s_tready = ~skid_valid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_tvalid   <= 1'b0;
            m_tdata    <= {DW{1'b0}};
            m_tuser    <= 1'b0;
            m_tlast    <= 1'b0;
            skid_valid <= 1'b0;
        end else begin
            if (m_tready || !m_tvalid) begin
                // Output stage can take a beat: skid first, then the input.
                if (skid_valid) begin
                    m_tdata    <= skid_tdata;
                    m_tuser    <= skid_tuser;
                    m_tlast    <= skid_tlast;
                    m_tvalid   <= 1'b1;
                    skid_valid <= 1'b0;
                end else begin
                    m_tdata  <= s_tdata;
                    m_tuser  <= s_tuser;
                    m_tlast  <= s_tlast;
                    m_tvalid <= s_tvalid;
                end
            end else if (s_tvalid && !skid_valid) begin
                // Output stalled and a beat was already in flight.
                skid_tdata <= s_tdata;
                skid_tuser <= s_tuser;
                skid_tlast <= s_tlast;
                skid_valid <= 1'b1;
            end
        end
    end

endmodule
