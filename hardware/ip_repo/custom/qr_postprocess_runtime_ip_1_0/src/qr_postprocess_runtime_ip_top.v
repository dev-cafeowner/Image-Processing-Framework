`timescale 1ns / 1ps
/*
 * ============================================================================
 * Module : qr_postprocess_runtime_ip_top
 *
 * IP3 responsibilities
 *   - PS AXI4-Lite CSR and IRQ
 *   - Frontend frame-ready/release control
 *   - Coordinated IP2 + IP3 start
 *   - Event AXI4-Stream input
 *   - Sparse CCL / Object Properties
 *   - QRP1 result AXI4-Stream output
 *   - Frame ID assignment
 * ============================================================================
 */
module qr_postprocess_runtime_ip_top #(
    parameter integer MAX_RECORDS           = 16,
    parameter integer EVENT_FIFO_DEPTH      = 32,
    parameter integer EVENT_FIFO_ADDR_WIDTH = 5,
    parameter integer FRAME_TIMEOUT_W       = 24,
    parameter integer ADDR_W                = 6
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXI_CONTROL:S_AXIS_EVENT:M_AXIS_RESULT, ASSOCIATED_RESET aresetn, FREQ_HZ 125000000" *)
    input  wire                 aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire                 aresetn,

    // ---------------------------------------------------------------- AXI-Lite
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI_CONTROL, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 6, FREQ_HZ 125000000, HAS_BURST 0, HAS_LOCK 0, HAS_CACHE 0, HAS_REGION 0, HAS_QOS 0" *)
    input  wire [ADDR_W-1:0]    s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWPROT" *)
    input  wire [2:0]           s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWVALID" *)
    input  wire                 s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL AWREADY" *)
    output wire                 s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WDATA" *)
    input  wire [31:0]          s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WSTRB" *)
    input  wire [3:0]           s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WVALID" *)
    input  wire                 s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL WREADY" *)
    output wire                 s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BRESP" *)
    output wire [1:0]           s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BVALID" *)
    output wire                 s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL BREADY" *)
    input  wire                 s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARADDR" *)
    input  wire [ADDR_W-1:0]    s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARPROT" *)
    input  wire [2:0]           s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARVALID" *)
    input  wire                 s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL ARREADY" *)
    output wire                 s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RDATA" *)
    output wire [31:0]          s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RRESP" *)
    output wire [1:0]           s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RVALID" *)
    output wire                 s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI_CONTROL RREADY" *)
    input  wire                 s_axi_rready,

    // ------------------------------------------------------------- Event input
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_EVENT TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS_EVENT, TDATA_NUM_BYTES 4, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
    input  wire [31:0]          s_axis_event_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_EVENT TKEEP" *)
    input  wire [3:0]           s_axis_event_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_EVENT TVALID" *)
    input  wire                 s_axis_event_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_EVENT TREADY" *)
    output wire                 s_axis_event_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS_EVENT TLAST" *)
    input  wire                 s_axis_event_tlast,

    // ------------------------------------------------------------ Result output
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS_RESULT, TDATA_NUM_BYTES 4, HAS_TKEEP 1, HAS_TLAST 1, HAS_TREADY 1" *)
    output wire [31:0]          m_axis_result_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TKEEP" *)
    output wire [3:0]           m_axis_result_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TVALID" *)
    output wire                 m_axis_result_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TREADY" *)
    input  wire                 m_axis_result_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TLAST" *)
    output wire                 m_axis_result_tlast,

    // ---------------------------------------------------------- IP1 handshake
    input  wire                 frontend_frame_ready,
    input  wire [7:0]           frontend_valid_margin,

    output wire                 frontend_frame_release,
    output wire                 frontend_frame_stuck,
    output wire                 frontend_stat_clear,

    // ---------------------------------------------------------- IP2 handshake
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

    // --------------------------------------------------------------- status
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq, SENSITIVITY LEVEL_HIGH" *)
    output wire                 irq,

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
    output wire                 system_error,

    output wire [8:0]           stored_hit_count,
    output wire [5:0]           allocated_label_count,
    output wire [18:0]          accumulated_hit_count,
    output wire [5:0]           qualified_property_count
);

    wire unused_axi_prot;
    assign unused_axi_prot =
        ^{s_axi_awprot, s_axi_arprot};

    wire enable;
    wire image_capture_enable_unused;
    wire auto_start_enable;

    wire manual_start_pulse;
    wire soft_reset_pulse;
    wire error_clear_pulse;
    wire stream_start_pulse;

    wire [31:0] frame_id_seed;
    wire frame_id_seed_write;
    wire [31:0] irq_enable_unused;
    wire [31:0] irq_status_unused;

    wire core_aresetn;
    assign core_aresetn =
        aresetn && !soft_reset_pulse;

    reg frontend_frame_ready_d;
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

    wire frame_id_valid;
    wire frame_id_protocol_error;

    wire post_start_ready;
    wire post_processing_busy;

    wire frame_ctrl_start_ready;
    wire coordinated_start;
    wire frame_control_error;

    wire pipeline_start_ready;

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

    /*
     * Raw frame presence must remain independent from temporary downstream
     * busy/not-ready states. Otherwise the one-shot controller can re-arm
     * while the same frontend frame is still being held.
     */
    assign pipeline_start_ready =
        ip2_start_ready &&
        post_start_ready;

    assign processing_busy =
        ip2_processing_busy ||
        post_processing_busy ||
        stream_busy;

    assign ip2_start = coordinated_start;

    assign frontend_stat_clear = error_clear_pulse;
    assign ip2_error_clear     = error_clear_pulse;

    assign result_tx_done = packet_tx_done;

    qr_frame_id_control u_frame_id (
        .aclk                    (aclk),
        .aresetn                 (core_aresetn),

        .seed_write              (frame_id_seed_write),
        .seed_value              (frame_id_seed),

        .frame_sof_accept        (frontend_frame_ready_rise),
        .frame_release           (frontend_frame_release),

        .feature_start_accept    (coordinated_start),

        .error_clear             (error_clear_pulse),

        .next_frame_id           (next_frame_id),
        .active_frame_id         (active_frame_id),
        .active_valid            (frame_id_valid),
        .frame_id_protocol_error (frame_id_protocol_error)
    );

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
        .final_processing_done  (packet_tx_done),

        .stat_clear             (error_clear_pulse),
        .stuck                  (frontend_frame_stuck),
        .control_protocol_error (frame_control_error)
    );

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

    assign result_error_flags = core_error_flags;

    assign system_error =
        core_system_error ||
        frame_control_error ||
        frame_id_protocol_error;

    qr_pl_control_axi_lite #(
        .ADDR_W(ADDR_W)
    ) u_csr (
        .aclk                    (aclk),
        .aresetn                 (aresetn),

        .s_axi_awaddr            (s_axi_awaddr),
        .s_axi_awvalid           (s_axi_awvalid),
        .s_axi_awready           (s_axi_awready),

        .s_axi_wdata             (s_axi_wdata),
        .s_axi_wstrb             (s_axi_wstrb),
        .s_axi_wvalid            (s_axi_wvalid),
        .s_axi_wready            (s_axi_wready),

        .s_axi_bresp             (s_axi_bresp),
        .s_axi_bvalid            (s_axi_bvalid),
        .s_axi_bready            (s_axi_bready),

        .s_axi_araddr            (s_axi_araddr),
        .s_axi_arvalid           (s_axi_arvalid),
        .s_axi_arready           (s_axi_arready),

        .s_axi_rdata             (s_axi_rdata),
        .s_axi_rresp             (s_axi_rresp),
        .s_axi_rvalid            (s_axi_rvalid),
        .s_axi_rready            (s_axi_rready),

        .processing_busy         (processing_busy),
        .feature_start_ready     (frame_ctrl_start_ready),
        .frontend_frame_ready    (frontend_frame_ready),
        .result_ready            (result_ready),
        .stream_busy             (stream_busy),
        .packet_tx_done          (packet_tx_done),
        .image_tx_done           (1'b0),
        .combined_error          (
            system_error ||
            frame_control_error
        ),
        .frame_stuck             (frontend_frame_stuck),
        .image_overflow_error    (1'b0),
        .frame_id_protocol_error (frame_id_protocol_error),

        .result_word_length      (result_word_length),
        .candidate_count         (candidate_count),
        .error_flags             (result_error_flags),
        .active_frame_id         (active_frame_id),
        .frame_drop_count        (16'd0),
        .fe_mode_applied         (6'd0),
        .valid_margin            (frontend_valid_margin[5:0]),

        .enable                  (enable),
        .image_capture_enable    (image_capture_enable_unused),
        .auto_start_enable       (auto_start_enable),

        .manual_start_pulse      (manual_start_pulse),
        .soft_reset_pulse        (soft_reset_pulse),
        .error_clear_pulse       (error_clear_pulse),
        .stream_start_pulse      (stream_start_pulse),

        .frame_id_seed           (frame_id_seed),
        .frame_id_seed_write     (frame_id_seed_write),

        .irq_enable              (irq_enable_unused),
        .irq_status              (irq_status_unused),
        .irq                     (irq)
    );

endmodule
