`timescale 1ns / 1ps

/*
 * ============================================================================
 * Module : qr_postprocess_runtime_core
 *
 * Pure functional QR runtime core.
 *
 * This module contains no AXI4-Lite register interface.
 * AXI4-Lite transport and CSR semantics are implemented outside this core
 * by qr_runtime_exact.
 *
 * Included here:
 *   - Frame ID control
 *   - One-shot frame start / release control
 *   - Coordinated IP2 + IP3 start
 *   - Event AXI4-Stream input
 *   - Sparse CCL / Object Properties / QRP1 packet generation
 *
 * Exact-Sync:
 *   final_processing_done is supplied from the outer exact-sync wrapper.
 *   In the final system it is driven by:
 *
 *      qr_frame_completion_ctrl.frame_complete
 *
 *   so frontend_frame_release occurs only after:
 *
 *      image_tx_done + result_tx_done + PS FRAME_ACK
 * ============================================================================
 */

module qr_postprocess_runtime_core #(
    parameter integer MAX_RECORDS           = 16,
    parameter integer EVENT_FIFO_DEPTH      = 32,
    parameter integer EVENT_FIFO_ADDR_WIDTH = 5,
    parameter integer FRAME_TIMEOUT_W       = 24
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // -------------------------------------------------------------------------
    // Control from CSR
    // -------------------------------------------------------------------------
    input  wire                 enable,
    input  wire                 auto_start_enable,
    input  wire                 manual_start_pulse,
    input  wire                 soft_reset_pulse,
    input  wire                 error_clear_pulse,
    input  wire                 stream_start_pulse,

    input  wire [31:0]          frame_id_seed,
    input  wire                 frame_id_seed_write,

    // Exact-sync completion from outer wrapper
    input  wire                 final_processing_done,
    // Accepted camera SOF from Gray8 tap
    input  wire                 frame_sof_accept,   

    // -------------------------------------------------------------------------
    // Event AXI4-Stream input
    // -------------------------------------------------------------------------
    input  wire [31:0]          s_axis_event_tdata,
    input  wire [3:0]           s_axis_event_tkeep,
    input  wire                 s_axis_event_tvalid,
    output wire                 s_axis_event_tready,
    input  wire                 s_axis_event_tlast,

    // -------------------------------------------------------------------------
    // QRP1 Result AXI4-Stream output
    // -------------------------------------------------------------------------
    output wire [31:0]          m_axis_result_tdata,
    output wire [3:0]           m_axis_result_tkeep,
    output wire                 m_axis_result_tvalid,
    input  wire                 m_axis_result_tready,
    output wire                 m_axis_result_tlast,

    // -------------------------------------------------------------------------
    // IP1 / frontend handshake
    // -------------------------------------------------------------------------
    input  wire                 frontend_frame_ready,
    input  wire [7:0]           frontend_valid_margin,

    output wire                 frontend_frame_release,
    output wire                 frontend_frame_stuck,
    output wire                 frontend_stat_clear,

    // -------------------------------------------------------------------------
    // IP2 handshake
    // -------------------------------------------------------------------------
    output wire                 ip2_start,
    input  wire                 ip2_start_ready,
    input  wire                 ip2_processing_busy,
    input  wire                 ip2_processing_done,
    output wire                 ip2_error_clear,

    input  wire                 ip2_scan_vcc_error,
    input  wire                 ip2_candidate_overrun_error,
    input  wire                 ip2_candidate_drop_error,
    input  wire                 ip2_coordinate_error,
    input  wire                 ip2_arbiter_protocol_error,
    input  wire                 ip2_row_done_overrun_error,
    input  wire                 ip2_event_stability_error,
    input  wire                 ip2_event_row_order_error,
    input  wire                 ip2_event_protocol_error,

    input  wire                 external_fatal_frame_error,

    // -------------------------------------------------------------------------
    // Runtime status to outer CSR / wrapper
    // -------------------------------------------------------------------------
    output wire                 feature_start_ready,

    output wire [31:0]          active_frame_id,
    output wire [31:0]          next_frame_id,

    output wire [31:0]          result_error_flags,
    output wire [15:0]          result_word_length,
    output wire [15:0]          result_byte_length,
    output wire [7:0]           candidate_count,

    output wire                 result_ready,
    output wire                 processing_busy,
    output wire                 postprocess_done,
    output wire                 result_tx_done,

    output wire                 frame_control_error,
    output wire                 frame_id_protocol_error,
    output wire                 system_error,

    output wire [8:0]           stored_hit_count,
    output wire [5:0]           allocated_label_count,
    output wire [18:0]          accumulated_hit_count,
    output wire [5:0]           qualified_property_count
);

    // =========================================================================
    // Core reset
    // =========================================================================

    wire core_aresetn;

    assign core_aresetn =
        aresetn &&
        !soft_reset_pulse;

    // =========================================================================
    // Frontend frame acceptance edge
    // =========================================================================

    reg  frontend_frame_ready_d;
    wire frontend_frame_ready_rise;

    assign frontend_frame_ready_rise =
        frontend_frame_ready &&
        !frontend_frame_ready_d;

    always @(posedge aclk or negedge core_aresetn) begin
        if (!core_aresetn)
            frontend_frame_ready_d <= 1'b0;
        else
            frontend_frame_ready_d <= frontend_frame_ready;
    end

    // =========================================================================
    // Internal runtime signals
    // =========================================================================

    wire frame_id_valid;

    wire post_start_ready;
    wire post_processing_busy;

    wire coordinated_start;
    wire pipeline_start_ready;
    wire frame_ctrl_start_ready;

    wire stream_busy;
    wire packet_tx_done;

    wire [31:0] packet_error_flags_wide;
    wire [31:0] core_error_flags;
    wire        core_system_error;

    wire ingress_protocol_error;
    wire ingress_row_order_error;
    wire ip2_completion_protocol_error;

    wire ccl_hit_overflow_error;
    wire ccl_label_overflow_error;
    wire ccl_protocol_error;
    wire property_overflow_error;
    wire property_protocol_error;
    wire candidate_overflow_error;
    wire packet_protocol_error;

    wire event_fifo_full_unused;
    wire event_fifo_empty_unused;
    wire ccl_busy_unused;
    wire properties_busy_unused;

    // =========================================================================
    // Coordinated start readiness
    // =========================================================================

    assign pipeline_start_ready =
        ip2_start_ready &&
        post_start_ready;

    assign feature_start_ready =
        frame_ctrl_start_ready;

    assign processing_busy =
        ip2_processing_busy ||
        post_processing_busy ||
        stream_busy;

    assign ip2_start =
        coordinated_start;

    assign frontend_stat_clear =
        error_clear_pulse;

    assign ip2_error_clear =
        error_clear_pulse;

    assign result_tx_done =
        packet_tx_done;

    // =========================================================================
    // Frame ID controller
    // =========================================================================

    qr_frame_id_control u_frame_id (
        .aclk                    (aclk),
        .aresetn                 (core_aresetn),

        .seed_write              (frame_id_seed_write),
        .seed_value              (frame_id_seed),

        .frame_sof_accept        (frame_sof_accept),
        .frame_release           (frontend_frame_release),

        .feature_start_accept    (coordinated_start),

        .error_clear             (error_clear_pulse),

        .next_frame_id           (next_frame_id),
        .active_frame_id         (active_frame_id),
        .active_valid            (frame_id_valid),
        .frame_id_protocol_error (frame_id_protocol_error)
    );

    // =========================================================================
    // Frame start / release controller
    // =========================================================================

    qr_frame_ctrl_runtime #(
        .TIMEOUT_W(FRAME_TIMEOUT_W)
    ) u_frame_ctrl (
        .aclk                   (aclk),
        .aresetn                (core_aresetn),

        .enable                 (enable),
        .auto_start_enable      (auto_start_enable),
        .manual_start_pulse     (manual_start_pulse),

        .frame_ready            (frontend_frame_ready),
        .frame_id_valid         (frame_id_valid),
        .pipeline_start_ready   (pipeline_start_ready),

        .frame_release          (frontend_frame_release),
        .start                  (coordinated_start),
        .start_ready            (frame_ctrl_start_ready),

        .processing_busy        (processing_busy),

        // Outer Exact-Sync wrapper drives this with frame_complete.
        .final_processing_done  (final_processing_done),

        .stat_clear             (error_clear_pulse),
        .stuck                  (frontend_frame_stuck),
        .control_protocol_error (frame_control_error)
    );

    // =========================================================================
    // QR postprocess / QRP1 core
    // =========================================================================

    qr_postprocess_axis_qrp1_core #(
        .MAX_RECORDS           (MAX_RECORDS),
        .EVENT_FIFO_DEPTH      (EVENT_FIFO_DEPTH),
        .EVENT_FIFO_ADDR_WIDTH (EVENT_FIFO_ADDR_WIDTH)
    ) u_postprocess (
        .aclk                         (aclk),
        .aresetn                      (core_aresetn),

        .start                        (coordinated_start),
        .start_ready                  (post_start_ready),
        .processing_busy              (post_processing_busy),
        .postprocess_done             (postprocess_done),

        .frame_id                     (active_frame_id),
        .image_format                 (8'd1),

        .s_axis_event_tdata           (s_axis_event_tdata),
        .s_axis_event_tkeep           (s_axis_event_tkeep),
        .s_axis_event_tvalid          (s_axis_event_tvalid),
        .s_axis_event_tready          (s_axis_event_tready),
        .s_axis_event_tlast           (s_axis_event_tlast),

        .ip2_processing_done          (ip2_processing_done),

        .ip2_scan_vcc_error           (ip2_scan_vcc_error),
        .ip2_candidate_overrun_error  (ip2_candidate_overrun_error),
        .ip2_candidate_drop_error     (ip2_candidate_drop_error),
        .ip2_coordinate_error         (ip2_coordinate_error),
        .ip2_arbiter_protocol_error   (ip2_arbiter_protocol_error),
        .ip2_row_done_overrun_error   (ip2_row_done_overrun_error),
        .ip2_event_stability_error    (ip2_event_stability_error),
        .ip2_event_row_order_error    (ip2_event_row_order_error),
        .ip2_event_protocol_error     (ip2_event_protocol_error),

        .external_fatal_frame_error   (external_fatal_frame_error),
        .error_clear                  (error_clear_pulse),

        .result_ready                 (result_ready),
        .candidate_count              (candidate_count),
        .result_word_length           (result_word_length),
        .result_byte_length           (result_byte_length),
        .packet_error_flags           (packet_error_flags_wide),

        .stream_start                 (stream_start_pulse),
        .stream_busy                  (stream_busy),

        .m_axis_result_tdata          (m_axis_result_tdata),
        .m_axis_result_tkeep          (m_axis_result_tkeep),
        .m_axis_result_tvalid         (m_axis_result_tvalid),
        .m_axis_result_tready         (m_axis_result_tready),
        .m_axis_result_tlast          (m_axis_result_tlast),

        .packet_tx_done               (packet_tx_done),

        .stored_hit_count             (stored_hit_count),
        .allocated_label_count        (allocated_label_count),
        .accumulated_hit_count        (accumulated_hit_count),
        .qualified_property_count     (qualified_property_count),

        .event_fifo_full              (event_fifo_full_unused),
        .event_fifo_empty             (event_fifo_empty_unused),
        .ccl_busy                     (ccl_busy_unused),
        .properties_busy              (properties_busy_unused),

        .ingress_protocol_error       (ingress_protocol_error),
        .ingress_row_order_error      (ingress_row_order_error),
        .ip2_completion_protocol_error(ip2_completion_protocol_error),

        .ccl_hit_overflow_error       (ccl_hit_overflow_error),
        .ccl_label_overflow_error     (ccl_label_overflow_error),
        .ccl_protocol_error           (ccl_protocol_error),
        .property_overflow_error      (property_overflow_error),
        .property_protocol_error      (property_protocol_error),
        .candidate_overflow_error     (candidate_overflow_error),
        .packet_protocol_error        (packet_protocol_error),

        .error_flags                  (core_error_flags),
        .combined_error               (core_system_error)
    );

    // =========================================================================
    // Error/status aggregation
    // =========================================================================

    assign result_error_flags =
        core_error_flags;

    assign system_error =
        core_system_error ||
        frame_control_error ||
        frame_id_protocol_error;

    // Keep frontend_valid_margin as a real core input because the outer CSR
    // reports it. The functional datapath itself does not consume the value.
    wire unused_frontend_margin;
    assign unused_frontend_margin = ^frontend_valid_margin;

endmodule
