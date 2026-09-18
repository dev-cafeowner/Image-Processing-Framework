`timescale 1ns / 1ps
/*
 * Frame-ready level to one-shot feature start, with optional PS manual start.
 * frame_release is generated only after full frame completion (image + result).
 */
module qr_frame_ctrl_runtime #(
    parameter integer TIMEOUT_W = 24
)(
    input  wire aclk,
    input  wire aresetn,

    input  wire enable,
    input  wire auto_start_enable,
    input  wire manual_start_pulse,

    /*
     * frame_ready is the raw frontend frame-held level.
     * pipeline_start_ready is the combined IP2/IP3 readiness.
     *
     * Keeping these signals separate prevents the controller from re-arming
     * merely because a downstream processing block becomes busy.
     */
    input  wire frame_ready,
    input  wire frame_id_valid,
    input  wire pipeline_start_ready,

    output reg  frame_release,
    output reg  start,
    output wire start_ready,

    input  wire processing_busy,
    input  wire final_processing_done,

    input  wire stat_clear,
    output reg  stuck,
    output reg  control_protocol_error
);
    reg launched;
    reg armed;
    reg manual_pending;
    reg [TIMEOUT_W-1:0] watchdog;

    wire request_present = auto_start_enable | manual_pending;
    wire can_start =
        enable &&
        frame_ready &&
        frame_id_valid &&
        pipeline_start_ready &&
        armed &&
        !processing_busy &&
        !launched &&
        request_present;

    assign start_ready =
        enable &&
        frame_ready &&
        frame_id_valid &&
        pipeline_start_ready &&
        armed &&
        !processing_busy &&
        !launched;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            frame_release <= 1'b0;
            start <= 1'b0;
            launched <= 1'b0;
            armed <= 1'b1;
            manual_pending <= 1'b0;
            watchdog <= {TIMEOUT_W{1'b0}};
            stuck <= 1'b0;
            control_protocol_error <= 1'b0;
        end
        else begin
            frame_release <= 1'b0;
            start <= 1'b0;

            if (!frame_ready)
                armed <= 1'b1;

            if (manual_start_pulse) begin
                if (manual_pending || launched)
                    control_protocol_error <= 1'b1;
                else
                    manual_pending <= 1'b1;
            end

            if (can_start) begin
                start <= 1'b1;
                launched <= 1'b1;
                armed <= 1'b0;
                manual_pending <= 1'b0;
                watchdog <= {TIMEOUT_W{1'b0}};
            end

            if (final_processing_done) begin
                if (!launched)
                    control_protocol_error <= 1'b1;

                launched <= 1'b0;
                frame_release <= 1'b1;
                watchdog <= {TIMEOUT_W{1'b0}};
            end
            else if (launched) begin
                if (&watchdog)
                    stuck <= 1'b1;
                else
                    watchdog <= watchdog + {{(TIMEOUT_W-1){1'b0}}, 1'b1};
            end

            if (stat_clear) begin
                stuck <= 1'b0;
                control_protocol_error <= 1'b0;
                watchdog <= {TIMEOUT_W{1'b0}};
            end
        end
    end
endmodule
