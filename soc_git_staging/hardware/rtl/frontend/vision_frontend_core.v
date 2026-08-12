`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : vision_frontend_core
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   The whole Front-End chain, selectable at run time by FE_MODE.
//
//     RGB565 -> grayscale
//            -> [gaussian]
//            -> [sobel]
//            -> [threshold | adaptive]
//            -> [morphology]
//            -> Gray8 / binary  --+--> m_axis, 8 bit (bring-up and testbenches)
//                                 |
//                                 +--> binary_frame_writer
//                                        -> Binary Frame BRAM Port A
//                                        -> fb_axis, 32 bit, for AXI DMA S2MM
//
//   Every optional stage sits inside an axis_bypass, so a disabled stage is
//   routed around entirely rather than left in the path. One bitstream covers
//   every application; nothing is re-synthesised to change presets.
//
//   Runtime selection does NOT save area. All stages are always synthesised and
//   the bypasses cost extra on top. Measured, the whole chain is a couple of
//   percent of the device, so the trade is worth it: the value is one bitstream
//   for several applications, not a smaller one.
//
// FE_MODE
//   [0] gaussian_en   [1] sobel_en     [2] thresh_en
//   [3] thresh_adaptive (0 = global, 1 = adaptive)
//   [4] morph_en      [5] morph_close  (0 = opening, 1 = closing)
//
//   Global and adaptive thresholding are two bypasses in series rather than one
//   three way switch. At most one is ever enabled, so the stream passes through
//   one and around the other, and the same primitive covers both.
//
//   Presets, verified against vectors/<pattern>_p*.mem:
//     0x0C  P0 BARCODE   gray -> adaptive
//     0x3D  P1 QR        gray -> gauss -> adaptive -> closing
//     0x07  P2 EDGE      gray -> gauss -> sobel -> global
//     0x04  P3 RAW       gray -> global
//
//   Invalid combinations are listed in docs/STATUS.md 3-7 and reported through
//   cfg_invalid. This block only flags them; it does not refuse to run, because
//   silently substituting a different mode would be worse than a wrong image
//   with a status bit set.
//
// Note on latency and the valid margin
//   Each enabled window stage adds about one row of latency, W*2 beats of
//   per-frame flush, and 1 px of replicate-derived border. adaptive adds 16 px
//   of border on its own. valid_margin exposes the total; software must crop by
//   it rather than assume a constant.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module vision_frontend_core #(
    parameter integer MAX_W = 640,

    // Build sobel into the chain at all.
    //
    // 0 is the default because P2 EDGE (Hough line detection) is out of scope
    // and NOTHING else uses sobel: P0 BARCODE is gray->adaptive, P1 QR is
    // gray->gauss->adaptive->closing, and the extraction side reads 1 bit
    // pixels out of the frame buffer. There is no consumer for an edge map.
    //
    // It was left instantiated-but-disabled at first, on the reasoning that
    // FE_MODE keeps it switched off so it costs only area. That reasoning was
    // wrong about TIMING. Static analysis does not know a module is never
    // enabled - the logic is on the die and gets timed either way, and in the
    // real block design sobel was the ONLY thing that failed:
    //
    //   with sobel      WNS -0.108 ns   all 8 failing endpoints in u_sobel
    //   without sobel   WNS +0.335 ns   critical path back in u_adaptive
    //
    // Set to 1 to bring P2 EDGE back. The module, its testbench and its golden
    // vectors are all still here, so that is the only edit needed.
    parameter integer ENABLE_SOBEL = 0
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // ---- configuration. Must be stable while a frame is in flight ----------
    input  wire [11:0]          cfg_width,
    input  wire [11:0]          cfg_height,
    input  wire [5:0]           cfg_fe_mode,
    input  wire [7:0]           cfg_thresh,     // global threshold
    input  wire [7:0]           cfg_c,          // adaptive offset C
    input  wire                 cfg_fb_inv,     // 1 = dark->1. Fixed 1 in this scope
    input  wire                 frame_release,  // extraction side is done with the buffer
    input  wire                 stat_clear,     // 1 cycle, clears the sticky status flags

    output wire                 cfg_invalid,    // FE_MODE violates R1/R2/R3
    output wire [7:0]           valid_margin,   // replicate-derived border, px

    // ---- Slave : RGB565 ----------------------------------------------------
    input  wire [15:0]          s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tuser,
    input  wire                 s_axis_tlast,

    // ---- Master : Gray8 or binary -----------------------------------------
    //   Kept for bring-up and for the golden-vector testbenches. In the block
    //   design m_axis_tready is tied high; see the frame buffer writer below.
    output wire [7:0]           m_axis_tdata,
    output wire                 m_axis_tvalid,
    input  wire                 m_axis_tready,
    output wire                 m_axis_tuser,
    output wire                 m_axis_tlast,

    // ---- Binary Frame BRAM write port (Port A) -----------------------------
    //   Port B goes to the feature extraction side. Names match
    //   docs/extractor_handoff_spec.md section 3.
    output wire                 wr_en,
    output wire [13:0]          wr_addr,
    output wire [31:0]          wr_data,

    // ---- 32 bit stream for AXI DMA S2MM (PS copy in DDR) ------------------
    output wire [31:0]          fb_axis_tdata,
    output wire                 fb_axis_tvalid,
    input  wire                 fb_axis_tready,
    output wire                 fb_axis_tlast,

    // ---- frame handshake and status ---------------------------------------
    output wire                 frame_ready,
    output wire [15:0]          frame_num,      // captured frames, free-running
    output wire                 frame_dropped,  // sticky
    output wire [15:0]          frame_drop_cnt, // dropped frames, free-running
    output wire                 dma_overflow    // sticky
);

    wire gauss_en  = cfg_fe_mode[0];
    wire sobel_en  = cfg_fe_mode[1];
    wire thresh_en = cfg_fe_mode[2];
    wire adapt_sel = cfg_fe_mode[3];
    wire morph_en  = cfg_fe_mode[4];
    wire morph_cl  = cfg_fe_mode[5];

    wire glob_en = thresh_en & ~adapt_sel;
    wire adap_en = thresh_en &  adapt_sel;

    // ---- rule checks, docs/STATUS.md 3-7 -----------------------------------
    wire r1_bad = ~thresh_en;                  // binary path needs a threshold
    wire r2_bad = morph_en & ~thresh_en;       // morphology needs binary input
    wire r3_bad = sobel_en &  adapt_sel;       // adaptive on an edge map

    // R4: sobel asked for on a build that has none. Without this the mode runs
    // and quietly produces a gaussian image instead of an edge map, which
    // looks like an algorithm bug rather than a configuration one.
    wire r4_bad = sobel_en & (ENABLE_SOBEL == 0);

    assign cfg_invalid = r1_bad | r2_bad | r3_bad | r4_bad;

    // What is actually in the path, as opposed to what was asked for. Only
    // this may feed valid_margin - a stage that is not built contributes no
    // border. Identical to sobel_en whenever ENABLE_SOBEL is 1.
    wire sobel_act = sobel_en & (ENABLE_SOBEL != 0);

    // 3x3 stages contribute 1 px each, morphology is two of them, and adaptive
    // contributes half its window. Kept as an adder so software never has to
    // hardcode a number that depends on the mode.
    assign valid_margin = {7'd0, gauss_en}
                        + {7'd0, sobel_act}
                        + (morph_en ? 8'd2  : 8'd0)
                        + (adap_en  ? 8'd16 : 8'd0);

    // ======================================================== grayscale
    wire [7:0] g_tdata;
    wire       g_tvalid, g_tready, g_tuser, g_tlast;

    grayscale #(
        .DW_IN  (16),
        .DW_OUT (8)
    ) u_gray (
        .aclk (aclk), .aresetn (aresetn),
        .s_axis_tdata (s_axis_tdata), .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready), .s_axis_tuser (s_axis_tuser),
        .s_axis_tlast (s_axis_tlast),
        .m_axis_tdata (g_tdata), .m_axis_tvalid (g_tvalid),
        .m_axis_tready (g_tready), .m_axis_tuser (g_tuser),
        .m_axis_tlast (g_tlast)
    );

    // Each stage below follows the same shape: a bypass switch, the stage it
    // wraps, and the node that carries on down the chain.
    `define FE_STAGE_WIRES(nm) \
        wire [7:0] nm``_u_tdata, nm``_v_tdata, nm``_tdata;                 \
        wire nm``_u_tvalid, nm``_u_tready, nm``_u_tuser, nm``_u_tlast;     \
        wire nm``_v_tvalid, nm``_v_tready, nm``_v_tuser, nm``_v_tlast;     \
        wire nm``_tvalid, nm``_tready, nm``_tuser, nm``_tlast;

    `FE_STAGE_WIRES(ga)
    `FE_STAGE_WIRES(so)
    `FE_STAGE_WIRES(th)
    `FE_STAGE_WIRES(ad)
    `FE_STAGE_WIRES(mo)

    // Register slice landing points: mid-chain and at the output. tready is
    // combinational through every stage (ready | ~valid) plus five bypass
    // muxes, and measured on the 1-stage case that path is 94 percent routing,
    // so it grows with distance. The slices cut it in both directions at the
    // cost of one beat of latency each. See STATUS.md 3-3.
    wire [7:0] sq_tdata, mq_tdata;
    wire       sq_tvalid, sq_tready, sq_tuser, sq_tlast;
    wire       mq_tvalid, mq_tready, mq_tuser, mq_tlast;

    // ======================================================== gaussian
    axis_bypass #(.DW(8)) u_bp_ga (
        .en (gauss_en),
        .s_tdata (g_tdata), .s_tvalid (g_tvalid), .s_tready (g_tready),
        .s_tuser (g_tuser), .s_tlast (g_tlast),
        .u_tdata (ga_u_tdata), .u_tvalid (ga_u_tvalid), .u_tready (ga_u_tready),
        .u_tuser (ga_u_tuser), .u_tlast (ga_u_tlast),
        .v_tdata (ga_v_tdata), .v_tvalid (ga_v_tvalid), .v_tready (ga_v_tready),
        .v_tuser (ga_v_tuser), .v_tlast (ga_v_tlast),
        .m_tdata (ga_tdata), .m_tvalid (ga_tvalid), .m_tready (ga_tready),
        .m_tuser (ga_tuser), .m_tlast (ga_tlast)
    );

    gaussian #(.DW(8), .MAX_W(MAX_W)) u_gauss (
        .aclk (aclk), .aresetn (aresetn),
        .cfg_width (cfg_width), .cfg_height (cfg_height),
        .s_axis_tdata (ga_u_tdata), .s_axis_tvalid (ga_u_tvalid),
        .s_axis_tready (ga_u_tready), .s_axis_tuser (ga_u_tuser),
        .s_axis_tlast (ga_u_tlast),
        .m_axis_tdata (ga_v_tdata), .m_axis_tvalid (ga_v_tvalid),
        .m_axis_tready (ga_v_tready), .m_axis_tuser (ga_v_tuser),
        .m_axis_tlast (ga_v_tlast)
    );

    // ======================================================== sobel
    generate
    if (ENABLE_SOBEL != 0) begin : g_sobel

        axis_bypass #(.DW(8)) u_bp_so (
            .en (sobel_en),
            .s_tdata (ga_tdata), .s_tvalid (ga_tvalid), .s_tready (ga_tready),
            .s_tuser (ga_tuser), .s_tlast (ga_tlast),
            .u_tdata (so_u_tdata), .u_tvalid (so_u_tvalid), .u_tready (so_u_tready),
            .u_tuser (so_u_tuser), .u_tlast (so_u_tlast),
            .v_tdata (so_v_tdata), .v_tvalid (so_v_tvalid), .v_tready (so_v_tready),
            .v_tuser (so_v_tuser), .v_tlast (so_v_tlast),
            .m_tdata (so_tdata), .m_tvalid (so_tvalid), .m_tready (so_tready),
            .m_tuser (so_tuser), .m_tlast (so_tlast)
        );

        sobel #(.DW(8), .MAX_W(MAX_W)) u_sobel (
            .aclk (aclk), .aresetn (aresetn),
            .cfg_width (cfg_width), .cfg_height (cfg_height),
            .s_axis_tdata (so_u_tdata), .s_axis_tvalid (so_u_tvalid),
            .s_axis_tready (so_u_tready), .s_axis_tuser (so_u_tuser),
            .s_axis_tlast (so_u_tlast),
            .m_axis_tdata (so_v_tdata), .m_axis_tvalid (so_v_tvalid),
            .m_axis_tready (so_v_tready), .m_axis_tuser (so_v_tuser),
            .m_axis_tlast (so_v_tlast)
        );

    end else begin : g_no_sobel

        // Straight through. Not an axis_bypass with en tied low - that would
        // leave the mux, and the point of the parameter is that nothing is
        // built at all.
        assign so_tdata  = ga_tdata;
        assign so_tvalid = ga_tvalid;
        assign so_tuser  = ga_tuser;
        assign so_tlast  = ga_tlast;
        assign ga_tready = so_tready;

        // The stage wire macro declares these for every stage, so tie the
        // unused half off rather than leaving it floating.
        assign so_u_tdata  = 8'd0;
        assign so_u_tvalid = 1'b0;
        assign so_u_tuser  = 1'b0;
        assign so_u_tlast  = 1'b0;
        assign so_u_tready = 1'b0;
        assign so_v_tdata  = 8'd0;
        assign so_v_tvalid = 1'b0;
        assign so_v_tuser  = 1'b0;
        assign so_v_tlast  = 1'b0;
        assign so_v_tready = 1'b0;

    end
    endgenerate

    // ---- mid-chain register slice ------------------------------------------
    axis_reg_slice #(.DW(8)) u_slice_mid (
        .aclk (aclk), .aresetn (aresetn),
        .s_tdata (so_tdata), .s_tvalid (so_tvalid), .s_tready (so_tready),
        .s_tuser (so_tuser), .s_tlast (so_tlast),
        .m_tdata (sq_tdata), .m_tvalid (sq_tvalid), .m_tready (sq_tready),
        .m_tuser (sq_tuser), .m_tlast (sq_tlast)
    );

    // ======================================================== threshold (global)
    axis_bypass #(.DW(8)) u_bp_th (
        .en (glob_en),
        .s_tdata (sq_tdata), .s_tvalid (sq_tvalid), .s_tready (sq_tready),
        .s_tuser (sq_tuser), .s_tlast (sq_tlast),
        .u_tdata (th_u_tdata), .u_tvalid (th_u_tvalid), .u_tready (th_u_tready),
        .u_tuser (th_u_tuser), .u_tlast (th_u_tlast),
        .v_tdata (th_v_tdata), .v_tvalid (th_v_tvalid), .v_tready (th_v_tready),
        .v_tuser (th_v_tuser), .v_tlast (th_v_tlast),
        .m_tdata (th_tdata), .m_tvalid (th_tvalid), .m_tready (th_tready),
        .m_tuser (th_tuser), .m_tlast (th_tlast)
    );

    threshold #(.DW(8)) u_thresh (
        .aclk (aclk), .aresetn (aresetn),
        .cfg_thresh (cfg_thresh),
        .s_axis_tdata (th_u_tdata), .s_axis_tvalid (th_u_tvalid),
        .s_axis_tready (th_u_tready), .s_axis_tuser (th_u_tuser),
        .s_axis_tlast (th_u_tlast),
        .m_axis_tdata (th_v_tdata), .m_axis_tvalid (th_v_tvalid),
        .m_axis_tready (th_v_tready), .m_axis_tuser (th_v_tuser),
        .m_axis_tlast (th_v_tlast)
    );

    // ======================================================== threshold (adaptive)
    axis_bypass #(.DW(8)) u_bp_ad (
        .en (adap_en),
        .s_tdata (th_tdata), .s_tvalid (th_tvalid), .s_tready (th_tready),
        .s_tuser (th_tuser), .s_tlast (th_tlast),
        .u_tdata (ad_u_tdata), .u_tvalid (ad_u_tvalid), .u_tready (ad_u_tready),
        .u_tuser (ad_u_tuser), .u_tlast (ad_u_tlast),
        .v_tdata (ad_v_tdata), .v_tvalid (ad_v_tvalid), .v_tready (ad_v_tready),
        .v_tuser (ad_v_tuser), .v_tlast (ad_v_tlast),
        .m_tdata (ad_tdata), .m_tvalid (ad_tvalid), .m_tready (ad_tready),
        .m_tuser (ad_tuser), .m_tlast (ad_tlast)
    );

    adaptive #(.DW(8), .MAX_W(MAX_W), .WIN(32), .SHIFT(10)) u_adaptive (
        .aclk (aclk), .aresetn (aresetn),
        .cfg_width (cfg_width), .cfg_height (cfg_height), .cfg_c (cfg_c),
        .s_axis_tdata (ad_u_tdata), .s_axis_tvalid (ad_u_tvalid),
        .s_axis_tready (ad_u_tready), .s_axis_tuser (ad_u_tuser),
        .s_axis_tlast (ad_u_tlast),
        .m_axis_tdata (ad_v_tdata), .m_axis_tvalid (ad_v_tvalid),
        .m_axis_tready (ad_v_tready), .m_axis_tuser (ad_v_tuser),
        .m_axis_tlast (ad_v_tlast)
    );

    // ======================================================== morphology
    axis_bypass #(.DW(8)) u_bp_mo (
        .en (morph_en),
        .s_tdata (ad_tdata), .s_tvalid (ad_tvalid), .s_tready (ad_tready),
        .s_tuser (ad_tuser), .s_tlast (ad_tlast),
        .u_tdata (mo_u_tdata), .u_tvalid (mo_u_tvalid), .u_tready (mo_u_tready),
        .u_tuser (mo_u_tuser), .u_tlast (mo_u_tlast),
        .v_tdata (mo_v_tdata), .v_tvalid (mo_v_tvalid), .v_tready (mo_v_tready),
        .v_tuser (mo_v_tuser), .v_tlast (mo_v_tlast),
        .m_tdata (mq_tdata), .m_tvalid (mq_tvalid),
        .m_tready (mq_tready), .m_tuser (mq_tuser),
        .m_tlast (mq_tlast)
    );

    // ---- output register slice ---------------------------------------------
    axis_reg_slice #(.DW(8)) u_slice_out (
        .aclk (aclk), .aresetn (aresetn),
        .s_tdata (mq_tdata), .s_tvalid (mq_tvalid), .s_tready (mq_tready),
        .s_tuser (mq_tuser), .s_tlast (mq_tlast),
        .m_tdata (m_axis_tdata), .m_tvalid (m_axis_tvalid),
        .m_tready (m_axis_tready), .m_tuser (m_axis_tuser),
        .m_tlast (m_axis_tlast)
    );

    morphology #(.DW(8), .MAX_W(MAX_W)) u_morph (
        .aclk (aclk), .aresetn (aresetn),
        .cfg_width (cfg_width), .cfg_height (cfg_height), .cfg_close (morph_cl),
        .s_axis_tdata (mo_u_tdata), .s_axis_tvalid (mo_u_tvalid),
        .s_axis_tready (mo_u_tready), .s_axis_tuser (mo_u_tuser),
        .s_axis_tlast (mo_u_tlast),
        .m_axis_tdata (mo_v_tdata), .m_axis_tvalid (mo_v_tvalid),
        .m_axis_tready (mo_v_tready), .m_axis_tuser (mo_v_tuser),
        .m_axis_tlast (mo_v_tlast)
    );

    // ======================================================== frame buffer writer
    // The writer OBSERVES the 8 bit output; it does not consume it.
    //
    // It ties its own tready high and can never backpressure, so handing it
    // m_axis_tvalid alone would be wrong: a beat held by a low m_axis_tready is
    // offered but NOT transferred, and the writer would pack the same pixel
    // twice. It has to be told when a transfer actually happened.
    //
    // This is the ordinary passive-monitor tap on an AXI4-Stream channel -
    // a transfer is valid AND ready - and it is the only place in the core
    // where a tvalid input is driven by anything other than a tvalid.
    //
    // Consequence to know: with m_axis_tready low the frame buffer stalls
    // together with the chain. That is the safe failure - it records nothing
    // rather than recording duplicates. In the block design m_axis_tready is
    // tied high and the 8 bit port is bring-up only.
    wire fb_beat = m_axis_tvalid & m_axis_tready;

    binary_frame_writer #(
        .DW    (8),
        .WORDW (32),
        .AW    (14)
    ) u_fbwrite (
        .aclk (aclk), .aresetn (aresetn),
        .cfg_width (cfg_width), .cfg_height (cfg_height),
        .cfg_fb_inv (cfg_fb_inv),
        .frame_release (frame_release),
        .stat_clear (stat_clear),
        .s_axis_tdata (m_axis_tdata), .s_axis_tvalid (fb_beat),
        .s_axis_tready (),      // tied high inside the writer, nothing to drive
        .s_axis_tuser (m_axis_tuser), .s_axis_tlast (m_axis_tlast),
        .wr_en (wr_en), .wr_addr (wr_addr), .wr_data (wr_data),
        .m_axis_tdata (fb_axis_tdata), .m_axis_tvalid (fb_axis_tvalid),
        .m_axis_tready (fb_axis_tready), .m_axis_tlast (fb_axis_tlast),
        .frame_ready (frame_ready), .frame_num (frame_num),
        .frame_dropped (frame_dropped), .frame_drop_cnt (frame_drop_cnt),
        .dma_overflow (dma_overflow)
    );

    `undef FE_STAGE_WIRES

endmodule
