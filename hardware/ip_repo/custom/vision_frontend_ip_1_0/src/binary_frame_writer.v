`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : binary_frame_writer
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   The handoff point. Packs the 8bit binary stream into 32 pixel words and
//   writes them to the Binary Frame Buffer, which the feature extraction side
//   reads through the other BRAM port.
//
//   Format is fixed by docs/extractor_handoff_spec.md section 3:
//     640x480, 1 bit per pixel, 32 bit words, MSB = leftmost pixel
//     word_addr = y*20 + x[9:5],  bit_index = 31 - x[4:0]
//     9,600 words, address 0..9599
//
//   The word address is a plain counter, not y*20 + x[9:5]. Words are produced
//   in raster order anyway, so the multiply never needs to exist - and a
//   constant multiply on an address path is exactly what cost adaptive.v 4 ns
//   before it was replaced by a concatenation.
//
// FB_INV - polarity is a setting, not a constant
//   Front-End internal binary is 0xFF = white (bright), 0x00 = black. Which of
//   those becomes a 1 in the frame buffer depends on the application:
//
//     cfg_fb_inv = 1   dark -> 1    P0 BARCODE / P1 QR / P3 RAW
//     cfg_fb_inv = 0   bright -> 1  P2 EDGE
//
//   Barcode and QR treat dark as the foreground, but P2 EDGE feeds Hough with a
//   Sobel edge map where the EDGE is the bright 0xFF. A fixed inversion would
//   hand Hough a buffer with edges as 0 and background as 1. Flipping the
//   threshold polarity instead just moves the problem to the other preset, so
//   neither constant works - it has to be a bit.
//
//   Inverting costs nothing: it is absorbed into the LUT feeding the packing
//   shift register. See docs/STATUS.md 4-1.
//
// ** This module never asserts backpressure. **
//   s_axis_tready is tied high. The camera cannot be stalled, and there is no
//   input FIFO, so refusing a beat would lose pixels somewhere upstream with no
//   way to recover them. Instead, when the previous frame has not been released
//   yet, the incoming frame is DROPPED whole and frame_dropped is raised.
//   That is what "frame_release" really means - see handoff spec section 4.
//
// Frame handshake
//   last word written -> wr_en low -> frame_ready high (level, not a pulse)
//   frame_ready stays high until frame_release. Frames arriving in between are
//   dropped.
//
//   Two counters, and the difference matters:
//     frame_num       CAPTURED frames. Does not count what was thrown away.
//     frame_drop_cnt  DROPPED frames. One count per SOF that arrived while
//                     frame_ready was still high.
//
//   frame_num alone cannot tell software how many frames were lost - it would
//   have to guess the arrival count from elapsed time, which is wrong the
//   moment the camera rate wobbles. frame_dropped is only a sticky bit and
//   says "at least one", never how many. The counter closes that gap for
//   16 flip-flops.
//
//   Both counters free-run and wrap. Read them as differences between two
//   polls, the same way frame_num is meant to be read; a wrap is invisible to
//   a subtraction as long as fewer than 65536 frames pass between reads.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module binary_frame_writer #(
    parameter integer DW    = 8,
    parameter integer WORDW = 32,      // pixels packed per word
    parameter integer AW    = 14       // 9600 words needs 14 bits
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [11:0]          cfg_width,      // must be a multiple of WORDW
    input  wire [11:0]          cfg_height,
    input  wire                 cfg_fb_inv,     // 1 = dark->1, 0 = bright->1

    input  wire                 frame_release,  // extraction side is done
    input  wire                 stat_clear,     // 1 cycle, clears the sticky flags

    // ---- Slave : binary 8bit, 0x00 / 0xFF ---------------------------------
    input  wire [DW-1:0]        s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,  // tied high, see header
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // ---- Binary Frame BRAM write port -------------------------------------
    output reg                  wr_en,
    output reg  [AW-1:0]        wr_addr,
    output reg  [WORDW-1:0]     wr_data,

    // ---- 32 bit stream for AXI DMA S2MM (PS copy in DDR) ------------------
    output reg  [WORDW-1:0]     m_axis_tdata,
    output reg                  m_axis_tvalid,
    input  wire                 m_axis_tready,
    output reg                  m_axis_tlast,   // end of frame

    // ---- status -----------------------------------------------------------
    output reg                  frame_ready,
    output reg  [15:0]          frame_num,      // captured frames, free-running
    output reg                  frame_dropped,  // sticky
    output reg  [15:0]          frame_drop_cnt, // dropped frames, free-running
    output reg                  dma_overflow    // sticky, DMA was not ready
);

    localparam integer BC = 5;                  // log2(WORDW)

    // The stream is always accepted. Dropping happens inside, not upstream.
    assign s_axis_tready = 1'b1;

    wire beat = s_axis_tvalid;                  // tready is always 1

    // Any non-zero pixel is "set". The contract guarantees 0x00 / 0xFF, but the
    // reduction keeps the meaning sane if grayscale ever reaches here.
    wire px_set = |s_axis_tdata;
    wire bit_in = cfg_fb_inv ? ~px_set : px_set;

    reg               capturing;
    reg [BC-1:0]      bit_cnt;
    reg [WORDW-1:0]   pack;
    reg [11:0]        row;
    reg [AW-1:0]      word_idx;       // address of the NEXT word to write

    // Start of frame. A new frame can only be taken when the previous one has
    // been released; otherwise it is dropped whole.
    wire sof       = beat && s_axis_tuser;
    wire can_start = ~frame_ready;
    wire start_now = sof && can_start;

    // The SOF pixel is part of the frame, so it must be packed in the very
    // cycle capturing is decided - not one cycle later. The *_eff signals treat
    // the counters as already reset on that beat, which is why the first pixel
    // is not lost and why wr_addr starts at 0.
    wire              active   = beat && (capturing || start_now);
    wire [BC-1:0]     bit_eff  = start_now ? {BC{1'b0}} : bit_cnt;
    wire [11:0]       row_eff  = start_now ? 12'd0      : row;
    wire [AW-1:0]     idx_eff  = start_now ? {AW{1'b0}} : word_idx;

    wire [WORDW-1:0] pack_next = {pack[WORDW-2:0], bit_in};
    wire             word_done = (bit_eff == WORDW - 1);
    wire             last_row  = (row_eff == cfg_height - 12'd1);
    wire             frame_end = active && s_axis_tlast && last_row;

    always @(posedge aclk) begin
        if (!aresetn) begin
            capturing     <= 1'b0;
            bit_cnt       <= {BC{1'b0}};
            word_idx      <= {AW{1'b0}};
            wr_addr       <= {AW{1'b0}};
            row           <= 12'd0;
            wr_en         <= 1'b0;
            frame_ready    <= 1'b0;
            frame_num      <= 16'd0;
            frame_dropped  <= 1'b0;
            frame_drop_cnt <= 16'd0;
            dma_overflow   <= 1'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            wr_en <= 1'b0;

            // Sticky flags are cleared FIRST so that an event landing on the
            // same cycle still wins - the later assignments below override
            // this one. Losing an event to a clear would be the worst kind of
            // bug here: the flag exists precisely to catch rare events.
            //
            // The counters are deliberately NOT cleared. frame_drop_cnt is a
            // count, so a difference between two reads already gives the rate
            // and monotonic is the useful behaviour. A peak like
            // axis_fifo's fifo_max_level is different - a difference of two
            // peaks means nothing, so that one does get cleared.
            if (stat_clear) begin
                frame_dropped <= 1'b0;
                dma_overflow  <= 1'b0;
            end

            // The DMA copy is one beat per word. It is 0.29 MHz of words
            // against a 125 MHz clock, so a stall means something is wrong
            // rather than merely busy - record it instead of stalling.
            if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
            end

            if (frame_release) frame_ready <= 1'b0;

            // One drop counted per SOF, not per beat. The decision is made at
            // the frame boundary and the whole frame goes, so the rest of the
            // beats must not add to the count.
            if (start_now)               capturing <= 1'b1;
            else if (sof && ~can_start) begin
                capturing      <= 1'b0;
                frame_dropped  <= 1'b1;
                frame_drop_cnt <= frame_drop_cnt + 16'd1;
            end

            if (active) begin
                pack <= pack_next;
                row  <= s_axis_tlast ? (row_eff + 12'd1) : row_eff;

                if (word_done) begin
                    bit_cnt  <= {BC{1'b0}};
                    // wr_addr carries the address OF this word, so it takes
                    // idx_eff. word_idx then moves on for the next one.
                    wr_en    <= 1'b1;
                    wr_data  <= pack_next;
                    wr_addr  <= idx_eff;
                    word_idx <= idx_eff + {{(AW-1){1'b0}}, 1'b1};

                    if (m_axis_tvalid && !m_axis_tready) dma_overflow <= 1'b1;
                    m_axis_tdata  <= pack_next;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= frame_end;
                end else begin
                    bit_cnt  <= bit_eff + {{(BC-1){1'b0}}, 1'b1};
                    word_idx <= idx_eff;
                end

                if (frame_end) begin
                    capturing   <= 1'b0;
                    frame_ready <= 1'b1;
                    frame_num   <= frame_num + 16'd1;
                end
            end
        end
    end

    // ------------------------------------------------------- simulation check
    // A width that is not a multiple of WORDW would silently pack pixels from
    // the next row into the tail word and shift the whole image.
    // synthesis translate_off
    always @(posedge aclk) begin
        if (aresetn && sof && (cfg_width[BC-1:0] != {BC{1'b0}}))
            $display("[FBWRITE][ERR] cfg_width %0d is not a multiple of %0d",
                     cfg_width, WORDW);
    end
    // synthesis translate_on

endmodule
