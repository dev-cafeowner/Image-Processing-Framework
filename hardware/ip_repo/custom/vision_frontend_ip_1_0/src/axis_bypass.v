`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : axis_bypass
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   Routes an AXI4-Stream around one processing stage at run time.
//
//     en = 1    upstream -> stage -> downstream
//     en = 0    upstream -------------> downstream, stage sees no valid beats
//
//   Four interfaces, because a bypass is not something a wrapper can express in
//   Verilog. The stage stays a separate instance and this block sits around it:
//
//       s (upstream) ---+--------------------------------+
//                       |                                |
//                       +--> u (to stage) ... v (back) --+--> m (downstream)
//
//   ** A bypass is not a data mux. ** tready has to be routed backwards too.
//   Muxing only tdata and leaving the stage in the chain still lets the
//   bypassed stage consume, produce, and stall the stream with its own tready.
//   That is the mistake this module exists to prevent.
//
//   The bypass path is pure wire, so en = 0 is bit-exact pass-through with zero
//   added latency. That is also what makes it free to verify: the expected
//   output of a bypassed stage is the input vector itself, so no new golden
//   vector is needed and the test still checks tuser/tlast alignment, the pixel
//   count and the handshake all at once.
//
//   Cost of the wire: tready gains one more mux level per bypass. With five of
//   them in vision_frontend_core that is five levels on a path that is already
//   mostly routing delay - see STATUS.md 3-3. If it ever becomes the critical
//   path the fix is a register slice, not a rewrite of this block.
//
//   Switching en mid-frame orphans whatever the stage still holds. The control
//   contract only changes configuration on a frame boundary and reports what
//   was actually applied in MODE_APPLIED, so software never has to guess.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module axis_bypass #(
    parameter integer DW = 8
)(
    input  wire                 en,

    // Upstream
    input  wire [DW-1:0]        s_tdata,
    input  wire                 s_tvalid,
    output wire                 s_tready,
    input  wire                 s_tuser,
    input  wire                 s_tlast,

    // To the stage
    output wire [DW-1:0]        u_tdata,
    output wire                 u_tvalid,
    input  wire                 u_tready,
    output wire                 u_tuser,
    output wire                 u_tlast,

    // Back from the stage
    input  wire [DW-1:0]        v_tdata,
    input  wire                 v_tvalid,
    output wire                 v_tready,
    input  wire                 v_tuser,
    input  wire                 v_tlast,

    // Downstream
    output wire [DW-1:0]        m_tdata,
    output wire                 m_tvalid,
    input  wire                 m_tready,
    output wire                 m_tuser,
    output wire                 m_tlast
);

    // Feed the stage only while it is enabled. tdata/tuser/tlast may keep
    // toggling; gating tvalid is what stops the stage from consuming.
    assign u_tdata  = s_tdata;
    assign u_tvalid = s_tvalid & en;
    assign u_tuser  = s_tuser;
    assign u_tlast  = s_tlast;

    // Drain the stage while enabled. Held high when bypassed so a stage that
    // still has a beat in flight from before the switch cannot deadlock.
    assign v_tready = m_tready | ~en;

    // Downstream takes the stage output or the raw stream.
    assign m_tdata  = en ? v_tdata  : s_tdata;
    assign m_tvalid = en ? v_tvalid : s_tvalid;
    assign m_tuser  = en ? v_tuser  : s_tuser;
    assign m_tlast  = en ? v_tlast  : s_tlast;

    // The backward half of the mux. Without this the bypassed stage would keep
    // control of the upstream handshake.
    assign s_tready = en ? u_tready : m_tready;

endmodule
