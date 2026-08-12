`timescale 1ns / 1ps
/*
 * IP2: QR Run-Length + Vertical Cross-Check Front-End
 *
 * Input:
 *   External Binary Frame BRAM Port B, 32-bit x 9600 words
 *
 * Output:
 *   32-bit AXI4-Stream event packet
 *   TDATA[20:19] type
 *   TDATA[18:9]  x
 *   TDATA[8:0]   y
 *   TLAST asserted on FRAME_DONE
 *
 * This wrapper does not contain the Binary Frame BRAM.
 */
module qr_vcc_frontend_ip_top (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF BRAM_PORTB:M_AXIS_EVENT, ASSOCIATED_RESET aresetn, FREQ_HZ 125000000" *)
    input  wire         aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire         aresetn,

    input  wire         start,
    output wire         start_ready,
    input  wire         error_clear,

    output wire         processing_busy,
    output wire         processing_done,

    /*
     * Native BRAM Port-B master.
     * The connected BMG must use READ_LATENCY_B=1.
     */
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME BRAM_PORTB, MASTER_TYPE BRAM_CTRL, MEM_SIZE 38400, MEM_WIDTH 32, READ_LATENCY 1" *)
    output wire         bram_clk,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB RST" *)
    output wire         bram_rst,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB EN" *)
    output wire         bram_en,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB WE" *)
    output wire         bram_we,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB ADDR" *)
    output wire [13:0]  bram_addr,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB DIN" *)
    output wire [31:0]  bram_din,

    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 BRAM_PORTB DOUT" *)
    input  wire [31:0]  bram_dout,

    /*
     * Event stream.
     */
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_EVENT TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS_EVENT, TDATA_NUM_BYTES 4, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
    output wire [31:0]  m_axis_event_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_EVENT TKEEP" *)
    output wire [3:0]   m_axis_event_tkeep,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_EVENT TVALID" *)
    output wire         m_axis_event_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_EVENT TREADY" *)
    input  wire         m_axis_event_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_EVENT TLAST" *)
    output wire         m_axis_event_tlast,

    /*
     * Status/debug.
     */
    output wire         scan_vcc_busy,
    output wire         reader_frame_done,
    output wire         reader_busy,
    output wire         reader_pause,
    output wire         reader_paused,
    output wire         owner_vcc,
    output wire         vcc_grant,

    output wire         run_pattern_valid,
    output wire [9:0]   run_candidate_x,
    output wire [8:0]   run_candidate_y,
    output wire [12:0]  run_pattern_total,

    output reg  [15:0]  hit_event_count,
    output reg  [15:0]  row_event_count,
    output reg  [15:0]  total_event_count,

    output wire         candidate_overrun_error,
    output wire         candidate_drop_error,
    output wire         coordinate_error,
    output wire         arbiter_protocol_error,
    output wire         row_done_overrun_error,
    output wire         scan_vcc_error,

    output wire         event_stability_error,
    output wire         event_row_order_error,
    output wire         event_protocol_error,
    output wire         combined_error
);

    wire        hit_valid;
    wire        hit_ready;
    wire [9:0]  hit_x;
    wire [8:0]  hit_y;

    wire        row_done_valid;
    wire        row_done_ready;
    wire [8:0]  row_done_y;

    wire        scan_vcc_done_valid;
    wire        scan_vcc_done_ready;

    wire        event_active;
    wire        accepted_start;

    wire        candidate_pending_unused;
    wire [2:0]  candidate_state_unused;
    wire [1:0]  arbiter_state_unused;

    assign start_ready =
        !scan_vcc_busy && !event_active;

    assign accepted_start =
        start && start_ready;

    assign processing_busy =
        scan_vcc_busy || event_active;

    assign bram_clk = aclk;
    assign bram_rst = ~aresetn;
    assign bram_we  = 1'b0;
    assign bram_din = 32'd0;

    qr_runlength_vcc_top u_scan_vcc (
        .aclk                    (aclk),
        .aresetn                 (aresetn),

        .start                   (accepted_start),

        .scan_vcc_busy           (scan_vcc_busy),
        .scan_vcc_done_valid     (scan_vcc_done_valid),
        .scan_vcc_done_ready     (scan_vcc_done_ready),

        .reader_frame_done       (reader_frame_done),

        .bram_en                 (bram_en),
        .bram_addr               (bram_addr),
        .bram_rd_data            (bram_dout),

        .hit_valid               (hit_valid),
        .hit_ready               (hit_ready),
        .hit_x                   (hit_x),
        .hit_y                   (hit_y),

        .row_done_valid          (row_done_valid),
        .row_done_ready          (row_done_ready),
        .row_done_y              (row_done_y),

        .error_clear             (error_clear),

        .candidate_overrun_error (candidate_overrun_error),
        .candidate_drop_error    (candidate_drop_error),
        .coordinate_error        (coordinate_error),
        .arbiter_protocol_error  (arbiter_protocol_error),
        .row_done_overrun_error  (row_done_overrun_error),
        .scan_vcc_error          (scan_vcc_error),

        .reader_busy             (reader_busy),
        .reader_pause            (reader_pause),
        .reader_paused           (reader_paused),

        .candidate_pending       (candidate_pending_unused),
        .candidate_state         (candidate_state_unused),

        .vcc_grant               (vcc_grant),
        .owner_vcc               (owner_vcc),
        .arbiter_state           (arbiter_state_unused),

        .run_pattern_valid       (run_pattern_valid),
        .run_candidate_x         (run_candidate_x),
        .run_candidate_y         (run_candidate_y),
        .run_pattern_total       (run_pattern_total)
    );

    qr_vcc_event_axis_packer u_event_packer (
        .aclk                    (aclk),
        .aresetn                 (aresetn),

        .start                   (accepted_start),

        .hit_valid               (hit_valid),
        .hit_ready               (hit_ready),
        .hit_x                   (hit_x),
        .hit_y                   (hit_y),

        .row_done_valid          (row_done_valid),
        .row_done_ready          (row_done_ready),
        .row_done_y              (row_done_y),

        .scan_done_valid         (scan_vcc_done_valid),
        .scan_done_ready         (scan_vcc_done_ready),

        .m_axis_tdata            (m_axis_event_tdata),
        .m_axis_tkeep            (m_axis_event_tkeep),
        .m_axis_tvalid           (m_axis_event_tvalid),
        .m_axis_tready           (m_axis_event_tready),
        .m_axis_tlast            (m_axis_event_tlast),

        .active                  (event_active),
        .processing_done         (processing_done),

        .error_clear             (error_clear),
        .event_stability_error   (event_stability_error),
        .row_order_error         (event_row_order_error),
        .protocol_error          (event_protocol_error)
    );

    assign combined_error =
        scan_vcc_error ||
        event_stability_error ||
        event_row_order_error ||
        event_protocol_error;

    always @(posedge aclk) begin
        if (!aresetn) begin
            hit_event_count   <= 16'd0;
            row_event_count   <= 16'd0;
            total_event_count <= 16'd0;
        end
        else begin
            if (accepted_start) begin
                hit_event_count   <= 16'd0;
                row_event_count   <= 16'd0;
                total_event_count <= 16'd0;
            end
            else if (m_axis_event_tvalid && m_axis_event_tready) begin
                total_event_count <= total_event_count + 1'b1;

                case (m_axis_event_tdata[20:19])
                    2'b00:
                        hit_event_count <= hit_event_count + 1'b1;
                    2'b01:
                        row_event_count <= row_event_count + 1'b1;
                    default: begin
                    end
                endcase
            end
        end
    end

endmodule
