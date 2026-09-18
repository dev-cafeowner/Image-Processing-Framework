`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : ov7670_capture
// Project     : Vision Front-End (Zynq-7020 / Zybo Z7-20)
// Target      : xc7z020clg400-1
//
// Description :
//   OV7670 parallel receiver. Takes PCLK / HREF / VSYNC / D[7:0] straight off
//   the Pmod pins and produces the RGB565 AXI4-Stream that axis_fifo and
//   vision_frontend_core already expect: tuser = SOF, tlast = EOL.
//
//   This is the 18 pin OV7670 with no AL422B. The camera cannot be stalled, so
//   the only honest response to backpressure is to drop and say so - see
//   cam_overflow below.
//
// THE WHOLE POINT: there is no second clock domain
//   PCLK is an input pin at 12.5 MHz. The obvious design puts it on a BUFG and
//   builds a PCLK domain with a CDC FIFO into aclk. This one does not, and that
//   is deliberate:
//
//     - aclk is 125 MHz and PCLK is 12.5 MHz. Ten aclk edges per PCLK period is
//       plenty to oversample, so a synchroniser plus edge detect gets every
//       byte with no CDC anywhere.
//     - XCLK is generated here by dividing aclk by ten. The camera derives PCLK
//       from XCLK, so PCLK is frequency-locked to aclk by construction. It is
//       phase-unrelated - it leaves through a pin and comes back through the
//       sensor - but it cannot drift, so the oversampling ratio is exactly ten
//       forever, not "about ten".
//     - PCLK therefore does not need a clock capable pin. That is the practical
//       payoff: any Pmod pin will do.
//
//   XCLK is a divided output, not a forwarded clock. Nothing in this module is
//   clocked by it, so it is ordinary registered data on its way to an OBUF and
//   needs no ODDR and no clock forwarding.
//
// Sampling alignment, because it looks off by one and is not
//   pclk_rise is asserted the cycle in which pclk_s[1] is high and pclk_s[2] is
//   still low. In that same cycle d_s1 holds cam_data as it was at the edge
//   that captured the PCLK rise. Data and strobe come down two flop stages
//   each, so they stay aligned and both are metastability hardened. Using d_s0
//   would shave a cycle and reintroduce the metastability this exists to avoid.
//
//   The OV7670 changes D[7:0] on the PCLK falling edge, so at the rising edge
//   the byte has been stable for half a PCLK period - 40 ns here. There is no
//   timing question to answer at this ratio.
//
// tlast needs one pixel of lookahead
//   EOL belongs on the last beat of a line, and the receiver does not know a
//   beat was the last one until HREF falls afterwards. Counting to cfg_width
//   would work only when the camera is in the mode we think it is, which during
//   bring up is exactly the assumption that is wrong.
//
//   So a completed pixel waits one slot in pend_*. It is emitted when the next
//   pixel completes (tlast = 0) or when HREF falls (tlast = 1). The receiver
//   never needs to be told the line length, and reports back what it measured
//   instead - see cam_line_len.
//
// capture_en, and why the status logic ignores it
//   Framing and measurement run on aresetn and keep running while the pipeline
//   is disabled. That is the point: plug the camera in, read CAM_STATUS, see
//   640 x 480, and only then enable the pipeline. Status that only exists once
//   you have enabled the thing you are trying to debug is status you cannot use.
//
//   capture_en gates the emit path only. While it is low, pixels are discarded
//   and cam_overflow is NOT set - a disabled pipeline is not an overflow, and
//   flagging it would leave the bit permanently on before first enable.
//
// cam_overflow means pixels were lost
//   The output is one register. If a pixel completes while the previous beat
//   has not been accepted, the new one is dropped and the sticky bit sets. At
//   6.25 Mpixel/s into a 125 MHz sink behind a 128 deep FIFO this should never
//   happen, so if it does, something downstream stalled and the frame is
//   misaligned, not merely short. The flag is the whole report; this module
//   does not try to resynchronise a frame it has already corrupted.
//
// NOTE: This file is intentionally ASCII-only. The Vivado Tcl console renders
//       source strings using the system code page, so non-ASCII text in
//       $display/$fatal comes out garbled. Korean documentation lives in docs/.
//
// Revision : 0.01 - File Created
//////////////////////////////////////////////////////////////////////////////////


module ov7670_capture #(
    // aclk / XCLK_DIV = XCLK. Must be even so the duty cycle stays 50 %.
    // 125 MHz / 10 = 12.5 MHz XCLK -> 12.5 MHz PCLK -> 15.6 fps at 640x480.
    // The OV7670 accepts 10 to 48 MHz on XCLK.
    parameter integer XCLK_DIV          = 10,

    // OV7670 default is an active high VSYNC pulse between frames; COM10[1]
    // inverts it. Kept as a parameter so a module that comes up inverted is a
    // one line change and not a debugging session.
    parameter integer VSYNC_ACTIVE_HIGH = 1
)(
    input  wire         aclk,
    input  wire         aresetn,

    // ---- camera pins -------------------------------------------------------
    input  wire         cam_pclk,
    input  wire         cam_href,
    input  wire         cam_vsync,
    input  wire [7:0]   cam_data,
    output wire         cam_xclk,

    // ---- control -----------------------------------------------------------
    input  wire         capture_en,     // cfg_enable & ~cfg_soft_reset
    input  wire         stat_clear,

    // ---- master : RGB565 to axis_fifo --------------------------------------
    output reg  [15:0]  m_axis_tdata,
    output reg          m_axis_tvalid,
    input  wire         m_axis_tready,
    output reg          m_axis_tuser,   // SOF
    output reg          m_axis_tlast,   // EOL

    // ---- status ------------------------------------------------------------
    // Separately for waveform and ILA use, and packed for the register bank.
    // The packed layout IS the CAM_STATUS register at 0x1C - see spec section 6.
    //
    //   [11:0]  line_len      pixels in the last completed line
    //   [23:12] frame_lines   lines in the last completed frame
    //   [24]    overflow      sticky
    //   [25]    vsync_seen    sticky
    //   [31:26] reserved, 0
    output wire [11:0]  cam_line_len,   // pixels in the last completed line
    output wire [11:0]  cam_frame_lines,// lines in the last completed frame
    output reg          cam_overflow,   // sticky
    output reg          cam_vsync_seen, // sticky
    output wire [31:0]  cam_status
);

    assign cam_status = {6'd0, cam_vsync_seen, cam_overflow,
                         cam_frame_lines, cam_line_len};

    // ====================================================================
    //  XCLK - aclk divided down, driven out as data
    // ====================================================================
    localparam integer HALF = XCLK_DIV / 2;

    reg [7:0] xdiv;
    reg       xclk_q;

    always @(posedge aclk) begin
        if (!aresetn) begin
            xdiv   <= 8'd0;
            xclk_q <= 1'b0;
        end else if (xdiv == HALF[7:0] - 8'd1) begin
            xdiv   <= 8'd0;
            xclk_q <= ~xclk_q;
        end else begin
            xdiv   <= xdiv + 8'd1;
        end
    end

    assign cam_xclk = xclk_q;

    // ====================================================================
    //  input synchronisers
    // ====================================================================
    // pclk gets three stages because the third is the edge detector's history
    // bit. href, vsync and the data bus get two.
    // Keep the two-stage input samplers together in implementation.
    // qr_perf uses aclk=62.5 MHz, XCLK_DIV=2 and CLKRC[7]=0:
    // PCLK <=15.625 MHz, not the original 125/12.5 MHz example above.
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] pclk_s;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] href_s;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] vsync_s;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [7:0] d_s0, d_s1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            pclk_s  <= 3'b000;
            href_s  <= 2'b00;
            vsync_s <= 2'b00;
            d_s0    <= 8'd0;
            d_s1    <= 8'd0;
        end else begin
            pclk_s  <= {pclk_s[1:0], cam_pclk};
            href_s  <= {href_s[0],   cam_href};
            vsync_s <= {vsync_s[0],  cam_vsync};
            d_s0    <= cam_data;
            d_s1    <= d_s0;
        end
    end

    wire pclk_rise = pclk_s[1] & ~pclk_s[2];
    wire href      = href_s[1];
    wire vsync_raw = vsync_s[1];
    wire vsync     = (VSYNC_ACTIVE_HIGH != 0) ? vsync_raw : ~vsync_raw;

    reg  href_d, vsync_d;
    always @(posedge aclk) begin
        if (!aresetn) begin
            href_d  <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d  <= href;
            vsync_d <= vsync;
        end
    end

    wire href_rise  =  href  & ~href_d;
    wire href_fall  = ~href  &  href_d;
    // The vertical sync pulse is asserted BETWEEN frames, so the trailing edge
    // is where pixel data begins and that is the semantically correct frame
    // start.
    //
    // Be aware that the leading edge would also work. Nothing observable
    // changes: HREF is low for the whole sync pulse, so no pixel can complete
    // between the two edges, and sof_pending, the emit gate and the line count
    // snapshot all end up in the same place either way. tb_ov7670 confirms this
    // - swapping the edge here is not detected, and that is a true equivalence
    // rather than a hole in the testbench.
    wire frame_start = ~vsync & vsync_d;

    // ====================================================================
    //  byte pairing
    // ====================================================================
    // OV7670 RGB565 sends the high byte first: {R[4:0],G[5:3]} then
    // {G[2:0],B[4:0]}. That lands directly on grayscale.v's R[15:11] /
    // G[10:5] / B[4:0] with no swapping.
    reg        byte_phase;      // 0 = next byte is the high byte
    reg [7:0]  hi_byte;
    reg        sof_pending;

    wire byte_stb    = pclk_rise & href;
    wire pixel_done  = byte_stb & byte_phase;
    wire [15:0] pixel = {hi_byte, d_s1};

    always @(posedge aclk) begin
        if (!aresetn) begin
            byte_phase  <= 1'b0;
            hi_byte     <= 8'd0;
            sof_pending <= 1'b0;
        end else begin
            // Realign at every line start. A glitch that costs one byte would
            // otherwise swap the two halves of every pixel for the rest of the
            // frame, which looks like a colour bug rather than a lost byte.
            if (href_rise)
                byte_phase <= 1'b0;
            else if (byte_stb)
                byte_phase <= ~byte_phase;

            if (byte_stb & ~byte_phase)
                hi_byte <= d_s1;

            if (frame_start)
                sof_pending <= 1'b1;
            else if (pixel_done)
                sof_pending <= 1'b0;
        end
    end

    // ====================================================================
    //  one pixel of lookahead, so tlast lands on the right beat
    // ====================================================================
    reg [15:0] pend_data;
    reg        pend_user;
    reg        pend_valid;

    reg [15:0] emit_data;
    reg        emit_user, emit_last, emit_req;

    // pixel_done needs href high; href_fall needs href low. They cannot be
    // asserted in the same cycle, so these two branches never race.
    always @(posedge aclk) begin
        if (!aresetn) begin
            pend_data  <= 16'd0;
            pend_user  <= 1'b0;
            pend_valid <= 1'b0;
            emit_data  <= 16'd0;
            emit_user  <= 1'b0;
            emit_last  <= 1'b0;
            emit_req   <= 1'b0;
        end else begin
            emit_req <= 1'b0;

            if (pixel_done) begin
                if (pend_valid) begin
                    emit_data <= pend_data;
                    emit_user <= pend_user;
                    emit_last <= 1'b0;
                    emit_req  <= 1'b1;
                end
                pend_data  <= pixel;
                pend_user  <= sof_pending;
                pend_valid <= 1'b1;
            end else if (href_fall & pend_valid) begin
                emit_data  <= pend_data;
                emit_user  <= pend_user;
                emit_last  <= 1'b1;
                emit_req   <= 1'b1;
                pend_valid <= 1'b0;
            end
        end
    end

    // ====================================================================
    //  emit gating - only ever start on a frame boundary
    // ====================================================================
    // capture_en can rise at any moment, including halfway down a frame. Emit
    // from that instant and the core receives a stream whose first beat is some
    // arbitrary pixel with no SOF in front of it, and every frame after that is
    // off by the remainder. The symptom is a permanently skewed image, which
    // does not point at the enable.
    //
    // So capture_en arms, and the next frame_start opens the gate. Dropping
    // capture_en closes it immediately and discards whatever was in flight.
    reg emitting;

    always @(posedge aclk) begin
        if (!aresetn)
            emitting <= 1'b0;
        else if (!capture_en)
            emitting <= 1'b0;
        else if (frame_start)
            emitting <= 1'b1;
    end

    // ====================================================================
    //  output register
    // ====================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 16'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tuser  <= 1'b0;
            m_axis_tlast  <= 1'b0;
            cam_overflow  <= 1'b0;
        end else begin
            if (m_axis_tvalid & m_axis_tready)
                m_axis_tvalid <= 1'b0;

            // A beat left stranded in the output register when the pipeline was
            // disabled must not be delivered on re-enable. It belongs to a frame
            // that no longer exists.
            if (!capture_en)
                m_axis_tvalid <= 1'b0;

            if (stat_clear)
                cam_overflow <= 1'b0;

            if (emit_req & emitting) begin
                if (m_axis_tvalid & ~m_axis_tready) begin
                    // The beat in the output register has not been taken and
                    // the camera has produced another. One pixel is gone.
                    cam_overflow <= 1'b1;
                end else begin
                    m_axis_tdata  <= emit_data;
                    m_axis_tuser  <= emit_user;
                    m_axis_tlast  <= emit_last;
                    m_axis_tvalid <= 1'b1;
                end
            end
        end
    end

    // ====================================================================
    //  measurement - what the camera is actually sending
    // ====================================================================
    // Not derived from cfg_width / cfg_height on purpose. These are what came
    // out of the sensor, so they are the one reading that can contradict the
    // configuration. 640 x 480 means VGA RGB565 is running. 320 means the SCCB
    // write for VGA did not take. 0 means no PCLK, or the data bus is dead.
    reg [11:0] px_in_line, line_len_r;
    reg [11:0] lines_in_fr, frame_lines_r;

    always @(posedge aclk) begin
        if (!aresetn) begin
            px_in_line     <= 12'd0;
            line_len_r     <= 12'd0;
            lines_in_fr    <= 12'd0;
            frame_lines_r  <= 12'd0;
            cam_vsync_seen <= 1'b0;
        end else begin
            if (pixel_done && (px_in_line != 12'hFFF))
                px_in_line <= px_in_line + 12'd1;

            if (href_fall) begin
                line_len_r  <= px_in_line;
                px_in_line  <= 12'd0;
                if (lines_in_fr != 12'hFFF)
                    lines_in_fr <= lines_in_fr + 12'd1;
            end

            if (frame_start) begin
                frame_lines_r  <= lines_in_fr;
                lines_in_fr    <= 12'd0;
                px_in_line     <= 12'd0;
                cam_vsync_seen <= 1'b1;
            end

            if (stat_clear)
                cam_vsync_seen <= 1'b0;
        end
    end

    assign cam_line_len    = line_len_r;
    assign cam_frame_lines = frame_lines_r;

endmodule
