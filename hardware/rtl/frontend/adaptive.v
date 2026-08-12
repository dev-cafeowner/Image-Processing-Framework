`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : adaptive
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   AXI4-Stream Video. Adaptive threshold on 8bit grayscale.
//
//       mean = sum(WIN x WIN box) >> SHIFT        WIN = 32, SHIFT = 10
//       out  = (v > mean - C) ? 255 : 0
//
//   The box for output pixel (x,y) covers rows y-16..y+15 and columns
//   x-16..x+15, replicate padded. The padding is ASYMMETRIC - 16 on the top and
//   left, 15 on the bottom and right - because the window is even. This matches
//   model/ref_model.py exactly; see docs/fixed_point_spec.md section 6.
//
//   mean - C can go negative, and the reference model compares in signed
//   arithmetic, so a negative threshold must make every pixel white.
//
//   ** Known limit ** A solid black region whose side reaches WIN inverts: the
//   window falls entirely inside it, the mean goes to 0, and 0 > 0-C is true.
//   Measured: 31 px fine, 32 px centre flips, 64 px interior wiped out. So this
//   stage only makes sense while the widest solid black run stays under WIN.
//
// Why two passes per row instead of one
//   The window reaches 15 rows BELOW the output row, so output row y needs
//   input row y+15. Folding a row into the column sums and sweeping the same
//   sums horizontally at once would need several simultaneous accesses to the
//   same arrays.
//
//   The pixel rate is 9.2 MHz against a 100 MHz clock, about 10x of headroom,
//   so throughput is the cheap thing to spend here. Each row is handled in two
//   sequential passes and every array keeps one read port and one write port:
//
//     PH_IN   W beats,    consumes the stream, folds row r into the column sums
//     PH_OUT  W+16 beats, produces output row y = r-15, no input accepted
//
//   About 630,000 beats per frame, 6.3 ms at 100 MHz against a 33 ms frame
//   period. tready is low for roughly half the time and the source simply waits.
//
// Frame timing
//     rows r = 0 .. 14     PH_IN only, no output yet
//     rows r = 15 .. H-1   PH_IN then PH_OUT (output row r-15)
//     rows r = H .. H+14   flush. No input; the bottom row is replicated
//   Exactly W*H pixels come out. A testbench must drain on the received count,
//   never on a fixed cycle budget.
//
// Storage and the clamping trick
//   line_buf holds the last WIN rows. Row r goes to slot r%WIN, and the slot it
//   overwrites already holds row r-WIN, which is exactly the row leaving the
//   window - so reading it before the write gives the subtrahend for free, the
//   same trick window_gen uses.
//
//   The clamped edges cannot come from that slot, so two dedicated row buffers
//   hold row 0 and row H-1:
//     r <  WIN  -> the row leaving the window is clamped to row 0
//     r >= H    -> the row entering the window is clamped to row H-1
//
//   Horizontally, a WIN deep shift register of column sums replaces random
//   access: the value falling out the far end is exactly the column leaving the
//   window. Columns 0 and W-1 are latched separately for the two clamps.
//
// Pipeline
//   Every array is block RAM, so data arrives one cycle after its address.
//   Stage A drives addresses, stage B consumes the data and does all writes.
//   Stage B therefore writes address xb = x-1 while stage A reads address x,
//   which is why a simple dual port (one read, one write) is enough and why the
//   read never sees its own write.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module adaptive #(
    parameter integer DW    = 8,
    parameter integer MAX_W = 640,
    parameter integer WIN   = 32,      // must be a power of two
    parameter integer SHIFT = 10       // log2(WIN*WIN)
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [11:0]          cfg_width,
    input  wire [11:0]          cfg_height,
    input  wire [7:0]           cfg_c,          // threshold offset C

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

    localparam integer HALF = WIN / 2;          // 16
    localparam integer LAG  = HALF - 1;         // 15, rows the output trails by
    localparam integer CSW  = 14;               // column sum, WIN*255 = 8160
    localparam integer BSW  = 18;               // box sum, WIN*WIN*255 = 261120
    // Line buffer row stride. MUST be a power of two >= MAX_W.
    //
    // With a stride of MAX_W the address is slot*MAX_W + x, a real multiply.
    // Vivado maps it to a DSP48, and a combinational DSP multiply is 4-5 ns:
    // measured WNS -0.875 ns at 125 MHz with only 6 logic levels, the giveaway
    // that the delay was one big block rather than deep logic.
    //
    // A power-of-two stride turns the address into a concatenation - zero
    // logic, zero DSP. The cost is the unused columns between MAX_W and
    // STRIDE: 32*1024*8 bits instead of 32*640*8, about 3 extra BRAM tiles out
    // of 140. Cheap for removing 4 ns from the critical path.
    localparam integer STRIDE = 1024;
    localparam integer SW     = 10;             // log2(STRIDE)
    localparam integer AW     = 5 + SW;         // slot is 5 bits

    localparam [11:0] ONE = 12'd1;

    localparam PH_IN  = 1'b0;
    localparam PH_OUT = 1'b1;

    // ==================================================== stage A : addresses
    reg        phase;
    reg [11:0] r;                   // source row folded into the sums
    reg [11:0] x;

    // Geometry is latched, and so are the comparison constants derived from it.
    // Taken straight from the ports these sit at the head of a 9 deep carry
    // chain that ends at the output register: measured WNS -0.890 ns with the
    // critical path starting at cfg_width. Latching costs 6 registers and moves
    // the whole frame geometry off the datapath.
    //
    // Loaded on reset and at each frame start, which is the boundary the
    // control register contract already specifies for configuration changes.
    reg [11:0] W, H;
    reg [11:0] W_m1;                // W-1,          last input column
    reg [11:0] W_hi;                // W+HALF-1,     last output beat
    reg [11:0] W_end;               // W+HALF,       last sweep beat
    reg [11:0] H_m1;                // H-1,          last input row
    reg [11:0] H_end;               // H+LAG-1,      last flush row

    wire frame_top = (phase == PH_IN) && (r == 12'd0) && (x == 12'd0);

    wire        no_input = (r >= H);
    wire        has_out  = (r >= LAG);
    wire [11:0] y        = r - LAG;
    wire        last_row = (r == H_end);

    wire out_free = m_axis_tready | ~m_axis_tvalid;
    wire ce = out_free & ((phase == PH_IN) ? (no_input | s_axis_tvalid) : 1'b1);

    assign s_axis_tready = out_free & (phase == PH_IN) & ~no_input;

    always @(posedge aclk) begin
        if (!aresetn || (ce && frame_top)) begin
            W     <= cfg_width;
            H     <= cfg_height;
            W_m1  <= cfg_width  - 12'd1;
            W_hi  <= cfg_width  + HALF[11:0] - 12'd1;
            W_end <= cfg_width  + HALF[11:0];
            H_m1  <= cfg_height - 12'd1;
            H_end <= cfg_height + LAG[11:0]  - 12'd1;
        end
    end

    // Read addresses. In PH_OUT the sweep runs past W-1 to flush the horizontal
    // window, so every address is clamped into range.
    wire [11:0] out_xa   = (x < HALF) ? 12'd0 : (x - HALF);
    wire [11:0] col_a    = (x > W_m1) ? W_m1 : x;
    wire [11:0] lb_xa    = (phase == PH_IN) ? x
                         : ((out_xa > W_m1) ? W_m1 : out_xa);
    wire [4:0]  slot_a   = (phase == PH_IN) ? r[4:0] : y[4:0];
    wire [AW-1:0] lb_ra  = {slot_a, lb_xa[SW-1:0]};

    // ==================================================== stage B : data
    reg        phb;
    reg [11:0] rb, xb;
    reg [DW-1:0] sdata_b;
    reg        vld_b;

    wire        no_input_b = (rb >= H);
    wire        has_out_b  = (rb >= LAG);
    wire [11:0] yb         = rb - LAG;
    wire [11:0] out_xb     = xb - HALF;

    // ------------------------------------------------------------- memories
    reg [DW-1:0]  line_buf [0:WIN*STRIDE-1];
    reg [DW-1:0]  row_first[0:MAX_W-1];
    reg [DW-1:0]  row_last [0:MAX_W-1];
    reg [CSW-1:0] col_sum  [0:MAX_W-1];

    reg [DW-1:0]  lb_rd, rf_rd, rl_rd;
    reg [CSW-1:0] cs_rd;

    // ------------------------------------------------- pass 1 : column sums
    wire [DW-1:0] p_in  = no_input_b ? rl_rd : sdata_b;
    wire [DW-1:0] p_sub = (rb < WIN) ? rf_rd : lb_rd;

    wire [CSW-1:0] cs_next = (rb == 12'd0) ? (p_in << 5)          // 32 x row 0
                                           : (cs_rd + p_in - p_sub);

    wire [AW-1:0] lb_wa = {rb[4:0], xb[SW-1:0]};

    // -------------------------------------------- pass 2 : horizontal sweep
    reg [CSW-1:0] csr [0:WIN-1];
    reg [CSW-1:0] cs_first, cs_last;
    reg [BSW-1:0] box;

    wire [CSW-1:0] cs_enter = (xb > W_m1) ? cs_last  : cs_rd;
    wire [CSW-1:0] cs_leave = (xb < WIN)     ? cs_first : csr[WIN-1];

    wire [BSW-1:0] box_next = (xb == 12'd0)
                            ? ((cs_rd << 4) + cs_rd)              // 17 x col 0
                            : (xb < HALF)
                              ? (box + cs_rd)                     // still filling
                              : (box + cs_enter - cs_leave);

    // The output reads the REGISTERED box, not box_next. Standalone this module
    // met timing at +0.428 ns, but integrated into vision_frontend_core the
    // same path fell to -0.268 ns: the box adder, the shift, the C subtraction
    // and the compare all sat between a block RAM output and the output
    // register, and integration ate the thin margin.
    //
    // Using box splits that in two - block RAM -> mux -> adder -> register, and
    // register -> mean -> subtract -> compare -> register - at the cost of the
    // output lagging one more beat. Hence out_xb = xb - HALF rather than
    // xb - HALF + 1, and the line buffer address follows the same shift.
    wire [DW-1:0] mean   = box[SHIFT + DW - 1 : SHIFT];
    wire [8:0]    thr_lo = {1'b0, mean} - {1'b0, cfg_c};          // may go negative
    wire [DW-1:0] bin    = (thr_lo[8] || (lb_rd > thr_lo[7:0])) ? 8'hFF : 8'h00;

    // xb = HALF .. W+HALF-1 is exactly W outputs. The upper end is where stage A
    // has already moved on to the next PH_IN and stage B is draining the tail.
    wire out_vld = vld_b && (phb == PH_OUT) && has_out_b
                   && (xb >= HALF) && (xb <= W_hi);

    integer i;

    // ------------------------------------------------------- memory reads
    always @(posedge aclk) begin
        if (ce) begin
            lb_rd <= line_buf[lb_ra];
            rf_rd <= row_first[col_a];
            rl_rd <= row_last[col_a];
            cs_rd <= col_sum[col_a];
        end
    end

    // ------------------------------------------------------- stage A control
    always @(posedge aclk) begin
        if (!aresetn) begin
            phase <= PH_IN;
            r     <= 12'd0;
            x     <= 12'd0;
        end else if (ce) begin
            if (phase == PH_IN) begin
                if (x == W_m1) begin
                    x     <= 12'd0;
                    phase <= has_out ? PH_OUT : PH_IN;
                    if (!has_out) r <= r + ONE;
                end else begin
                    x <= x + ONE;
                end
            end else begin
                if (x == W_end) begin                // W+16, one extra to drain
                    x     <= 12'd0;
                    phase <= PH_IN;
                    r     <= last_row ? 12'd0 : (r + ONE);
                end else begin
                    x <= x + ONE;
                end
            end
        end
    end

    // ------------------------------------------------------- stage A -> B
    always @(posedge aclk) begin
        if (!aresetn) begin
            vld_b <= 1'b0;
        end else if (ce) begin
            phb     <= phase;
            rb      <= r;
            xb      <= x;
            sdata_b <= s_axis_tdata;
            vld_b   <= 1'b1;
        end
    end

    // ------------------------------------------------------- stage B writes
    always @(posedge aclk) begin
        if (ce && vld_b) begin
            if (phb == PH_IN) begin
                if (!no_input_b)   line_buf[lb_wa] <= p_in;
                if (rb == 12'd0)   row_first[xb]   <= p_in;
                if (rb == H_m1)    row_last[xb]    <= p_in;
                col_sum[xb] <= cs_next;
                if (xb == 12'd0)   cs_first <= cs_next;
                if (xb == W_m1)    cs_last  <= cs_next;
            end else begin
                box <= box_next;
                for (i = WIN-1; i > 0; i = i - 1) csr[i] <= csr[i-1];
                csr[0] <= cs_enter;
            end
        end
    end

    // ------------------------------------------------------- output register
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
            m_axis_tdata  <= {DW{1'b0}};
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else if (ce) begin
            m_axis_tvalid <= out_vld;
            if (out_vld) begin
                m_axis_tdata <= bin;
                m_axis_tuser <= (out_xb == 12'd0) && (yb == 12'd0);
                m_axis_tlast <= (out_xb == W_m1);
            end
        end else if (m_axis_tready) begin
            m_axis_tvalid <= 1'b0;
        end
    end

endmodule
