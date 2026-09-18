`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : sobel
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. 3x3 Sobel edge magnitude on 8bit grayscale.
//
//        [-1 0 1]          [-1 -2 -1]
//   Gx = [-2 0 2]     Gy = [ 0  0  0]     out = min(|Gx| + |Gy|, 255)
//        [-1 0 1]          [ 1  2  1]
//
//   Neighbourhood generation, replicate borders and the handshake all live in
//   window_gen. This module is only the arithmetic, same as gaussian.v.
//
//   |Gx| + |Gy| instead of sqrt(Gx^2 + Gy^2)
//     Overestimates by at most about 12 percent, which edge detection does not
//     care about, and costs no square root and no multipliers.
//
//   Saturation is mandatory
//     Gx and Gy each span -1020..+1020, so |Gx| + |Gy| reaches 2040. That does
//     not fit in the 8 bit output. Truncating instead of saturating would wrap
//     a strong edge round to a small value, turning the brightest edges in the
//     image into dark ones. min(mag, 255) is the contract in
//     docs/fixed_point_spec.md section 5.
//
//   No signed arithmetic
//     Both kernels are separable into [1 2 1] along one axis and [-1 0 1] along
//     the other, so each gradient is the difference of two sums that are
//     themselves non-negative:
//
//       Gx = (right column) - (left column)     each weighted [1 2 1] vertically
//       Gy = (bottom row)   - (top row)         each weighted [1 2 1] horizontally
//
//     Taking the absolute value is then just "subtract the smaller from the
//     larger". Everything stays unsigned, which removes the sign extension
//     width traps entirely. The integer result is identical to the signed
//     9-term form in model/ref_model.py because no rounding happens anywhere.
//
//     column / row sum   max 255*4 = 1020
//     |Gx| + |Gy|        max       = 2040   fits in 12 bits
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module sobel #(
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

    // Master : Gray8, edge magnitude
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
    wire [DW-1:0] w12 = win[5*DW +: DW];
    wire [DW-1:0] w20 = win[6*DW +: DW];
    wire [DW-1:0] w21 = win[7*DW +: DW];
    wire [DW-1:0] w22 = win[8*DW +: DW];
    // w11, the centre pixel, has weight 0 in both kernels.

    // ------------------------------------------------------ separable sums
    // The LHS width sets the context for the whole expression, so the shifts
    // and adds are evaluated at 11 bits. Declaring these narrower would
    // silently truncate, the same trap as the multiplies in grayscale.v.
    wire [10:0] col_l = w00 + (w10 << 1) + w20;      // max 1020
    wire [10:0] col_r = w02 + (w12 << 1) + w22;
    wire [10:0] row_t = w00 + (w01 << 1) + w02;
    wire [10:0] row_b = w20 + (w21 << 1) + w22;

    // ------------------------------------------------- pipeline stage 1 / 2
    // Two register stages, not one. Doing sums, absolute values, the final add
    // and the saturation in a single cycle misses 100 MHz: measured -0.001 ns
    // WNS with 12 logic levels and 6 carry chains, 9.748 ns of a 10 ns period.
    // gaussian.v gets away with one stage because it is only an adder tree;
    // sobel adds a compare and a conditional subtract on top of that.
    //
    // The split is at the separable boundary: stage 1 finishes the [1 2 1]
    // pass, stage 2 takes the differences and saturates. That is not an even
    // split - stage 2 still carries 6 chains and 8.046 ns, because two
    // comparisons and two conditional subtracts sit there. It is enough:
    // WNS goes from -0.001 ns to +1.665 ns for 41 extra flip-flops.
    // If a later change eats that margin, the next cut goes inside the
    // absolute value, registering the comparison alongside the subtraction.
    //
    // Both stages share one enable, so a blocked output freezes the whole
    // pipeline and no beat is lost or duplicated. Latency grows by one cycle,
    // which nothing depends on - window_gen already dominates it and the
    // testbench drains on the received pixel count.
    wire adv = m_axis_tready | ~m_axis_tvalid;

    assign win_ready = adv;

    reg [10:0] col_l_q, col_r_q, row_t_q, row_b_q;
    reg        s1_valid, s1_user, s1_last;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid <= 1'b0;
            s1_user  <= 1'b0;
            s1_last  <= 1'b0;
        end else if (adv) begin
            s1_valid <= win_valid;
            if (win_valid) begin
                col_l_q <= col_l;
                col_r_q <= col_r;
                row_t_q <= row_t;
                row_b_q <= row_b;
                s1_user <= win_user;
                s1_last <= win_last;
            end
        end
    end

    // Absolute value without signed arithmetic: subtract the smaller from the
    // larger. Both operands are unsigned and the result cannot borrow.
    wire [10:0] abs_gx = (col_r_q >= col_l_q) ? (col_r_q - col_l_q)
                                              : (col_l_q - col_r_q);
    wire [10:0] abs_gy = (row_b_q >= row_t_q) ? (row_b_q - row_t_q)
                                              : (row_t_q - row_b_q);

    wire [11:0] mag = abs_gx + abs_gy;               // max 2040

    // Saturate. Any bit above bit 7 means the value exceeded 255.
    wire [DW-1:0] edge_mag = (|mag[11:8]) ? 8'd255 : mag[7:0];

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DW{1'b0}};
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else if (adv) begin
            m_axis_tvalid <= s1_valid;
            if (s1_valid) begin
                m_axis_tdata <= edge_mag;
                m_axis_tuser <= s1_user;
                m_axis_tlast <= s1_last;
            end
        end
    end

endmodule
