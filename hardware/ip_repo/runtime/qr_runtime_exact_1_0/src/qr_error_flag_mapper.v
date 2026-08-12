`timescale 1ns / 1ps
/*
 * QRP1 H4 error flag mapping.
 * Bits 31:16 remain zero in schema v1.
 */
module qr_error_flag_mapper (
    input  wire scan_vcc_error,
    input  wire candidate_overrun_error,
    input  wire candidate_drop_error,
    input  wire coordinate_error,
    input  wire arbiter_protocol_error,
    input  wire row_done_overrun_error,
    input  wire event_overflow_error,
    input  wire row_order_error,
    input  wire event_protocol_error,
    input  wire ccl_hit_overflow_error,
    input  wire ccl_label_overflow_error,
    input  wire ccl_protocol_error,
    input  wire property_overflow_error,
    input  wire property_protocol_error,
    input  wire candidate_buffer_overflow_error,
    input  wire packet_protocol_error,
    output wire [31:0] error_flags
);
    assign error_flags = {
        16'd0,
        packet_protocol_error,
        candidate_buffer_overflow_error,
        property_protocol_error,
        property_overflow_error,
        ccl_protocol_error,
        ccl_label_overflow_error,
        ccl_hit_overflow_error,
        event_protocol_error,
        row_order_error,
        event_overflow_error,
        row_done_overrun_error,
        arbiter_protocol_error,
        coordinate_error,
        candidate_drop_error,
        candidate_overrun_error,
        scan_vcc_error
    };
endmodule
