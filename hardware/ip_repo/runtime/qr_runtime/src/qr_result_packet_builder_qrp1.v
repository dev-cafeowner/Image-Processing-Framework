`timescale 1ns / 1ps
/*
 * QRP1 Result Packet Builder
 *
 * Contract source:
 *   PS qr_packet_build_v1()/qr_packet_parse_v1()
 *
 * Packet:
 *   H0 = 0x51525031 ("QRP1")
 *   H1 = {schema=1, header_words=5, candidate_words=5, packet_flags}
 *   H2 = frame_id[31:0]
 *   H3 = {packet_word_count[15:0], candidate_count[7:0], image_format[7:0]}
 *   H4 = error_flags[31:0]
 *
 * Candidate:
 *   C0 = {hit_count[18:0], flags[7:0], label[4:0]}
 *   C1 = {3'b0, min_y[8:0], max_x[9:0], min_x[9:0]}
 *   C2 = {23'b0, max_y[8:0]}
 *   C3 = {4'b0, sum_x[27:0]}
 *   C4 = {4'b0, sum_y[27:0]}
 */
module qr_result_packet_builder_qrp1 #(
    parameter integer MAX_RECORDS = 16,
    parameter [7:0]   PACKET_FLAGS = 8'h00
)(
    input  wire         aclk,
    input  wire         aresetn,

    input  wire         start,
    input  wire [31:0]  frame_id,
    input  wire [7:0]   image_format,

    input  wire         fatal_frame_error,
    input  wire [31:0]  upstream_error_flags,

    input  wire         property_valid,
    output wire         property_ready,
    input  wire [4:0]   property_label,
    input  wire [7:0]   property_flags,
    input  wire [9:0]   property_min_x,
    input  wire [9:0]   property_max_x,
    input  wire [8:0]   property_min_y,
    input  wire [8:0]   property_max_y,
    input  wire [18:0]  property_hit_count,
    input  wire [27:0]  property_sum_x,
    input  wire [27:0]  property_sum_y,

    input  wire         properties_done_valid,
    output wire         properties_done_ready,

    output wire         builder_busy,
    output wire         result_ready,
    output reg  [7:0]   candidate_count,
    output reg  [15:0]  result_word_length,
    output reg  [15:0]  result_byte_length,
    output reg  [31:0]  packet_error_flags,

    input  wire         stream_start,
    output wire         stream_busy,
    output wire [31:0]  m_axis_tdata,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready,
    output wire [3:0]   m_axis_tkeep,
    output wire         m_axis_tlast,

    output wire         stream_done_valid,
    input  wire         stream_done_ready,

    input  wire         error_clear,
    output reg          candidate_overflow_error,
    output reg          protocol_error
);

    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_COLLECT     = 3'd1;
    localparam [2:0] ST_READY       = 3'd2;
    localparam [2:0] ST_SEND_HEADER = 3'd3;
    localparam [2:0] ST_SEND_RECORD = 3'd4;
    localparam [2:0] ST_DONE        = 3'd5;

    reg [2:0] state;

    reg [31:0] record_word0_mem [0:MAX_RECORDS-1];
    reg [31:0] record_word1_mem [0:MAX_RECORDS-1];
    reg [31:0] record_word2_mem [0:MAX_RECORDS-1];
    reg [31:0] record_word3_mem [0:MAX_RECORDS-1];
    reg [31:0] record_word4_mem [0:MAX_RECORDS-1];

    reg [7:0] collect_count;
    reg       frame_overflow;
    reg       frame_protocol_error;
    reg       fatal_latched;
    reg [31:0] upstream_errors_latched;

    reg [31:0] frame_id_latched;
    reg [7:0]  image_format_latched;

    reg [2:0] header_index;
    reg [7:0] record_index;
    reg [2:0] record_word_index;

    reg [31:0] tdata_mux;
    reg        tlast_mux;

    integer i;

    wire property_fire;
    wire done_fire;
    wire stream_start_fire;
    wire axis_fire;
    wire stream_done_fire;

    wire collect_full;
    wire overflow_now;
    wire protocol_violation_now;
    wire [7:0] count_after_property;
    wire fatal_at_done;
    wire overflow_at_done;
    wire protocol_at_done;
    wire [31:0] errors_at_done;
    wire [7:0] packet_count_at_done;
    wire [15:0] packet_words_at_done;

    assign property_ready = (state == ST_COLLECT);
    assign properties_done_ready = (state == ST_COLLECT);

    assign builder_busy = (state != ST_IDLE);
    assign result_ready = (state == ST_READY);
    assign stream_busy = (state == ST_SEND_HEADER) || (state == ST_SEND_RECORD);

    assign m_axis_tdata = tdata_mux;
    assign m_axis_tvalid = stream_busy;
    assign m_axis_tkeep = 4'hF;
    assign m_axis_tlast = tlast_mux;

    assign stream_done_valid = (state == ST_DONE);

    assign property_fire = property_valid && property_ready;
    assign done_fire = properties_done_valid && properties_done_ready;
    assign stream_start_fire = stream_start && result_ready;
    assign axis_fire = m_axis_tvalid && m_axis_tready;
    assign stream_done_fire = stream_done_valid && stream_done_ready;

    assign collect_full = (collect_count >= MAX_RECORDS);
    assign overflow_now = property_fire && collect_full;

    assign protocol_violation_now =
        (start && (state != ST_IDLE)) ||
        (property_valid && (state != ST_COLLECT)) ||
        (properties_done_valid && (state != ST_COLLECT)) ||
        (stream_start && (state != ST_READY)) ||
        ((state == ST_COLLECT) &&
         (image_format_latched != 8'd1) &&
         (image_format_latched != 8'd2));

    assign count_after_property =
        (property_fire && !collect_full) ?
            (collect_count + 8'd1) :
            collect_count;

    assign fatal_at_done = fatal_latched | fatal_frame_error;
    assign overflow_at_done = frame_overflow | overflow_now;
    assign protocol_at_done =
        frame_protocol_error |
        protocol_violation_now |
        protocol_error;

    assign errors_at_done =
        upstream_errors_latched |
        upstream_error_flags |
        (overflow_at_done ? 32'h0000_4000 : 32'd0) |
        (protocol_at_done ? 32'h0000_8000 : 32'd0);

    assign packet_count_at_done =
        fatal_at_done ? 8'd0 : count_after_property;

    assign packet_words_at_done =
        16'd5 +
        ({8'd0, packet_count_at_done} << 2) +
        {8'd0, packet_count_at_done};

    always @(*) begin
        tdata_mux = 32'd0;
        tlast_mux = 1'b0;

        if (state == ST_SEND_HEADER) begin
            case (header_index)
                3'd0: tdata_mux = 32'h5152_5031;
                3'd1: tdata_mux = {8'd1, 8'd5, 8'd5, PACKET_FLAGS};
                3'd2: tdata_mux = frame_id_latched;
                3'd3: tdata_mux = {
                    result_word_length,
                    candidate_count,
                    image_format_latched
                };
                3'd4: begin
                    tdata_mux = packet_error_flags;
                    if (candidate_count == 0)
                        tlast_mux = 1'b1;
                end
                default: tdata_mux = 32'd0;
            endcase
        end
        else if (state == ST_SEND_RECORD) begin
            case (record_word_index)
                3'd0: tdata_mux = record_word0_mem[record_index];
                3'd1: tdata_mux = record_word1_mem[record_index];
                3'd2: tdata_mux = record_word2_mem[record_index];
                3'd3: tdata_mux = record_word3_mem[record_index];
                3'd4: begin
                    tdata_mux = record_word4_mem[record_index];
                    if (record_index == candidate_count - 8'd1)
                        tlast_mux = 1'b1;
                end
                default: tdata_mux = 32'd0;
            endcase
        end
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state <= ST_IDLE;
            collect_count <= 8'd0;
            candidate_count <= 8'd0;
            result_word_length <= 16'd0;
            result_byte_length <= 16'd0;
            packet_error_flags <= 32'd0;

            frame_overflow <= 1'b0;
            frame_protocol_error <= 1'b0;
            fatal_latched <= 1'b0;
            upstream_errors_latched <= 32'd0;

            frame_id_latched <= 32'd0;
            image_format_latched <= 8'd1;

            header_index <= 3'd0;
            record_index <= 8'd0;
            record_word_index <= 3'd0;

            candidate_overflow_error <= 1'b0;
            protocol_error <= 1'b0;

            for (i = 0; i < MAX_RECORDS; i = i + 1) begin
                record_word0_mem[i] <= 32'd0;
                record_word1_mem[i] <= 32'd0;
                record_word2_mem[i] <= 32'd0;
                record_word3_mem[i] <= 32'd0;
                record_word4_mem[i] <= 32'd0;
            end
        end
        else begin
            if (error_clear) begin
                candidate_overflow_error <= 1'b0;
                protocol_error <= 1'b0;
            end

            if (protocol_violation_now) begin
                protocol_error <= 1'b1;
                if (state == ST_COLLECT)
                    frame_protocol_error <= 1'b1;
            end

            if (state == ST_COLLECT) begin
                fatal_latched <= fatal_latched | fatal_frame_error;
                upstream_errors_latched <=
                    upstream_errors_latched | upstream_error_flags;
            end

            if (property_fire) begin
                if (!collect_full) begin
                    record_word0_mem[collect_count] <= {
                        property_hit_count,
                        property_flags,
                        property_label
                    };
                    record_word1_mem[collect_count] <= {
                        3'd0,
                        property_min_y,
                        property_max_x,
                        property_min_x
                    };
                    record_word2_mem[collect_count] <= {
                        23'd0,
                        property_max_y
                    };
                    record_word3_mem[collect_count] <= {
                        4'd0,
                        property_sum_x
                    };
                    record_word4_mem[collect_count] <= {
                        4'd0,
                        property_sum_y
                    };
                    collect_count <= collect_count + 8'd1;
                end
                else begin
                    frame_overflow <= 1'b1;
                    candidate_overflow_error <= 1'b1;
                end
            end

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        state <= ST_COLLECT;
                        collect_count <= 8'd0;
                        candidate_count <= 8'd0;
                        result_word_length <= 16'd0;
                        result_byte_length <= 16'd0;
                        packet_error_flags <= 32'd0;

                        frame_overflow <= 1'b0;
                        frame_protocol_error <= 1'b0;
                        fatal_latched <= fatal_frame_error;
                        upstream_errors_latched <= upstream_error_flags;

                        frame_id_latched <= frame_id;
                        image_format_latched <= image_format;

                        header_index <= 3'd0;
                        record_index <= 8'd0;
                        record_word_index <= 3'd0;
                    end
                end

                ST_COLLECT: begin
                    if (done_fire) begin
                        candidate_count <= packet_count_at_done;
                        result_word_length <= packet_words_at_done;
                        result_byte_length <= packet_words_at_done << 2;
                        packet_error_flags <= errors_at_done;
                        state <= ST_READY;
                    end
                end

                ST_READY: begin
                    if (stream_start_fire) begin
                        header_index <= 3'd0;
                        record_index <= 8'd0;
                        record_word_index <= 3'd0;
                        state <= ST_SEND_HEADER;
                    end
                end

                ST_SEND_HEADER: begin
                    if (axis_fire) begin
                        if (header_index == 3'd4) begin
                            if (candidate_count == 0) begin
                                state <= ST_DONE;
                            end
                            else begin
                                record_index <= 8'd0;
                                record_word_index <= 3'd0;
                                state <= ST_SEND_RECORD;
                            end
                        end
                        else begin
                            header_index <= header_index + 3'd1;
                        end
                    end
                end

                ST_SEND_RECORD: begin
                    if (axis_fire) begin
                        if (record_word_index == 3'd4) begin
                            if (record_index == candidate_count - 8'd1) begin
                                state <= ST_DONE;
                            end
                            else begin
                                record_index <= record_index + 8'd1;
                                record_word_index <= 3'd0;
                            end
                        end
                        else begin
                            record_word_index <= record_word_index + 3'd1;
                        end
                    end
                end

                ST_DONE: begin
                    if (stream_done_fire)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
