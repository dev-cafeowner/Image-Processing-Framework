`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : axis_fifo
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   Elastic buffer between the camera receiver and vision_frontend_core.
//
//   The camera cannot be stalled. It has no tready input and no way to be told
//   to wait, so any beat the chain refuses is a pixel lost somewhere upstream
//   with no way to recover it. The chain DOES refuse beats, and not rarely:
//
//     measured, tb_fe_p1qr, 640x480, P1 QR
//       longest continuous input stall = 657 clocks
//
//   That is adaptive and nothing else. Its PH_OUT phase runs W+16 beats
//   producing an output row and accepts no input at all during them:
//
//     assign s_axis_tready = out_free & (phase == PH_IN) & ~no_input;
//
//   657 = W + 16 + 1 at W=640, so the number is structural rather than a
//   measurement artifact and it scales with the frame width.
//
// Sizing
//   depth >= stall_clocks * f_pixel / f_clk
//
//   657 clocks at 125 MHz is 5.26 us. An OV7670 in VGA RGB565 puts out one
//   pixel per two PCLK, so with a 24 MHz PCLK the peak pixel rate inside an
//   active line is 12 MHz:
//
//     5.26 us * 12 MHz = 63 pixels
//
//   DEPTH 128 is that with 2x of headroom. The buffer empties completely
//   between stalls - the core drains at one pixel per clock, roughly ten times
//   the camera rate - so only ONE stall has to fit, not a whole row.
//
//   Widen the frame and the requirement grows with it: PH_OUT is W+16.
//
// fifo_full - read the name carefully
//   Sticky, set when a beat is offered while the buffer is full. What that
//   MEANS depends on who is upstream, and the buffer cannot tell:
//
//     camera receiver, ignores tready   the beat is gone. A pixel was lost.
//     compliant source, honours tready  ordinary backpressure. Nothing lost.
//
//   In this system the upstream is a camera, so a set flag is a lost pixel and
//   DEPTH was too small. In simulation the source does honour tready, so the
//   flag fires during any backpressure test and is informational there - the
//   thing that proves nothing was dropped is the bit-exact data comparison.
//
//   It is deliberately not called overflow. That would claim a loss the buffer
//   is not in a position to observe.
//
// fifo_max_level
//   High-water mark. DEPTH is calculated from a simulation of one preset; this
//   is how the number gets confirmed against a real camera and a real lens.
//   Read it after a few seconds of live video and compare against DEPTH.
//   The extraction side sizes its Event FIFO the same way.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module axis_fifo #(
    parameter integer DW    = 16,      // RGB565 at the camera side
    parameter integer DEPTH = 128      // must be a power of two
)(
    input  wire                 aclk,
    input  wire                 aresetn,
    input  wire                 stat_clear,     // 1 cycle, clears fifo_full and the peak

    // ---- Slave : from the camera receiver ----------------------------------
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // ---- Master : to vision_frontend_core ----------------------------------
    output wire [DW-1:0]        m_axis_tdata,
    output wire                 m_axis_tvalid,
    input  wire                 m_axis_tready,
    output wire                 m_axis_tuser,
    output wire                 m_axis_tlast,

    // ---- status ------------------------------------------------------------
    output reg                  fifo_full,       // sticky, see header
    output wire [15:0]          fifo_max_level   // high-water mark
);

    function integer clog2;
        input integer v;
        integer i;
        begin
            clog2 = 0;
            for (i = v - 1; i > 0; i = i >> 1) clog2 = clog2 + 1;
        end
    endfunction

    localparam integer AW = clog2(DEPTH);
    localparam integer PW = DW + 2;             // tdata + tuser + tlast

    // Distributed RAM. At DEPTH 128 x 18 bits this is a few dozen LUTs, far
    // cheaper than a BRAM tile - and BRAM is the scarce resource here, with
    // adaptive already holding 9.5 tiles.
    reg [PW-1:0] mem [0:DEPTH-1];

    reg  [AW:0]  wptr, rptr;

    // level is a counter, not wptr - rptr.
    //
    // Deriving it by subtraction put the subtractor, the +wr-rd adjust and the
    // peak comparator all on one combinational path out of rptr, and adding
    // the stat_clear mux on the peak register pushed it over: measured
    // -0.053 ns at 125 MHz, 10 logic levels with 5 CARRY4. Counting instead
    // costs AW+1 flops and removes the subtractor from that path entirely.
    reg  [AW:0]  level;

    // The extra bit is what separates full from empty: DEPTH itself needs one
    // more bit than any index into the memory.
    wire full  = (level == DEPTH[AW:0]);
    wire empty = (level == {(AW+1){1'b0}});

    assign s_axis_tready = ~full;
    assign m_axis_tvalid = ~empty;

    wire wr = s_axis_tvalid & s_axis_tready;
    wire rd = m_axis_tvalid & m_axis_tready;

    // First word fall through: an asynchronous read means a beat written into
    // an empty buffer is visible on the same cycle, so the buffer adds no
    // latency when it is not actually holding anything back.
    wire [PW-1:0] rdata = mem[rptr[AW-1:0]];
    assign m_axis_tdata = rdata[DW-1:0];
    assign m_axis_tlast = rdata[DW];
    assign m_axis_tuser = rdata[DW+1];

    wire [AW:0] level_next = level + {{AW{1'b0}}, wr} - {{AW{1'b0}}, rd};

    // The peak is kept at the buffer's own width and zero-extended on the way
    // out. Comparing an AW+1 bit level against a 16 bit register built a
    // comparator whose top half could never be anything but zero.
    reg [AW:0] peak;
    assign fifo_max_level = {{(16-AW-1){1'b0}}, peak};

    always @(posedge aclk) begin
        if (wr) mem[wptr[AW-1:0]] <= {s_axis_tuser, s_axis_tlast, s_axis_tdata};
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            wptr      <= {(AW+1){1'b0}};
            rptr      <= {(AW+1){1'b0}};
            level     <= {(AW+1){1'b0}};
            peak      <= {(AW+1){1'b0}};
            fifo_full <= 1'b0;
        end else begin
            if (wr) wptr <= wptr + {{AW{1'b0}}, 1'b1};
            if (rd) rptr <= rptr + {{AW{1'b0}}, 1'b1};
            level <= level_next;

            // Cleared first so an event on the same cycle still wins.
            //
            // fifo_max_level IS cleared, unlike the frame counters in
            // binary_frame_writer. It is a peak, not a count: the difference
            // between two peaks means nothing, so without a reset the value
            // is a lifetime maximum and says nothing about the last second.
            // Clearing is the only way to observe an interval.
            if (stat_clear) begin
                fifo_full <= 1'b0;
                peak      <= {(AW+1){1'b0}};
            end

            // Offered while full. With a camera upstream this beat is
            // already gone; with a compliant source it is just waiting.
            if (s_axis_tvalid & full) fifo_full <= 1'b1;

            if (level_next > peak) peak <= level_next;
        end
    end

    // ------------------------------------------------------- elaboration check
    // synthesis translate_off
    initial begin
        if (DEPTH != (1 << AW))
            $fatal(1, "[FIFO] DEPTH %0d is not a power of two", DEPTH);
    end
    // synthesis translate_on

endmodule
