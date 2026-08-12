`timescale 1ns / 1ps
/*
 * QR PL control/status AXI4-Lite slave.
 *
 * Address map:
 * 0x00 CONTROL
 * 0x04 STATUS
 * 0x08 FRAME_ID seed
 * 0x0C RESULT_WORDS
 * 0x10 CANDIDATE_COUNT
 * 0x14 ERROR_FLAGS
 * 0x18 IMAGE_BYTES
 * 0x1C IMAGE_FORMAT
 * 0x20 FE_CONFIG
 * 0x24 IMAGE_SIZE
 * 0x28 IMAGE_STRIDE
 * 0x2C IRQ_STATUS (W1C)
 * 0x30 IRQ_ENABLE
 * 0x34 ACTIVE_FRAME_ID
 * 0x38 FRAME_DROP_COUNT
 */
module qr_pl_control_axi_lite #(
    parameter integer ADDR_W = 6
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    input  wire [ADDR_W-1:0]    s_axi_awaddr,
    input  wire                 s_axi_awvalid,
    output wire                 s_axi_awready,

    input  wire [31:0]          s_axi_wdata,
    input  wire [3:0]           s_axi_wstrb,
    input  wire                 s_axi_wvalid,
    output wire                 s_axi_wready,

    output wire [1:0]           s_axi_bresp,
    output reg                  s_axi_bvalid,
    input  wire                 s_axi_bready,

    input  wire [ADDR_W-1:0]    s_axi_araddr,
    input  wire                 s_axi_arvalid,
    output wire                 s_axi_arready,

    output reg  [31:0]          s_axi_rdata,
    output wire [1:0]           s_axi_rresp,
    output reg                  s_axi_rvalid,
    input  wire                 s_axi_rready,

    input  wire                 processing_busy,
    input  wire                 feature_start_ready,
    input  wire                 frontend_frame_ready,
    input  wire                 result_ready,
    input  wire                 stream_busy,
    input  wire                 packet_tx_done,
    input  wire                 image_tx_done,
    input  wire                 combined_error,
    input  wire                 frame_stuck,
    input  wire                 image_overflow_error,
    input  wire                 frame_id_protocol_error,

    input  wire [15:0]          result_word_length,
    input  wire [7:0]           candidate_count,
    input  wire [31:0]          error_flags,
    input  wire [31:0]          active_frame_id,
    input  wire [15:0]          frame_drop_count,
    input  wire [5:0]           fe_mode_applied,
    input  wire [5:0]           valid_margin,

    output reg                  enable,
    output reg                  image_capture_enable,
    output reg                  auto_start_enable,

    output reg                  manual_start_pulse,
    output reg                  soft_reset_pulse,
    output reg                  error_clear_pulse,
    output reg                  stream_start_pulse,

    output reg  [31:0]          frame_id_seed,
    output reg                  frame_id_seed_write,

    output reg  [31:0]          irq_enable,
    output reg  [31:0]          irq_status,
    output wire                 irq
);
    localparam [ADDR_W-1:0] A_CONTROL      = 6'h00;
    localparam [ADDR_W-1:0] A_STATUS       = 6'h04;
    localparam [ADDR_W-1:0] A_FRAME_ID     = 6'h08;
    localparam [ADDR_W-1:0] A_RESULT_WORDS = 6'h0C;
    localparam [ADDR_W-1:0] A_CAND_COUNT   = 6'h10;
    localparam [ADDR_W-1:0] A_ERROR_FLAGS  = 6'h14;
    localparam [ADDR_W-1:0] A_IMAGE_BYTES  = 6'h18;
    localparam [ADDR_W-1:0] A_IMAGE_FORMAT = 6'h1C;
    localparam [ADDR_W-1:0] A_FE_CONFIG    = 6'h20;
    localparam [ADDR_W-1:0] A_IMAGE_SIZE   = 6'h24;
    localparam [ADDR_W-1:0] A_IMAGE_STRIDE = 6'h28;
    localparam [ADDR_W-1:0] A_IRQ_STATUS   = 6'h2C;
    localparam [ADDR_W-1:0] A_IRQ_ENABLE   = 6'h30;
    localparam [ADDR_W-1:0] A_ACTIVE_ID    = 6'h34;
    localparam [ADDR_W-1:0] A_DROP_COUNT   = 6'h38;

    reg aw_pending;
    reg [ADDR_W-1:0] awaddr_reg;
    reg w_pending;
    reg [31:0] wdata_reg;
    reg [3:0] wstrb_reg;

    reg result_ready_d;

    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire = s_axi_wvalid && s_axi_wready;
    wire write_commit = aw_pending && w_pending && !s_axi_bvalid;
    wire read_fire = s_axi_arvalid && s_axi_arready;

    assign s_axi_awready = !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = !w_pending && !s_axi_bvalid;
    assign s_axi_bresp = 2'b00;

    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp = 2'b00;

    assign irq = |(irq_status & irq_enable);

    function [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0] strb;
        begin
            merge_wstrb = old_value;
            if (strb[0]) merge_wstrb[7:0] = new_value[7:0];
            if (strb[1]) merge_wstrb[15:8] = new_value[15:8];
            if (strb[2]) merge_wstrb[23:16] = new_value[23:16];
            if (strb[3]) merge_wstrb[31:24] = new_value[31:24];
        end
    endfunction

    wire [31:0] control_value = {
        24'd0,
        auto_start_enable,
        1'b0,
        image_capture_enable,
        4'd0,
        enable
    };

    wire [31:0] status_value = {
        20'd0,
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

    reg [31:0] read_mux;
    always @(*) begin
        case (s_axi_araddr)
            A_CONTROL:      read_mux = control_value;
            A_STATUS:       read_mux = status_value;
            A_FRAME_ID:     read_mux = frame_id_seed;
            A_RESULT_WORDS: read_mux = {16'd0, result_word_length};
            A_CAND_COUNT:   read_mux = {24'd0, candidate_count};
            A_ERROR_FLAGS:  read_mux = error_flags;
            A_IMAGE_BYTES:  read_mux = 32'd307200;
            A_IMAGE_FORMAT: read_mux = 32'd1;
            A_FE_CONFIG:    read_mux = {20'd0, valid_margin, fe_mode_applied};
            A_IMAGE_SIZE:   read_mux = {16'd480, 16'd640};
            A_IMAGE_STRIDE: read_mux = 32'd640;
            A_IRQ_STATUS:   read_mux = irq_status;
            A_IRQ_ENABLE:   read_mux = irq_enable;
            A_ACTIVE_ID:    read_mux = active_frame_id;
            A_DROP_COUNT:   read_mux = {16'd0, frame_drop_count};
            default:        read_mux = 32'd0;
        endcase
    end

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            aw_pending <= 1'b0;
            awaddr_reg <= {ADDR_W{1'b0}};
            w_pending <= 1'b0;
            wdata_reg <= 32'd0;
            wstrb_reg <= 4'd0;
            s_axi_bvalid <= 1'b0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= 32'd0;

            enable <= 1'b0;
            image_capture_enable <= 1'b0;
            auto_start_enable <= 1'b1;

            manual_start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            error_clear_pulse <= 1'b0;
            stream_start_pulse <= 1'b0;

            frame_id_seed <= 32'd0;
            frame_id_seed_write <= 1'b0;

            irq_enable <= 32'd0;
            irq_status <= 32'd0;
            result_ready_d <= 1'b0;
        end
        else begin
            manual_start_pulse <= 1'b0;
            soft_reset_pulse <= 1'b0;
            error_clear_pulse <= 1'b0;
            stream_start_pulse <= 1'b0;
            frame_id_seed_write <= 1'b0;

            result_ready_d <= result_ready;

            if (aw_fire) begin
                aw_pending <= 1'b1;
                awaddr_reg <= s_axi_awaddr;
            end

            if (w_fire) begin
                w_pending <= 1'b1;
                wdata_reg <= s_axi_wdata;
                wstrb_reg <= s_axi_wstrb;
            end

            if (write_commit) begin
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;

                case (awaddr_reg)
                    A_CONTROL: begin
                        if (wstrb_reg[0]) begin
                            enable <= wdata_reg[0];
                            if (wdata_reg[1]) manual_start_pulse <= 1'b1;
                            if (wdata_reg[2]) soft_reset_pulse <= 1'b1;
                            if (wdata_reg[3]) error_clear_pulse <= 1'b1;
                            if (wdata_reg[4]) stream_start_pulse <= 1'b1;
                            image_capture_enable <= wdata_reg[5];
                            auto_start_enable <= wdata_reg[7];
                        end
                    end

                    A_FRAME_ID: begin
                        frame_id_seed <= merge_wstrb(
                            frame_id_seed,
                            wdata_reg,
                            wstrb_reg
                        );
                        frame_id_seed_write <= 1'b1;
                    end

                    A_IRQ_STATUS: begin
                        irq_status <= irq_status & ~wdata_reg;
                    end

                    A_IRQ_ENABLE: begin
                        irq_enable <= merge_wstrb(
                            irq_enable,
                            wdata_reg,
                            wstrb_reg
                        );
                    end

                    default: begin
                    end
                endcase
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (read_fire) begin
                s_axi_rdata <= read_mux;
                s_axi_rvalid <= 1'b1;
            end
            else if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            if (result_ready && !result_ready_d)
                irq_status[0] <= 1'b1;
            if (packet_tx_done)
                irq_status[1] <= 1'b1;
            if (image_tx_done)
                irq_status[2] <= 1'b1;
            if (combined_error)
                irq_status[3] <= 1'b1;
            if (frame_stuck)
                irq_status[4] <= 1'b1;
            if (image_overflow_error)
                irq_status[5] <= 1'b1;
            if (frame_id_protocol_error)
                irq_status[6] <= 1'b1;

            if (error_clear_pulse)
                irq_status[6:3] <= 4'd0;
        end
    end
endmodule
