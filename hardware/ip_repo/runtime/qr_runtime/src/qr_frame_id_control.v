`timescale 1ns / 1ps

module qr_frame_id_control (
    input  wire         aclk,
    input  wire         aresetn,

    input  wire         seed_write,
    input  wire [31:0]  seed_value,

    input  wire         frame_sof_accept,
    input  wire         frame_release,

    input  wire         feature_start_accept,

    input  wire         error_clear,

    output reg  [31:0]  next_frame_id,
    output reg  [31:0]  active_frame_id,
    output reg          active_valid,
    output reg          frame_id_protocol_error
);

    wire [31:0] id_for_new_frame =
        seed_write ? seed_value : next_frame_id;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            next_frame_id <= 32'd0;
            active_frame_id <= 32'd0;
            active_valid <= 1'b0;
            frame_id_protocol_error <= 1'b0;
        end
        else begin
            if (error_clear)
                frame_id_protocol_error <= 1'b0;

            if (seed_write) begin
                if (active_valid)
                    frame_id_protocol_error <= 1'b1;
                else
                    next_frame_id <= seed_value;
            end

            if (frame_sof_accept) begin
                if (active_valid) begin
                    frame_id_protocol_error <= 1'b1;
                end
                else begin
                    active_frame_id <= id_for_new_frame;
                    next_frame_id <= id_for_new_frame + 32'd1;
                    active_valid <= 1'b1;
                end
            end

            if (feature_start_accept && !active_valid)
                frame_id_protocol_error <= 1'b1;

            if (frame_release)
                active_valid <= 1'b0;
        end
    end

endmodule