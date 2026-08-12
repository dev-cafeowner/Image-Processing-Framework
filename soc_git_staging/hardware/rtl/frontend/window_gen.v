`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : window_gen
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. Turns a raster pixel stream into a 3x3 neighbourhood
//   window stream. Every 3x3 kernel module (gaussian, sobel, erode, dilate)
//   instantiates this and adds only its arithmetic.
//
//   Borders use REPLICATE, matching docs/fixed_point_spec.md section 1.
//
// Why the output lags the input
//   Output pixel (x,y) needs input rows y-1, y and y+1. Row y+1 has not been
//   received while row y is streaming in, so the output trails the input by
//   about one line. The last output row is the exception: its "row below" is
//   replicated, so it needs no further input and is emitted after the input
//   ends. That tail is the flush phase below.
//
//   Frame timing, in accepted beats:
//     rows 0 .. H-1   consume input, s_axis_tready high
//     row  H          flush. tready low, bottom row replicated
//     row  H+1        drain. pushes the last windows out of the pipeline
//   So a frame occupies W*(H+2) beats and emits exactly W*H windows.
//   A testbench must NOT stop a fixed few cycles after the input ends.
//
// Storage
//   Two line buffers hold rows y-1 and y-2. They are read-first, so the buffer
//   being overwritten with row y still returns row y-2 on the same address in
//   the same cycle. That is what lets two buffers cover a 3-row window.
//   Buffer roles alternate on ya[0].
//
// Blanking and backpressure
//   The whole datapath shares one clock enable, ce. It advances only when a
//   beat is actually available and the output register can take a result, so
//   idle input cycles (camera blanking) and downstream stalls freeze the
//   pipeline rather than corrupting it. Line buffer enables are gated by ce
//   too, so addresses and read data hold across a stall.
//
// Window packing, row major, LSB first
//   [0]=(-1,-1) [1]=(0,-1) [2]=(+1,-1)
//   [3]=(-1, 0) [4]=(0, 0) [5]=(+1, 0)     <- [4] is the centre pixel
//   [6]=(-1,+1) [7]=(0,+1) [8]=(+1,+1)
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module window_gen #(
    parameter integer DW    = 8,
    parameter integer MAX_W = 640          // line buffer depth. cfg_width <= MAX_W
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // Frame geometry. Must be stable while a frame is in flight; the raster
    // position is derived from these, not from tlast. 640x480 is fixed by
    // docs/frontend_axis_spec.md section 2, but keeping them as ports lets the
    // small vectors (64x48) run without recompiling.
    input  wire [11:0]          cfg_width,
    input  wire [11:0]          cfg_height,

    // Slave : pixel raster
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // Master : 3x3 window
    output reg  [9*DW-1:0]      m_win_tdata,
    output reg                  m_win_tvalid,
    input  wire                 m_win_tready,
    output reg                  m_win_tuser,
    output reg                  m_win_tlast
);

    localparam [11:0] ONE = 12'd1;

    // ------------------------------------------------------------- control
    // ya counts 0..H+1. Rows H and H+1 take no input (see header).
    reg  [11:0] xa, ya;

    // Geometry is registered, and in_phase is a flag maintained at row
    // boundaries instead of a live (ya < H) compare. Taken straight from the
    // ports, cfg_height sat at the head of s_axis_tready and of every ce in
    // this module: the integrated core measured WNS -0.023 ns with the
    // critical path cfg_height -> s_axis_tready. This is the third recurrence
    // of the same trap (adaptive geometry, morph_op cfg_op), so it is a rule
    // now: configuration never touches a handshake or datapath combinationally.
    //
    // Reloaded at the frame origin and on SOF resync - the same boundary the
    // control register contract specifies for configuration changes.
    reg [11:0] W, H;
    reg [11:0] W_m1;                // W-1, last column
    reg [11:0] H_p1;                // H+1, last drain row
    reg        in_phase;            // ya < H, i.e. this row consumes input

    wire can_adv  = m_win_tready | ~m_win_tvalid;

    // tready deliberately does not depend on tvalid, matching grayscale.v.
    assign s_axis_tready = can_adv & in_phase;

    wire ce = can_adv & (in_phase ? s_axis_tvalid : 1'b1);

    wire sof     = in_phase & s_axis_tuser;
    wire row_end = (xa == W_m1);

    always @(posedge aclk) begin
        if (!aresetn || (ce && (((xa == 12'd0) && (ya == 12'd0)) || sof))) begin
            W    <= cfg_width;
            H    <= cfg_height;
            W_m1 <= cfg_width  - 12'd1;
            H_p1 <= cfg_height + 12'd1;
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            xa       <= 12'd0;
            ya       <= 12'd0;
            in_phase <= 1'b1;               // row 0 always consumes input
        end else if (ce) begin
            if (sof) begin
                // SOF resynchronises the raster position. Without this a single
                // dropped beat would skew every later frame silently.
                xa       <= ONE;
                ya       <= 12'd0;
                in_phase <= 1'b1;
            end else if (row_end) begin
                xa <= 12'd0;
                if (ya == H_p1) begin
                    ya       <= 12'd0;
                    in_phase <= 1'b1;
                end else begin
                    ya       <= ya + ONE;
                    // Lands in a register: the compare is off the tready path.
                    in_phase <= ((ya + ONE) < H);
                end
            end else begin
                xa <= xa + ONE;
            end
        end
    end

    // --------------------------------------------------------- line buffers
    // Read-first: the read returns the old contents even when the same address
    // is written in the same cycle. Vivado infers block RAM from this template.
    reg [DW-1:0] lb0 [0:MAX_W-1];
    reg [DW-1:0] lb1 [0:MAX_W-1];
    reg [DW-1:0] rd0, rd1;

    wire wr = ce & in_phase;               // flush rows store nothing

    always @(posedge aclk) begin
        if (ce) begin
            if (wr && !ya[0]) lb0[xa] <= s_axis_tdata;
            rd0 <= lb0[xa];
            if (wr &&  ya[0]) lb1[xa] <= s_axis_tdata;
            rd1 <= lb1[xa];
        end
    end

    // ------------------------------------------------------- stage B : column
    // Line buffer data lands one ce after its address, so the position must be
    // delayed to match.
    reg [11:0]   xb, yb;
    reg [DW-1:0] p0_b;

    always @(posedge aclk) if (ce) begin
        xb   <= xa;
        yb   <= ya;
        p0_b <= s_axis_tdata;
    end

    // Row yb went into lb[yb[0]], so that same buffer returned row yb-2 and the
    // other one holds row yb-1.
    wire [DW-1:0] row_m2 = yb[0] ? rd1 : rd0;      // row yb-2
    wire [DW-1:0] row_m1 = yb[0] ? rd0 : rd1;      // row yb-1

    // { bottom, middle, top }. No border fixing here on purpose: every
    // replicate decision lives in one place, the stage D muxes below. During
    // the flush rows p0_b is stale, and the vertical mux discards it.
    wire [3*DW-1:0] col_new = { p0_b, row_m1, row_m2 };

    reg [3*DW-1:0] col_n, col_m, col_o;            // newest, centre, oldest

    always @(posedge aclk) if (ce) begin
        col_n <= col_new;
        col_m <= col_n;
        col_o <= col_m;
    end

    // ------------------------------------------- stage D : position of centre
    // col_m holds the column pushed three ce ago, so the position pipeline is
    // three deep. xd/yd address the centre column of the window built below.
    reg [11:0] xc, yc, xd, yd;

    always @(posedge aclk) if (ce) begin
        xc <= xb;  yc <= yb;
        xd <= xc;  yd <= yc;
    end

    // --------------------------------------------------- replicate + assemble
    // Horizontal first: at the left/right edge the neighbour column is replaced
    // by the centre column. That also discards the wrap-around column that the
    // shift register picks up across a row boundary, since it belongs to the
    // adjacent row.
    wire at_left  = (xd == 12'd0);
    wire at_right = (xd == W_m1);

    wire [3*DW-1:0] sel_l = at_left  ? col_m : col_o;
    wire [3*DW-1:0] sel_c =                    col_m;
    wire [3*DW-1:0] sel_r = at_right ? col_m : col_n;

    // Vertical second. Output row is yd-1, so yd==1 is the top image row and
    // yd==H is the bottom one.
    wire top_rep = (yd == ONE);
    wire bot_rep = (yd == H);

    wire [DW-1:0] l_t = top_rep ? sel_l[1*DW +: DW] : sel_l[0*DW +: DW];
    wire [DW-1:0] l_m =           sel_l[1*DW +: DW];
    wire [DW-1:0] l_b = bot_rep ? sel_l[1*DW +: DW] : sel_l[2*DW +: DW];

    wire [DW-1:0] c_t = top_rep ? sel_c[1*DW +: DW] : sel_c[0*DW +: DW];
    wire [DW-1:0] c_m =           sel_c[1*DW +: DW];
    wire [DW-1:0] c_b = bot_rep ? sel_c[1*DW +: DW] : sel_c[2*DW +: DW];

    wire [DW-1:0] r_t = top_rep ? sel_r[1*DW +: DW] : sel_r[0*DW +: DW];
    wire [DW-1:0] r_m =           sel_r[1*DW +: DW];
    wire [DW-1:0] r_b = bot_rep ? sel_r[1*DW +: DW] : sel_r[2*DW +: DW];

    wire [9*DW-1:0] win = { r_b, c_b, l_b,
                            r_m, c_m, l_m,
                            r_t, c_t, l_t };

    // yd sweeps 0..H+1. Only rows 1..H map onto a real image row, which is
    // exactly W*H windows per frame.
    wire out_vld = (yd >= ONE) && (yd <= H);

    // ------------------------------------------------------------- output reg
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_win_tvalid <= 1'b0;
            m_win_tdata  <= {(9*DW){1'b0}};
            m_win_tuser  <= 1'b0;
            m_win_tlast  <= 1'b0;
        end else if (ce) begin
            m_win_tvalid <= out_vld;
            m_win_tdata  <= win;
            m_win_tuser  <= out_vld && at_left && (yd == ONE);
            m_win_tlast  <= out_vld && at_right;
        end else if (m_win_tready) begin
            // A beat left while the pipeline is stalled for want of input.
            // Without this the same window would be presented twice.
            m_win_tvalid <= 1'b0;
        end
    end

    // ------------------------------------------------------- simulation check
    // cfg_width disagreeing with the actual EOL spacing would corrupt every
    // border decision while still producing plausible-looking output. Catch it
    // at the source instead.
    // synthesis translate_off
    always @(posedge aclk) begin
        if (aresetn && ce && in_phase && s_axis_tvalid) begin
            if (s_axis_tlast && (xa != W_m1))
                $display("[WINGEN][ERR] tlast at column %0d but cfg_width says %0d",
                         xa, W);
            if (!s_axis_tlast && (xa == W_m1))
                $display("[WINGEN][ERR] no tlast at column %0d (cfg_width %0d)",
                         xa, W);
        end
    end
    // synthesis translate_on

endmodule
