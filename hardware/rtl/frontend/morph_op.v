`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : morph_op
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. One atomic 3x3 morphological operation.
//
//       cfg_op = 0   Erosion   = window minimum
//       cfg_op = 1   Dilation  = window maximum
//
//   Neighbourhood generation, replicate borders and the handshake all live in
//   window_gen. This module is only the arithmetic, same as gaussian.v.
//
//   Opening and Closing are compositions of this block, so morphology.v just
//   chains two instances with opposite cfg_op. Keeping the atom separate means
//   the erode and dilate golden vectors verify exactly the logic that the
//   composed operations reuse.
//
//   On a binary image the minimum is a 9 input AND and the maximum a 9 input
//   OR, and synthesis reduces to that on its own. The general min/max form is
//   kept because it is what model/ref_model.py computes and because it stays
//   correct if the stage is ever fed grayscale.
//
//   The tree is 4 comparator levels deep: 9 -> 5 -> 3 -> 2 -> 1. That needs two
//   register stages, not one - see the note above the pipeline below.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module morph_op #(
    parameter integer DW    = 8,
    parameter integer MAX_W = 640
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [11:0]          cfg_width,
    input  wire [11:0]          cfg_height,
    input  wire                 cfg_op,         // 0 = erode (min), 1 = dilate (max)

    // Slave : binary or grayscale
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // Master
    output reg  [DW-1:0]        m_axis_tdata,
    output reg                  m_axis_tvalid,
    input  wire                 m_axis_tready,
    output reg                  m_axis_tuser,
    output reg                  m_axis_tlast
);

    // ------------------------------------------------------ neighbourhood
    wire [9*DW-1:0] win;
    wire            win_valid, win_ready, win_user, win_last;

    window_gen #(
        .DW    (DW),
        .MAX_W (MAX_W)
    ) u_win (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .cfg_width     (cfg_width),
        .cfg_height    (cfg_height),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tuser  (s_axis_tuser),
        .s_axis_tlast  (s_axis_tlast),
        .m_win_tdata   (win),
        .m_win_tvalid  (win_valid),
        .m_win_tready  (win_ready),
        .m_win_tuser   (win_user),
        .m_win_tlast   (win_last)
    );

    // ------------------------------------------------------ min / max tree
    function [DW-1:0] pick;
        input               op;
        input [DW-1:0]      a;
        input [DW-1:0]      b;
        begin
            pick = op ? ((a > b) ? a : b)      // dilate : maximum
                      : ((a < b) ? a : b);     // erode  : minimum
        end
    endfunction

    wire [DW-1:0] w0 = win[0*DW +: DW];
    wire [DW-1:0] w1 = win[1*DW +: DW];
    wire [DW-1:0] w2 = win[2*DW +: DW];
    wire [DW-1:0] w3 = win[3*DW +: DW];
    wire [DW-1:0] w4 = win[4*DW +: DW];
    wire [DW-1:0] w5 = win[5*DW +: DW];
    wire [DW-1:0] w6 = win[6*DW +: DW];
    wire [DW-1:0] w7 = win[7*DW +: DW];
    wire [DW-1:0] w8 = win[8*DW +: DW];

    // cfg_op reaches every comparator in the tree, so taking it straight from
    // the port puts an input pin at the head of a wide fanout. It is constant
    // within a frame, so it is registered like the geometry in adaptive.v.
    reg op_q;
    always @(posedge aclk) begin
        if (!aresetn) op_q <= 1'b0;
        else          op_q <= cfg_op;
    end

    // ------------------------------------------------- pipeline stage 1 / 2
    // Two register stages, not one. With one, the four comparator levels plus
    // the output mux measured WNS -2.378 ns: 13 logic levels, worse than any
    // other stage in the chain. A min/max tree is deeper than an adder tree of
    // the same span because each node is a compare AND a select, and cfg_op
    // makes both arms live.
    //
    // The cut is in the middle of the tree, which balances it: two comparator
    // levels on each side. Both stages share one enable so a blocked output
    // freezes everything and no beat is lost or duplicated.
    wire adv = m_axis_tready | ~m_axis_tvalid;

    assign win_ready = adv;

    wire [DW-1:0] a0 = pick(op_q, w0, w1);
    wire [DW-1:0] a1 = pick(op_q, w2, w3);
    wire [DW-1:0] a2 = pick(op_q, w4, w5);
    wire [DW-1:0] a3 = pick(op_q, w6, w7);

    wire [DW-1:0] b0 = pick(op_q, a0, a1);
    wire [DW-1:0] b1 = pick(op_q, a2, a3);

    reg [DW-1:0] b0_q, b1_q, w8_q;
    reg          s1_valid, s1_user, s1_last;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid <= 1'b0;
            s1_user  <= 1'b0;
            s1_last  <= 1'b0;
        end else if (adv) begin
            s1_valid <= win_valid;
            if (win_valid) begin
                b0_q    <= b0;
                b1_q    <= b1;
                w8_q    <= w8;
                s1_user <= win_user;
                s1_last <= win_last;
            end
        end
    end

    wire [DW-1:0] c0  = pick(op_q, b0_q, b1_q);
    wire [DW-1:0] res = pick(op_q, c0,   w8_q);

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DW{1'b0}};
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else if (adv) begin
            m_axis_tvalid <= s1_valid;
            if (s1_valid) begin
                m_axis_tdata <= res;
                m_axis_tuser <= s1_user;
                m_axis_tlast <= s1_last;
            end
        end
    end

endmodule
