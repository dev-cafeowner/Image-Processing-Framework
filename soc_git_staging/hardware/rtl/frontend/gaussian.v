`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : gaussian
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. 3x3 Gaussian blur on 8bit grayscale.
//
//       [1 2 1]
//   K = [2 4 2] / 16        out = acc >> 4, truncating
//       [1 2 1]
//
//   Neighbourhood generation, replicate borders and the handshake all live in
//   window_gen. This module is only the arithmetic.
//
//   The kernel is separable, so it is applied as [1 2 1] across then [1 2 1]
//   down: 6 adds and 4 shifts instead of 9 multiply-accumulates. The integer
//   result is identical because there is no intermediate rounding - the single
//   >>4 happens at the end, exactly as in model/ref_model.py.
//
//     row sum   max 255*4  = 1020
//     acc       max 1020*4 = 4080   fits in 12 bits
//     acc >> 4  max        =  255   the coefficients sum to 16
//
//   No multipliers and no DSP: every coefficient is a power of two.
//
//   Impulse response exposes the coefficients directly. A lone 255 gives
//   63 at the centre, 31 orthogonally and 15 diagonally. A 255 in the corner
//   gives 143 under replicate padding and 63 under zero padding, which is what
//   the impulse and border patterns check.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module gaussian #(
    parameter integer DW    = 8,
    parameter integer MAX_W = 640
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [11:0]          cfg_width,
    input  wire [11:0]          cfg_height,

    // Slave : Gray8
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // Master : Gray8, blurred
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

    wire [DW-1:0] w00 = win[0*DW +: DW];
    wire [DW-1:0] w01 = win[1*DW +: DW];
    wire [DW-1:0] w02 = win[2*DW +: DW];
    wire [DW-1:0] w10 = win[3*DW +: DW];
    wire [DW-1:0] w11 = win[4*DW +: DW];
    wire [DW-1:0] w12 = win[5*DW +: DW];
    wire [DW-1:0] w20 = win[6*DW +: DW];
    wire [DW-1:0] w21 = win[7*DW +: DW];
    wire [DW-1:0] w22 = win[8*DW +: DW];

    // ----------------------------------------------------- separable kernel
    // The LHS width sets the context for the whole expression, so the shifts
    // and adds are evaluated at 11 and 12 bits. Declaring these narrower would
    // silently truncate, the same trap as the multiplies in grayscale.v.
    wire [10:0] h0 = w00 + (w01 << 1) + w02;      // max 1020
    wire [10:0] h1 = w10 + (w11 << 1) + w12;
    wire [10:0] h2 = w20 + (w21 << 1) + w22;

    wire [11:0] acc   = h0 + (h1 << 1) + h2;      // max 4080
    wire [7:0]  gauss = acc[11:4];                // >> 4, truncating

    // --------------------------------------------------------- handshake
    // Same single register stage as grayscale.v.
    assign win_ready = m_axis_tready | ~m_axis_tvalid;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DW{1'b0}};
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else if (win_ready) begin
            m_axis_tvalid <= win_valid;
            if (win_valid) begin
                m_axis_tdata <= gauss;
                m_axis_tuser <= win_user;
                m_axis_tlast <= win_last;
            end
        end
    end

endmodule
