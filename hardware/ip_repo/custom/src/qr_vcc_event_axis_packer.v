`timescale 1ns / 1ps
/*
 * Direct valid-ready serializer for the Run-Length/VCC outputs.
 *
 * Event encoding in M_AXIS_EVENT_TDATA[20:0]:
 *   [20:19] 2'b00 HIT, 2'b01 ROW_DONE, 2'b10 FRAME_DONE
 *   [18:9]  X coordinate
 *   [8:0]   Y coordinate
 *
 * Priority:
 *   HIT > ROW_DONE > FRAME_DONE
 *
 * FRAME_DONE is transferred only after ROW_DONE(y=479) has completed.
 */
module qr_vcc_event_axis_packer (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire         start,

    input  wire         hit_valid,
    output wire         hit_ready,
    input  wire [9:0]   hit_x,
    input  wire [8:0]   hit_y,

    input  wire         row_done_valid,
    output wire         row_done_ready,
    input  wire [8:0]   row_done_y,

    input  wire         scan_done_valid,
    output wire         scan_done_ready,

    output wire [31:0]  m_axis_tdata,
    output wire [3:0]   m_axis_tkeep,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire         m_axis_tlast,

    output wire         active,
    output reg          processing_done,

    input  wire         error_clear,
    output reg          event_stability_error,
    output reg          row_order_error,
    output reg          protocol_error
);

    localparam [1:0] EVENT_HIT        = 2'b00;
    localparam [1:0] EVENT_ROW_DONE   = 2'b01;
    localparam [1:0] EVENT_FRAME_DONE = 2'b10;

    reg         active_q;
    reg [9:0]   expected_row;
    reg         last_row_seen;

    reg         blocked_valid;
    reg [1:0]   blocked_type;
    reg [18:0]  blocked_payload;

    wire selected_hit;
    wire selected_row;
    wire selected_done;
    wire multiple_inputs;

    wire [1:0] selected_type;
    wire [9:0] selected_x;
    wire [8:0] selected_y;
    wire [18:0] selected_payload;
    wire event_handshake;

    assign active = active_q;

    assign selected_hit =
        active_q && hit_valid;

    assign selected_row =
        active_q && !hit_valid && row_done_valid;

    assign selected_done =
        active_q && !hit_valid && !row_done_valid &&
        scan_done_valid && last_row_seen;

    assign multiple_inputs =
        (hit_valid && row_done_valid) ||
        (hit_valid && scan_done_valid) ||
        (row_done_valid && scan_done_valid);

    assign selected_type =
        selected_hit  ? EVENT_HIT :
        selected_row  ? EVENT_ROW_DONE :
                        EVENT_FRAME_DONE;

    assign selected_x =
        selected_hit ? hit_x : 10'd0;

    assign selected_y =
        selected_hit ? hit_y :
        selected_row ? row_done_y :
                       9'd479;

    assign selected_payload = {selected_x, selected_y};

    assign m_axis_tvalid =
        selected_hit || selected_row || selected_done;

    assign m_axis_tdata =
        {11'd0, selected_type, selected_x, selected_y};

    assign m_axis_tkeep = 4'hF;
    assign m_axis_tlast = selected_done;

    assign event_handshake =
        m_axis_tvalid && m_axis_tready;

    assign hit_ready =
        selected_hit && m_axis_tready;

    assign row_done_ready =
        selected_row && m_axis_tready;

    assign scan_done_ready =
        selected_done && m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            active_q              <= 1'b0;
            expected_row          <= 10'd0;
            last_row_seen         <= 1'b0;
            processing_done       <= 1'b0;
            blocked_valid         <= 1'b0;
            blocked_type          <= 2'd0;
            blocked_payload       <= 19'd0;
            event_stability_error <= 1'b0;
            row_order_error       <= 1'b0;
            protocol_error        <= 1'b0;
        end
        else begin
            processing_done <= 1'b0;

            if (error_clear) begin
                event_stability_error <= 1'b0;
                row_order_error       <= 1'b0;
                protocol_error        <= 1'b0;
            end

            if (!active_q) begin
                blocked_valid <= 1'b0;

                if (hit_valid || row_done_valid || scan_done_valid)
                    protocol_error <= 1'b1;

                if (start) begin
                    active_q      <= 1'b1;
                    expected_row  <= 10'd0;
                    last_row_seen <= 1'b0;
                end
            end
            else begin
                if (start)
                    protocol_error <= 1'b1;

                if (multiple_inputs)
                    protocol_error <= 1'b1;

                if (scan_done_valid && !last_row_seen)
                    protocol_error <= 1'b1;

                /*
                 * AXI valid must remain asserted and the payload must remain
                 * stable while TREADY is low.
                 */
                if (blocked_valid) begin
                    if (!m_axis_tvalid ||
                        (blocked_type != selected_type) ||
                        (blocked_payload != selected_payload)) begin
                        event_stability_error <= 1'b1;
                        blocked_valid <= 1'b0;
                    end
                    else if (event_handshake) begin
                        blocked_valid <= 1'b0;
                    end
                end
                else if (m_axis_tvalid && !m_axis_tready) begin
                    blocked_valid   <= 1'b1;
                    blocked_type    <= selected_type;
                    blocked_payload <= selected_payload;
                end

                if (hit_valid && hit_ready) begin
                    if ((hit_x >= 10'd640) || (hit_y >= 9'd480))
                        protocol_error <= 1'b1;
                end

                if (row_done_valid && row_done_ready) begin
                    if ({1'b0, row_done_y} != expected_row)
                        row_order_error <= 1'b1;

                    if (row_done_y == 9'd479) begin
                        expected_row  <= 10'd480;
                        last_row_seen <= 1'b1;
                    end
                    else begin
                        expected_row <= expected_row + 1'b1;
                    end
                end

                if (selected_done && event_handshake) begin
                    active_q        <= 1'b0;
                    processing_done <= 1'b1;
                    blocked_valid   <= 1'b0;
                end
            end
        end
    end

endmodule
