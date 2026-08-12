`timescale 1ns / 1ps
/*
 * ============================================================================
 * Module : qr_postprocess_axis_qrp1_core
 *
 * Input
 *   IP2 Event AXI4-Stream:
 *     TDATA[20:19] Event Type
 *     TDATA[18:9]  X
 *     TDATA[8:0]   Y
 *     TKEEP        4'hF
 *     TLAST        FRAME_DONE only
 *
 * Processing
 *   Event FIFO -> Sparse CCL -> Object Properties -> QRP1 Packet Builder
 *
 * Event Type
 *   2'b00 HIT
 *   2'b01 ROW_DONE
 *   2'b10 FRAME_DONE
 * ============================================================================
 */
module qr_postprocess_axis_qrp1_core #(
    parameter integer MAX_RECORDS           = 16,
    parameter integer EVENT_FIFO_DEPTH      = 32,
    parameter integer EVENT_FIFO_ADDR_WIDTH = 5
)(
    input  wire         aclk,
    input  wire         aresetn,

    input  wire         start,
    output wire         start_ready,
    output wire         processing_busy,
    output reg          postprocess_done,

    input  wire [31:0]  frame_id,
    input  wire [7:0]   image_format,

    input  wire [31:0]  s_axis_event_tdata,
    input  wire [3:0]   s_axis_event_tkeep,
    input  wire         s_axis_event_tvalid,
    output wire         s_axis_event_tready,
    input  wire         s_axis_event_tlast,

    input  wire         ip2_processing_done,

    input  wire         ip2_scan_vcc_error,
    input  wire         ip2_candidate_overrun_error,
    input  wire         ip2_candidate_drop_error,
    input  wire         ip2_coordinate_error,
    input  wire         ip2_arbiter_protocol_error,
    input  wire         ip2_row_done_overrun_error,
    input  wire         ip2_event_stability_error,
    input  wire         ip2_event_row_order_error,
    input  wire         ip2_event_protocol_error,

    input  wire         external_fatal_frame_error,
    input  wire         error_clear,

    output wire         result_ready,
    output wire [7:0]   candidate_count,
    output wire [15:0]  result_word_length,
    output wire [15:0]  result_byte_length,
    output wire [31:0]  packet_error_flags,

    input  wire         stream_start,
    output wire         stream_busy,

    output wire [31:0]  m_axis_result_tdata,
    output wire [3:0]   m_axis_result_tkeep,
    output wire         m_axis_result_tvalid,
    input  wire         m_axis_result_tready,
    output wire         m_axis_result_tlast,

    output wire         packet_tx_done,

    output wire [8:0]   stored_hit_count,
    output wire [5:0]   allocated_label_count,
    output wire [18:0]  accumulated_hit_count,
    output wire [5:0]   qualified_property_count,

    output wire         event_fifo_full,
    output wire         event_fifo_empty,
    output wire         ccl_busy,
    output wire         properties_busy,

    output reg          ingress_protocol_error,
    output reg          ingress_row_order_error,
    output reg          ip2_completion_protocol_error,

    output wire         ccl_hit_overflow_error,
    output wire         ccl_label_overflow_error,
    output wire         ccl_protocol_error,
    output wire         property_overflow_error,
    output wire         property_protocol_error,
    output wire         candidate_overflow_error,
    output wire         packet_protocol_error,

    output wire [31:0]  error_flags,
    output wire         combined_error
);

    localparam [1:0] EVENT_HIT        = 2'b00;
    localparam [1:0] EVENT_ROW_DONE   = 2'b01;
    localparam [1:0] EVENT_FRAME_DONE = 2'b10;

    wire        fifo_s_valid;
    wire        fifo_s_ready;
    wire [20:0] fifo_s_data;

    wire        fifo_m_valid;
    wire        fifo_m_ready;
    wire [20:0] fifo_m_data;

    wire [1:0]  event_type;
    wire [9:0]  event_x;
    wire [8:0]  event_y;

    wire        labeled_hit_valid;
    wire        labeled_hit_ready;
    wire [9:0]  labeled_hit_x;
    wire [8:0]  labeled_hit_y;
    wire [4:0]  labeled_hit_label;
    wire        labeled_hit_last;

    wire        ccl_done_valid;
    wire        ccl_done_ready;

    wire        property_valid;
    wire        property_ready;
    wire [4:0]  property_label;
    wire [9:0]  property_min_x;
    wire [9:0]  property_max_x;
    wire [8:0]  property_min_y;
    wire [8:0]  property_max_y;
    wire [18:0] property_hit_count;
    wire [27:0] property_sum_x;
    wire [27:0] property_sum_y;

    wire        properties_done_valid;
    wire        properties_done_ready;

    wire        packet_builder_busy;
    wire        stream_done_valid;
    wire        stream_done_ready;

    reg         ingress_active;
    reg         frame_done_received;
    reg         last_row_seen;
    reg [9:0]   expected_row;
    reg         ip2_done_seen;

    reg         blocked_valid;
    reg [31:0]  blocked_tdata;
    reg [3:0]   blocked_tkeep;
    reg         blocked_tlast;

    reg         result_ready_d;

    wire        start_accept;
    wire        event_input_fire;
    wire        event_is_hit;
    wire        event_is_row;
    wire        event_is_frame;
    wire        event_type_valid;

    wire        combined_row_order_error;
    wire        combined_event_protocol_error;
    wire        fatal_frame_error;

    assign start_ready =
        !ingress_active &&
        event_fifo_empty &&
        !ccl_busy &&
        !properties_busy &&
        !packet_builder_busy;

    assign start_accept = start && start_ready;

    assign processing_busy =
        ingress_active ||
        !event_fifo_empty ||
        ccl_busy ||
        properties_busy ||
        packet_builder_busy;

    /*
     * Backpressure is propagated directly to IP2.
     * No event is accepted before start or after FRAME_DONE.
     */
    assign s_axis_event_tready =
        ingress_active &&
        !frame_done_received &&
        fifo_s_ready;

    assign event_input_fire =
        s_axis_event_tvalid &&
        s_axis_event_tready;

    assign fifo_s_valid = event_input_fire;
    assign fifo_s_data  = s_axis_event_tdata[20:0];

    assign event_is_hit =
        (s_axis_event_tdata[20:19] == EVENT_HIT);

    assign event_is_row =
        (s_axis_event_tdata[20:19] == EVENT_ROW_DONE);

    assign event_is_frame =
        (s_axis_event_tdata[20:19] == EVENT_FRAME_DONE);

    assign event_type_valid =
        event_is_hit || event_is_row || event_is_frame;

    assign event_type = fifo_m_data[20:19];
    assign event_x    = fifo_m_data[18:9];
    assign event_y    = fifo_m_data[8:0];

    wire ccl_event_ready;

    /*
     * The FIFO drains directly into Sparse CCL through valid-ready.
     */
    assign fifo_m_ready = ccl_event_ready;

    assign stream_done_ready = 1'b1;
    assign packet_tx_done =
        stream_done_valid && stream_done_ready;

    assign combined_row_order_error =
        ingress_row_order_error ||
        ip2_event_row_order_error;

    assign combined_event_protocol_error =
        ingress_protocol_error ||
        ip2_event_stability_error ||
        ip2_event_protocol_error ||
        ip2_completion_protocol_error;

    assign fatal_frame_error =
        external_fatal_frame_error ||
        ip2_scan_vcc_error ||
        ip2_candidate_overrun_error ||
        ip2_candidate_drop_error ||
        ip2_row_done_overrun_error ||
        ingress_protocol_error ||
        ingress_row_order_error ||
        ip2_event_stability_error ||
        ip2_event_row_order_error ||
        ip2_event_protocol_error ||
        ip2_completion_protocol_error;

    qr_event_fifo #(
        .DATA_WIDTH (21),
        .DEPTH      (EVENT_FIFO_DEPTH),
        .ADDR_WIDTH (EVENT_FIFO_ADDR_WIDTH)
    ) u_event_fifo (
        .aclk    (aclk),
        .aresetn (aresetn),

        .s_valid (fifo_s_valid),
        .s_ready (fifo_s_ready),
        .s_data  (fifo_s_data),

        .m_valid (fifo_m_valid),
        .m_ready (fifo_m_ready),
        .m_data  (fifo_m_data),

        .full    (event_fifo_full),
        .empty   (event_fifo_empty)
    );

    qr_sparse_ccl #(
        .MAX_HITS          (256),
        .HIT_ADDR_WIDTH    (8),
        .HIT_COUNT_WIDTH   (9),
        .MAX_LABELS        (32),
        .LABEL_WIDTH       (5),
        .LABEL_COUNT_WIDTH (6),
        .X_LINK_THRESHOLD  (10'd4),
        .Y_LINK_THRESHOLD  (9'd2)
    ) u_sparse_ccl (
        .aclk                  (aclk),
        .aresetn               (aresetn),
        .start                 (start_accept),

        .event_valid           (fifo_m_valid),
        .event_ready           (ccl_event_ready),
        .event_type            (event_type),
        .event_x               (event_x),
        .event_y               (event_y),

        .labeled_hit_valid     (labeled_hit_valid),
        .labeled_hit_ready     (labeled_hit_ready),
        .labeled_hit_x         (labeled_hit_x),
        .labeled_hit_y         (labeled_hit_y),
        .labeled_hit_label     (labeled_hit_label),
        .labeled_hit_last      (labeled_hit_last),

        .ccl_done_valid        (ccl_done_valid),
        .ccl_done_ready        (ccl_done_ready),

        .ccl_busy              (ccl_busy),
        .stored_hit_count      (stored_hit_count),
        .allocated_label_count (allocated_label_count),

        .error_clear           (error_clear),
        .hit_overflow_error    (ccl_hit_overflow_error),
        .label_overflow_error  (ccl_label_overflow_error),
        .protocol_error        (ccl_protocol_error)
    );

    qr_object_properties #(
        .MAX_HITS             (256),
        .HIT_COUNT_WIDTH      (19),
        .MAX_LABELS           (32),
        .LABEL_WIDTH          (5),
        .LABEL_ADDR_WIDTH     (5),
        .LABEL_COUNT_WIDTH    (6),
        .SUM_X_WIDTH          (28),
        .SUM_Y_WIDTH          (28),
        .MIN_RECORD_HITS      (3)
    ) u_object_properties (
        .aclk                        (aclk),
        .aresetn                     (aresetn),
        .start                       (start_accept),

        .labeled_hit_valid           (labeled_hit_valid),
        .labeled_hit_ready           (labeled_hit_ready),
        .labeled_hit_x               (labeled_hit_x),
        .labeled_hit_y               (labeled_hit_y),
        .labeled_hit_label           (labeled_hit_label),
        .labeled_hit_last            (labeled_hit_last),

        .ccl_done_valid              (ccl_done_valid),
        .ccl_done_ready              (ccl_done_ready),

        .property_valid              (property_valid),
        .property_ready              (property_ready),
        .property_label              (property_label),
        .property_min_x              (property_min_x),
        .property_max_x              (property_max_x),
        .property_min_y              (property_min_y),
        .property_max_y              (property_max_y),
        .property_hit_count          (property_hit_count),
        .property_sum_x              (property_sum_x),
        .property_sum_y              (property_sum_y),

        .properties_done_valid       (properties_done_valid),
        .properties_done_ready       (properties_done_ready),

        .properties_busy             (properties_busy),
        .accumulated_hit_count       (accumulated_hit_count),
        .qualified_property_count    (qualified_property_count),

        .error_clear                 (error_clear),
        .accumulation_overflow_error (property_overflow_error),
        .protocol_error              (property_protocol_error)
    );

    qr_result_packet_builder_qrp1 #(
        .MAX_RECORDS (MAX_RECORDS),
        .PACKET_FLAGS(8'h00)
    ) u_packet_builder (
        .aclk                     (aclk),
        .aresetn                  (aresetn),

        .start                    (start_accept),
        .frame_id                 (frame_id),
        .image_format             (image_format),

        .fatal_frame_error        (fatal_frame_error),
        .upstream_error_flags     (error_flags),

        .property_valid           (property_valid),
        .property_ready           (property_ready),
        .property_label           (property_label),
        .property_flags           (8'h00),
        .property_min_x           (property_min_x),
        .property_max_x           (property_max_x),
        .property_min_y           (property_min_y),
        .property_max_y           (property_max_y),
        .property_hit_count       (property_hit_count),
        .property_sum_x           (property_sum_x),
        .property_sum_y           (property_sum_y),

        .properties_done_valid    (properties_done_valid),
        .properties_done_ready    (properties_done_ready),

        .builder_busy             (packet_builder_busy),
        .result_ready             (result_ready),
        .candidate_count          (candidate_count),
        .result_word_length       (result_word_length),
        .result_byte_length       (result_byte_length),
        .packet_error_flags       (packet_error_flags),

        .stream_start             (stream_start),
        .stream_busy              (stream_busy),
        .m_axis_tdata             (m_axis_result_tdata),
        .m_axis_tvalid            (m_axis_result_tvalid),
        .m_axis_tready            (m_axis_result_tready),
        .m_axis_tkeep             (m_axis_result_tkeep),
        .m_axis_tlast             (m_axis_result_tlast),

        .stream_done_valid        (stream_done_valid),
        .stream_done_ready        (stream_done_ready),

        .error_clear              (error_clear),
        .candidate_overflow_error (candidate_overflow_error),
        .protocol_error           (packet_protocol_error)
    );

    qr_error_flag_mapper u_error_mapper (
        .scan_vcc_error                  (ip2_scan_vcc_error),
        .candidate_overrun_error         (ip2_candidate_overrun_error),
        .candidate_drop_error            (ip2_candidate_drop_error),
        .coordinate_error                (ip2_coordinate_error),
        .arbiter_protocol_error          (ip2_arbiter_protocol_error),
        .row_done_overrun_error          (ip2_row_done_overrun_error),

        /*
         * A compliant valid-ready source cannot overflow this FIFO because
         * TREADY is deasserted when it is full.
         */
        .event_overflow_error            (1'b0),
        .row_order_error                 (combined_row_order_error),
        .event_protocol_error            (combined_event_protocol_error),

        .ccl_hit_overflow_error          (ccl_hit_overflow_error),
        .ccl_label_overflow_error        (ccl_label_overflow_error),
        .ccl_protocol_error              (ccl_protocol_error),

        .property_overflow_error         (property_overflow_error),
        .property_protocol_error         (property_protocol_error),

        .candidate_buffer_overflow_error (candidate_overflow_error),
        .packet_protocol_error           (packet_protocol_error),

        .error_flags                     (error_flags)
    );

    assign combined_error =
        external_fatal_frame_error ||
        (|error_flags);

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ingress_active               <= 1'b0;
            frame_done_received          <= 1'b0;
            last_row_seen                <= 1'b0;
            expected_row                 <= 10'd0;
            ip2_done_seen                <= 1'b0;

            blocked_valid                <= 1'b0;
            blocked_tdata                <= 32'd0;
            blocked_tkeep                <= 4'd0;
            blocked_tlast                <= 1'b0;

            ingress_protocol_error       <= 1'b0;
            ingress_row_order_error      <= 1'b0;
            ip2_completion_protocol_error<= 1'b0;

            result_ready_d               <= 1'b0;
            postprocess_done             <= 1'b0;
        end
        else begin
            result_ready_d   <= result_ready;
            postprocess_done <= result_ready && !result_ready_d;

            if (error_clear) begin
                ingress_protocol_error        <= 1'b0;
                ingress_row_order_error       <= 1'b0;
                ip2_completion_protocol_error <= 1'b0;
            end

            if (start_accept) begin
                ingress_active      <= 1'b1;
                frame_done_received <= 1'b0;
                last_row_seen       <= 1'b0;
                expected_row        <= 10'd0;
                ip2_done_seen       <= 1'b0;
                blocked_valid       <= 1'b0;
            end
            else if (start && !start_ready) begin
                ingress_protocol_error <= 1'b1;
            end

            if (ip2_processing_done) begin
                if (!ingress_active || ip2_done_seen)
                    ip2_completion_protocol_error <= 1'b1;
                else
                    ip2_done_seen <= 1'b1;
            end

            /*
             * AXI payload stability during downstream backpressure.
             */
            if (blocked_valid) begin
                if (!s_axis_event_tvalid ||
                    (s_axis_event_tdata != blocked_tdata) ||
                    (s_axis_event_tkeep != blocked_tkeep) ||
                    (s_axis_event_tlast != blocked_tlast)) begin
                    ingress_protocol_error <= 1'b1;
                    blocked_valid <= 1'b0;
                end
                else if (s_axis_event_tready) begin
                    blocked_valid <= 1'b0;
                end
            end
            else if (s_axis_event_tvalid &&
                     !s_axis_event_tready &&
                     ingress_active &&
                     !frame_done_received) begin
                blocked_valid <= 1'b1;
                blocked_tdata <= s_axis_event_tdata;
                blocked_tkeep <= s_axis_event_tkeep;
                blocked_tlast <= s_axis_event_tlast;
            end

            if (s_axis_event_tvalid &&
                (!ingress_active || frame_done_received)) begin
                ingress_protocol_error <= 1'b1;
            end

            if (event_input_fire) begin
                if (s_axis_event_tkeep != 4'hF)
                    ingress_protocol_error <= 1'b1;

                if (s_axis_event_tdata[31:21] != 11'd0)
                    ingress_protocol_error <= 1'b1;

                if (!event_type_valid)
                    ingress_protocol_error <= 1'b1;

                if (event_is_hit) begin
                    if (s_axis_event_tlast)
                        ingress_protocol_error <= 1'b1;

                    if ((s_axis_event_tdata[18:9] >= 10'd640) ||
                        (s_axis_event_tdata[8:0] >= 9'd480))
                        ingress_protocol_error <= 1'b1;
                end
                else if (event_is_row) begin
                    if (s_axis_event_tlast)
                        ingress_protocol_error <= 1'b1;

                    if (s_axis_event_tdata[18:9] != 10'd0)
                        ingress_protocol_error <= 1'b1;

                    if ({1'b0, s_axis_event_tdata[8:0]} != expected_row)
                        ingress_row_order_error <= 1'b1;

                    if (s_axis_event_tdata[8:0] == 9'd479) begin
                        expected_row  <= 10'd480;
                        last_row_seen <= 1'b1;
                    end
                    else begin
                        expected_row <= expected_row + 1'b1;
                    end
                end
                else if (event_is_frame) begin
                    if (!s_axis_event_tlast)
                        ingress_protocol_error <= 1'b1;

                    if ((s_axis_event_tdata[18:9] != 10'd0) ||
                        (s_axis_event_tdata[8:0] != 9'd479))
                        ingress_protocol_error <= 1'b1;

                    if (!last_row_seen)
                        ingress_row_order_error <= 1'b1;

                    frame_done_received <= 1'b1;
                end
            end

            /*
             * The IP2 completion pulse follows the accepted FRAME_DONE event.
             * It must be observed before the result packet becomes ready.
             */
            if (result_ready && !result_ready_d && !ip2_done_seen)
                ip2_completion_protocol_error <= 1'b1;

            if (packet_tx_done) begin
                ingress_active      <= 1'b0;
                frame_done_received <= 1'b0;
                blocked_valid       <= 1'b0;
            end
        end
    end

endmodule
