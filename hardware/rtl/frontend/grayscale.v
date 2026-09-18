`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : grayscale
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. Converts RGB565 (16bit) input to 8bit grayscale.
//
//   RGB565 -> RGB888 replicates the high bits into the low bits:
//     r8 = {r5, r5[4:2]}
//   A plain left shift (<<3) tops out at 248, so pure white never appears.
//
//   Gray = (77*R + 150*G + 29*B) >> 8
//     The coefficients sum to exactly 256, so an all-255 input yields exactly 255.
//     Max accumulator value is 255*256 = 65280, which fits in 16 bits.
//     These are constant multiplies, so synthesis reduces them to shift-add.
//
//   Two register stages, split after the multiplies. tuser (SOF) and tlast
//   (EOL) pass through unchanged.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module grayscale #(
    parameter integer DW_IN  = 16,
    parameter integer DW_OUT = 8
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // Slave : RGB565
    input  wire [DW_IN-1:0]     s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // Master : Gray8
    output reg  [DW_OUT-1:0]    m_axis_tdata,
    output reg                  m_axis_tvalid,
    input  wire                 m_axis_tready,
    output reg                  m_axis_tuser,
    output reg                  m_axis_tlast
);

    localparam [7:0] COEF_R = 8'd77;
    localparam [7:0] COEF_G = 8'd150;
    localparam [7:0] COEF_B = 8'd29;

    // ------------------------------------------------------- channel split
    wire [4:0] r5 = s_axis_tdata[15:11];
    wire [5:0] g6 = s_axis_tdata[10:5];
    wire [4:0] b5 = s_axis_tdata[4:0];

    // expand to 8 bit by replicating the high bits
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    // ------------------------------------------------------- weighted sum
    // The LHS is 16 bit, so the operands are context-extended to 16 bit before
    // the multiply. Declaring these as 8 bit would silently truncate.
    wire [15:0] mul_r = r8 * COEF_R;    // max 19635
    wire [15:0] mul_g = g8 * COEF_G;    // max 38250
    wire [15:0] mul_b = b8 * COEF_B;    // max  7395

    // ------------------------------------------------- pipeline stage 1 / 2
    // Two register stages, not one. At 100 MHz a single stage was fine, but at
    // 125 MHz the port-to-register path (unpack, three constant multiplies,
    // three-input add, shift) measured WNS -0.005 ns - failing by 5 ps with 12
    // logic levels. This was the last single-stage module in the chain.
    //
    // The cut is after the multiplies. They expand to shift-add trees and are
    // the deep part; the final sum and the >>8 are cheap.
    //
    // Both stages share one enable, so a blocked output freezes the pipeline
    // and no beat is lost or duplicated.
    wire adv = m_axis_tready | ~m_axis_tvalid;

    assign s_axis_tready = adv;

    reg [15:0] mr_q, mg_q, mb_q;
    reg        s1_valid, s1_user, s1_last;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s1_valid <= 1'b0;
            s1_user  <= 1'b0;
            s1_last  <= 1'b0;
        end else if (adv) begin
            s1_valid <= s_axis_tvalid;
            if (s_axis_tvalid) begin
                mr_q    <= mul_r;
                mg_q    <= mul_g;
                mb_q    <= mul_b;
                s1_user <= s_axis_tuser;
                s1_last <= s_axis_tlast;
            end
        end
    end

    wire [15:0] acc  = mr_q + mg_q + mb_q;      // max 65280
    wire [7:0]  gray = acc[15:8];               // >> 8, truncating

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DW_OUT{1'b0}};
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else if (adv) begin
            m_axis_tvalid <= s1_valid;
            if (s1_valid) begin
                m_axis_tdata <= gray;
                m_axis_tuser <= s1_user;
                m_axis_tlast <= s1_last;
            end
        end
    end

endmodule
