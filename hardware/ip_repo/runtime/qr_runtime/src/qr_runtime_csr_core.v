`timescale 1ns / 1ps
/*
 * QR Runtime CSR core.
 *
 * IMPORTANT:
 *   This module contains only register semantics. It does NOT implement AXI.
 *   The final packaged IP should place a Vivado-generated AXI4-Lite slave
 *   shell in front of this core. Keeping the register contract here prevents
 *   AXI protocol logic and QR control logic from being mixed together.
 */
module qr_runtime_csr_core #(
    parameter integer ADDR_W = 6
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  wr_en,
    input  wire [ADDR_W-1:0]     wr_addr,
    input  wire [31:0]           wr_data,
    input  wire [3:0]            wr_strb,
    input  wire [ADDR_W-1:0]     rd_addr,
    output reg  [31:0]           rd_data,

    input wire processing_busy,
    input wire feature_start_ready,
    input wire frontend_frame_ready,
    input wire result_ready,
    input wire stream_busy,
    input wire packet_tx_done,
    input wire image_tx_done,
    input wire combined_error,
    input wire frame_stuck,
    input wire image_overflow_error,
    input wire frame_id_protocol_error,
    input wire frame_complete_pending,
    input wire [15:0] result_word_length,
    input wire [7:0] candidate_count,
    input wire [31:0] error_flags,
    input wire [31:0] active_frame_id,
    input wire [31:0] image_frame_id,
    input wire [15:0] frame_drop_count,
    input wire [5:0] fe_mode_applied,
    input wire [5:0] valid_margin,

    output reg enable,
    output reg image_capture_enable,
    output reg auto_start_enable,
    output reg manual_start_pulse,
    output reg soft_reset_pulse,
    output reg error_clear_pulse,
    output reg stream_start_pulse,
    output reg frame_ack_pulse,
    output reg [31:0] frame_id_seed,
    output reg frame_id_seed_write,
    output reg [31:0] irq_enable,
    output reg [31:0] irq_status,
    output wire irq
);
    localparam [5:0]
        A_CONTROL        = 6'h00,
        A_STATUS         = 6'h04,
        A_FRAME_ID       = 6'h08,
        A_RESULT_WORDS   = 6'h0c,
        A_CAND_COUNT     = 6'h10,
        A_ERROR_FLAGS    = 6'h14,
        A_IMAGE_BYTES    = 6'h18,
        A_IMAGE_FORMAT   = 6'h1c,
        A_FE_CONFIG      = 6'h20,
        A_IMAGE_SIZE     = 6'h24,
        A_IMAGE_STRIDE   = 6'h28,
        A_IRQ_STATUS     = 6'h2c,
        A_IRQ_ENABLE     = 6'h30,
        A_ACTIVE_ID      = 6'h34,
        A_DROP_COUNT     = 6'h38,
        A_IMAGE_FRAME_ID = 6'h3c;

    reg result_ready_d;
    reg frame_complete_pending_d;

    function [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strb;
        begin
            merge_wstrb = old_value;
            if (strb[0]) merge_wstrb[7:0]   = new_value[7:0];
            if (strb[1]) merge_wstrb[15:8]  = new_value[15:8];
            if (strb[2]) merge_wstrb[23:16] = new_value[23:16];
            if (strb[3]) merge_wstrb[31:24] = new_value[31:24];
        end
    endfunction

    function [31:0] strobe_mask;
        input [3:0] strb;
        begin
            strobe_mask = {
                {8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}
            };
        end
    endfunction

    /* Pulse bits read as zero; only persistent bits are visible. */
    wire [31:0] control_value = {
        24'd0,
        auto_start_enable,     // bit 7
        1'b0,                  // bit 6 FRAME_ACK is pulse-only
        image_capture_enable,  // bit 5
        4'd0,                  // bits 4:1 are pulse-only
        enable                 // bit 0
    };

    /* STATUS[12:0] follows the Frame-aligned contract. */
    wire [31:0] status_value = {
        19'd0,
        frame_complete_pending,
        frame_id_protocol_error,
        image_overflow_error,
        frame_stuck,
        image_tx_done,
        packet_tx_done,
        frontend_frame_ready,
        stream_busy,
        feature_start_ready,
        combined_error,
        irq,
        result_ready,
        processing_busy
    };

    assign irq = |(irq_status & irq_enable);

    always @(*) begin
        case (rd_addr)
            A_CONTROL:        rd_data = control_value;
            A_STATUS:         rd_data = status_value;
            A_FRAME_ID:       rd_data = frame_id_seed;
            A_RESULT_WORDS:   rd_data = {16'd0, result_word_length};
            A_CAND_COUNT:     rd_data = {24'd0, candidate_count};
            A_ERROR_FLAGS:    rd_data = error_flags;
            A_IMAGE_BYTES:    rd_data = 32'd307200;
            A_IMAGE_FORMAT:   rd_data = 32'd1;
            A_FE_CONFIG:      rd_data = {20'd0, valid_margin, fe_mode_applied};
            A_IMAGE_SIZE:     rd_data = {16'd480, 16'd640};
            A_IMAGE_STRIDE:   rd_data = 32'd640;
            A_IRQ_STATUS:     rd_data = irq_status;
            A_IRQ_ENABLE:     rd_data = irq_enable;
            A_ACTIVE_ID:      rd_data = active_frame_id;
            A_DROP_COUNT:     rd_data = {16'd0, frame_drop_count};
            A_IMAGE_FRAME_ID: rd_data = image_frame_id;
            default:          rd_data = 32'd0;
        endcase
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            /*
             * Frame-aligned persistent CONTROL reset value = 0xA1
             *   bit7 AUTO_START_ENABLE     = 1
             *   bit5 IMAGE_CAPTURE_ENABLE = 1
             *   bit0 ENABLE                = 1
             */
            enable <= 1'b1;
            image_capture_enable <= 1'b1;
            auto_start_enable <= 1'b1;
            manual_start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            error_clear_pulse <= 1'b0;
            stream_start_pulse <= 1'b0;
            frame_ack_pulse <= 1'b0;
            frame_id_seed <= 32'd0;
            frame_id_seed_write <= 1'b0;
            irq_enable <= 32'd0;
            irq_status <= 32'd0;
            result_ready_d <= 1'b0;
            frame_complete_pending_d <= 1'b0;
        end else begin
            manual_start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            error_clear_pulse <= 1'b0;
            stream_start_pulse <= 1'b0;
            frame_ack_pulse <= 1'b0;
            frame_id_seed_write <= 1'b0;

            result_ready_d <= result_ready;
            frame_complete_pending_d <= frame_complete_pending;

            if (wr_en) begin
                case (wr_addr)
                    A_CONTROL: begin
                        if (wr_strb[0]) begin
                            enable <= wr_data[0];
                            if (wr_data[1]) manual_start_pulse <= 1'b1;
                            if (wr_data[2]) soft_reset_pulse <= 1'b1;
                            if (wr_data[3]) error_clear_pulse <= 1'b1;
                            if (wr_data[4]) stream_start_pulse <= 1'b1;
                            image_capture_enable <= wr_data[5];
                            if (wr_data[6]) frame_ack_pulse <= 1'b1;
                            auto_start_enable <= wr_data[7];
                        end
                    end
                    A_FRAME_ID: begin
                        frame_id_seed <= merge_wstrb(frame_id_seed, wr_data, wr_strb);
                        frame_id_seed_write <= 1'b1;
                    end
                    A_IRQ_STATUS: begin
                        /* W1C, honoring byte strobes. */
                        irq_status <= irq_status & ~(wr_data & strobe_mask(wr_strb));
                    end
                    A_IRQ_ENABLE: begin
                        irq_enable <= merge_wstrb(irq_enable, wr_data, wr_strb);
                    end
                    default: begin end
                endcase
            end

            /* Event latches. Event set wins if clear and event coincide. */
            if (result_ready && !result_ready_d) irq_status[0] <= 1'b1;
            if (packet_tx_done)                 irq_status[1] <= 1'b1;
            if (image_tx_done)                  irq_status[2] <= 1'b1;
            if (combined_error)                 irq_status[3] <= 1'b1;
            if (frame_stuck)                    irq_status[4] <= 1'b1;
            if (image_overflow_error)           irq_status[5] <= 1'b1;
            if (frame_id_protocol_error)        irq_status[6] <= 1'b1;
            if (frame_complete_pending && !frame_complete_pending_d)
                                                irq_status[7] <= 1'b1;

            if (error_clear_pulse)
                irq_status[6:3] <= 4'd0;
        end
    end
endmodule
