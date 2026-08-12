`timescale 1ns / 1ps

/*
 * ============================================================================
 * Module : qr_frame_completion_ctrl
 *
 * Role
 *   - One accepted QR frame lifetime completion controller.
 *   - Latches Image AXI-stream completion and Result AXI-stream completion.
 *   - Holds FRAME_COMPLETE_PENDING until PS writes FRAME_ACK.
 *   - Generates one-cycle frame_complete only after FRAME_ACK.
 *
 * Exact-Sync frame lifetime
 *
 *   coordinated_start
 *          |
 *          +--> image_tx_done  ----+
 *          |                       |
 *          +--> result_tx_done ----+--> frame_complete_pending
 *                                            |
 *                                      PS FRAME_ACK
 *                                            |
 *                                            v
 *                                      frame_complete
 *                                            |
 *                                   frontend_frame_release
 *
 * Notes
 *   - image_tx_done / result_tx_done are expected to be one-cycle pulses
 *     generated after the final AXI4-Stream beat (TLAST && TVALID && TREADY).
 *   - stat_clear clears only the sticky protocol error. It does not destroy
 *     an in-flight frame.
 * ============================================================================
 */

module qr_frame_completion_ctrl (
    input  wire aclk,
    input  wire aresetn,

    // Start of one accepted processing lifetime.
    input  wire frame_start,

    // Stream completion pulses for the same active frame.
    input  wire image_tx_done,
    input  wire result_tx_done,

    // PS CONTROL[6] write-one pulse.
    input  wire frame_ack_pulse,

    // Sticky status/error clear.
    input  wire stat_clear,

    // Debug/status outputs.
    output reg  image_done_seen,
    output reg  result_done_seen,
    output reg  frame_complete_pending,

    // One-clock pulse. Connect to qr_frame_ctrl_runtime.final_processing_done.
    output reg  frame_complete,

    // Sticky protocol error.
    output reg  completion_protocol_error
);

    reg frame_active;

    wire image_done_now;
    wire result_done_now;
    wire both_done_now;

    assign image_done_now  = image_done_seen  | image_tx_done;
    assign result_done_now = result_done_seen | result_tx_done;
    assign both_done_now   = image_done_now & result_done_now;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            frame_active              <= 1'b0;
            image_done_seen           <= 1'b0;
            result_done_seen          <= 1'b0;
            frame_complete_pending    <= 1'b0;
            frame_complete            <= 1'b0;
            completion_protocol_error <= 1'b0;
        end
        else begin
            // Pulse output defaults low every cycle.
            frame_complete <= 1'b0;

            // -------------------------------------------------------------
            // New accepted frame processing lifetime
            // -------------------------------------------------------------
            if (frame_start) begin
                if (frame_active || frame_complete_pending) begin
                    completion_protocol_error <= 1'b1;
                end
                else begin
                    frame_active           <= 1'b1;
                    image_done_seen        <= 1'b0;
                    result_done_seen       <= 1'b0;
                    frame_complete_pending <= 1'b0;
                end
            end

            // -------------------------------------------------------------
            // Latch Image stream completion
            // -------------------------------------------------------------
            if (image_tx_done) begin
                if (!frame_active) begin
                    completion_protocol_error <= 1'b1;
                end
                else if (image_done_seen) begin
                    // Duplicate completion pulse for the same frame.
                    completion_protocol_error <= 1'b1;
                end
                else begin
                    image_done_seen <= 1'b1;
                end
            end

            // -------------------------------------------------------------
            // Latch Result stream completion
            // -------------------------------------------------------------
            if (result_tx_done) begin
                if (!frame_active) begin
                    completion_protocol_error <= 1'b1;
                end
                else if (result_done_seen) begin
                    // Duplicate completion pulse for the same frame.
                    completion_protocol_error <= 1'b1;
                end
                else begin
                    result_done_seen <= 1'b1;
                end
            end

            // -------------------------------------------------------------
            // Both streams have finished.
            // Keep the frontend frame held until PS explicitly ACKs.
            // -------------------------------------------------------------
            if (frame_active &&
                !frame_complete_pending &&
                both_done_now) begin
                frame_complete_pending <= 1'b1;
            end

            // -------------------------------------------------------------
            // PS frame acknowledgement
            // -------------------------------------------------------------
            if (frame_ack_pulse) begin
                if (!frame_active || !frame_complete_pending) begin
                    // ACK before both streams are safely completed.
                    completion_protocol_error <= 1'b1;
                end
                else begin
                    frame_complete         <= 1'b1;
                    frame_complete_pending <= 1'b0;
                    frame_active           <= 1'b0;
                    image_done_seen        <= 1'b0;
                    result_done_seen       <= 1'b0;
                end
            end

            // -------------------------------------------------------------
            // Sticky error clear only.
            // Do not clear frame lifetime state here.
            // -------------------------------------------------------------
            if (stat_clear) begin
                completion_protocol_error <= 1'b0;
            end
        end
    end

endmodule

