`timescale 1ns/1ps
// Sensor-specific clock boundary. Every PCLK carries one {VS,HREF,byte}
// token, including blanking. Parsing/status stay in the common AXI domain.
// No multi-bit camera bus is independently synchronized/oversampled.
module ov7670_pclk_rx #(
    parameter integer FIFO_DEPTH = 4096,
    parameter integer EXPECTED_WIDTH = 640
)(
    input wire aclk, aresetn, pclk,
    input wire cam_href, cam_vsync,
    input wire [7:0] cam_data,
    input wire capture_en, stat_clear,
    output wire clear_busy,
    output reg [15:0] m_axis_tdata,
    output reg m_axis_tvalid, m_axis_tuser, m_axis_tlast,
    input wire m_axis_tready,
    output wire [31:0] cam_status, fifo_status,
    output wire [31:0] pclk_count, lost_tokens,
    output reg [31:0] frame_count, pixel_count, bad_lines,
    output reg [31:0] frame_period, frame_period_max
);
    localparam CW = $clog2(FIFO_DEPTH)+1;
    wire prst;
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.INIT_SYNC_FF(0),.RST_ACTIVE_HIGH(1))
        reset_pclk (.src_arst(!aresetn),.dest_clk(pclk),.dest_arst(prst));

    // The only input registers. Data changes at sensor PCLK falling edge.
    // No reset is needed: FIFO reset keeps these initial samples invisible.
    (* IOB="TRUE" *) reg [9:0] pin_sample;
    always @(posedge pclk) pin_sample <= {cam_vsync,cam_href,cam_data};

    reg clear_toggle=0;
    wire clear_p, clear_ack;
    reg clear_seen=0;
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1))
        clear_to_p (.src_clk(aclk),.src_in(clear_toggle),.dest_clk(pclk),.dest_out(clear_p));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1))
        clear_to_a (.src_clk(pclk),.src_in(clear_seen),.dest_clk(aclk),.dest_out(clear_ack));
    assign clear_busy = clear_toggle != clear_ack;
    always @(posedge aclk) begin
        if (!aresetn) clear_toggle <= 0;
        else if (stat_clear && !clear_busy) clear_toggle <= ~clear_toggle;
    end

    wire full, empty, wr_busy, rd_busy;
    wire [9:0] token;
    wire [CW-1:0] rd_count;
    wire take = !empty && !rd_busy && (!m_axis_tvalid || m_axis_tready || !capture_en);
    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("block"),.FIFO_WRITE_DEPTH(FIFO_DEPTH),
        .WRITE_DATA_WIDTH(10),.READ_DATA_WIDTH(10),.READ_MODE("fwft"),
        .FIFO_READ_LATENCY(0),.CDC_SYNC_STAGES(3),.RELATED_CLOCKS(0),
        .WR_DATA_COUNT_WIDTH(CW),.RD_DATA_COUNT_WIDTH(CW),
        .USE_ADV_FEATURES("0400"),.SIM_ASSERT_CHK(1)
    ) tokens (
        .rst(prst),.sleep(1'b0),.wr_clk(pclk),.wr_en(!wr_busy && !prst && !full),
        .din(pin_sample),.full(full),.wr_rst_busy(wr_busy),
        .rd_clk(aclk),.rd_en(take),.dout(token),.empty(empty),.rd_rst_busy(rd_busy),
        .rd_data_count(rd_count),.injectsbiterr(1'b0),.injectdbiterr(1'b0)
    );

    reg [31:0] p_ticks=0, p_lost=0;
    reg overflow_p=0;
    wire overflow_a, full_a;
    always @(posedge pclk) begin
        if (prst) begin
            p_ticks<=0; p_lost<=0; overflow_p<=0; clear_seen<=0;
        end else begin
            p_ticks<=p_ticks+1;
            if (clear_p != clear_seen) begin
                clear_seen<=clear_p;
                overflow_p<=0;
            end
            // Lost-token count is monotonic until PL reset, not a sticky flag.
            if (!wr_busy && full) begin p_lost<=p_lost+1; overflow_p<=1; end
        end
    end
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(3),.INIT_SYNC_FF(1),.REG_OUTPUT(1))
        pclk_counter (.src_clk(pclk),.src_in_bin(p_ticks),.dest_clk(aclk),.dest_out_bin(pclk_count));
    xpm_cdc_gray #(.WIDTH(32),.DEST_SYNC_FF(3),.INIT_SYNC_FF(1),.REG_OUTPUT(1))
        lost_counter (.src_clk(pclk),.src_in_bin(p_lost),.dest_clk(aclk),.dest_out_bin(lost_tokens));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1))
        overflow_sync (.src_clk(pclk),.src_in(overflow_p),.dest_clk(aclk),.dest_out(overflow_a));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(1),.INIT_SYNC_FF(1))
        full_sync (.src_clk(pclk),.src_in(full),.dest_clk(aclk),.dest_out(full_a));

    reg href_d, vsync_d, byte_phase, sof_pending, emitting, seen_vsync;
    reg [7:0] hi_byte;
    reg [15:0] pending_pixel;
    reg pending_valid, pending_sof;
    reg [11:0] line_pixels, frame_lines, last_width, last_height;
    reg [15:0] peak_level;
    reg [31:0] ticks, last_frame_tick;
    reg have_frame;
    wire href=token[8], vsync=token[9];
    assign cam_status={6'd0,seen_vsync,overflow_a,last_height,last_width};
    assign fifo_status={peak_level,15'd0,full_a};

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata<=0; m_axis_tvalid<=0; m_axis_tuser<=0; m_axis_tlast<=0;
            href_d<=0; vsync_d<=0; byte_phase<=0; sof_pending<=0; emitting<=0;
            seen_vsync<=0; hi_byte<=0; pending_pixel<=0; pending_valid<=0; pending_sof<=0;
            line_pixels<=0; frame_lines<=0; last_width<=0; last_height<=0;
            peak_level<=0; ticks<=0; last_frame_tick<=0; have_frame<=0;
            frame_period<=0; frame_period_max<=0; frame_count<=0; pixel_count<=0; bad_lines<=0;
        end else begin
            ticks<=ticks+1;
            if (rd_count>peak_level) peak_level<=rd_count;
            if (m_axis_tvalid && m_axis_tready) m_axis_tvalid<=0;
            if (!capture_en) begin emitting<=0; m_axis_tvalid<=0; end
            if (stat_clear) begin
                peak_level<=0; seen_vsync<=0; bad_lines<=0;
                frame_period_max<=0; have_frame<=0;
            end
            if (take) begin
                href_d<=href; vsync_d<=vsync;
                if (!vsync && vsync_d) begin
                    frame_count<=frame_count+1;
                    last_height<=frame_lines; frame_lines<=0; line_pixels<=0;
                    seen_vsync<=1; sof_pending<=1; pending_valid<=0; byte_phase<=0;
                    emitting<=capture_en;
                    if (have_frame) begin
                        frame_period<=ticks-last_frame_tick;
                        if (ticks-last_frame_tick>frame_period_max) frame_period_max<=ticks-last_frame_tick;
                    end
                    last_frame_tick<=ticks; have_frame<=1;
                end else if (href && !vsync) begin
                    // First HREF-high token contains the first byte, not a preamble.
                    if (!href_d || !byte_phase) begin hi_byte<=token[7:0]; byte_phase<=1; end
                    else begin
                        byte_phase<=0;
                        if (line_pixels!=4095) line_pixels<=line_pixels+1;
                        pixel_count<=pixel_count+1;
                        if (pending_valid && emitting && capture_en) begin
                            m_axis_tdata<=pending_pixel; m_axis_tuser<=pending_sof;
                            m_axis_tlast<=0; m_axis_tvalid<=1;
                        end
                        pending_pixel<={hi_byte,token[7:0]}; pending_valid<=1;
                        pending_sof<=sof_pending; sof_pending<=0;
                    end
                end else if (!href && href_d) begin
                    last_width<=line_pixels; line_pixels<=0;
                    if (frame_lines!=4095) frame_lines<=frame_lines+1;
                    if (byte_phase || line_pixels!=EXPECTED_WIDTH) bad_lines<=bad_lines+1;
                    byte_phase<=0;
                    if (pending_valid && emitting && capture_en) begin
                        m_axis_tdata<=pending_pixel; m_axis_tuser<=pending_sof;
                        m_axis_tlast<=1; m_axis_tvalid<=1;
                    end
                    pending_valid<=0;
                end
            end
        end
    end
endmodule
