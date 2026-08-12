`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : vision_frontend_ip_top
// Project     : Reusable Vision Front-End IP
// Target      : xc7z020clg400-1
//
// Description :
//   Vision Front-End top level after moving the camera elastic FIFO into the
//   separate ov7670_axis_top IP.
//
//     S_AXIS RGB565 -> vision_frontend_core
//                       +-> 8-bit M_AXIS bring-up stream
//                       +-> binary FB_AXIS stream
//                       +-> binary frame BRAM write port
//
//     S_AXI AXI4-Lite -> configuration and status registers
//
// Register ownership:
//   This IP owns only Vision Front-End configuration and status. Camera capture
//   control, CAM_STATUS and camera FIFO status belong to the separate
//   ov7670_axis AXI4-Lite peripheral.
//
// Reset:
//   S_AXI stays alive on aresetn. The processing core is held in reset until
//   CTRL.enable=1 and CTRL.soft_reset=0.
//
// NOTE: This file is intentionally ASCII-only.
//////////////////////////////////////////////////////////////////////////////////

module vision_frontend_ip_top #(
    parameter integer MAX_W        = 640,
    parameter integer ENABLE_SOBEL = 0,
    parameter integer ADDR_W       = 5
)(
    // ---- common clock and reset --------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXI:S_AXIS:M_AXIS:FB_AXIS, ASSOCIATED_RESET aresetn, FREQ_HZ 125000000" *)
    input  wire                 aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire                 aresetn,

    // ---- AXI4-Lite slave: PS configuration and status ----------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 5, FREQ_HZ 125000000, HAS_BURST 0, HAS_LOCK 0, HAS_CACHE 0, HAS_REGION 0, HAS_QOS 0" *)
    input  wire [ADDR_W-1:0]    s_axi_awaddr,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                 s_axi_awvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire                 s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0]          s_axi_wdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]           s_axi_wstrb,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                 s_axi_wvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire                 s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]           s_axi_bresp,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire                 s_axi_bvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                 s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [ADDR_W-1:0]    s_axi_araddr,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                 s_axi_arvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire                 s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0]          s_axi_rdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]           s_axi_rresp,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire                 s_axi_rvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                 s_axi_rready,

    // ---- AXI4-Stream slave: RGB565 from ov7670_axis_top --------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 2, TUSER_WIDTH 1, HAS_TLAST 1, HAS_TREADY 1" *)
    input  wire [15:0]          s_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire                 s_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire                 s_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
    input  wire                 s_axis_tuser,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire                 s_axis_tlast,

    // ---- frame handshake with downstream extraction logic ------------------
    input  wire                 pl_frame_release,
    output wire                 frame_ready,
    output wire [7:0]           valid_margin,
    input  wire                 frame_stuck,

    // ---- Binary Frame BRAM write port A ------------------------------------
    output wire                 wr_en,
    output wire [13:0]          wr_addr,
    output wire [31:0]          wr_data,

    // ---- AXI4-Stream master: packed binary stream for optional DMA ---------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 FB_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME FB_AXIS, TDATA_NUM_BYTES 4, HAS_TLAST 1, HAS_TREADY 1" *)
    output wire [31:0]          fb_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 FB_AXIS TVALID" *)
    output wire                 fb_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 FB_AXIS TREADY" *)
    input  wire                 fb_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 FB_AXIS TLAST" *)
    output wire                 fb_axis_tlast,

    // ---- AXI4-Stream master: 8-bit bring-up/test output --------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 1, TUSER_WIDTH 1, HAS_TLAST 1, HAS_TREADY 1" *)
    output wire [7:0]           m_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire                 m_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire                 m_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
    output wire                 m_axis_tuser,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire                 m_axis_tlast
);

    // ---------------------------------------------------------- CSR outputs
    wire        cfg_enable;
    wire        cfg_soft_reset;
    wire        cfg_csr_frame_release;
    wire        cfg_fb_inv;
    wire        cfg_stat_clear;
    wire [5:0]  cfg_fe_mode;
    wire [7:0]  cfg_thresh;
    wire [7:0]  cfg_c;
    wire [11:0] cfg_width;
    wire [11:0] cfg_height;

    // ---------------------------------------------------------- core status
    wire        sts_cfg_invalid;
    wire        sts_frame_ready;
    wire        sts_frame_dropped;
    wire        sts_dma_overflow;
    wire [7:0]  sts_valid_margin;
    wire [15:0] sts_frame_num;
    wire [15:0] sts_frame_drop_cnt;

    // ------------------------------------------------------- pipeline reset
    // Registered to keep CSR fanout out of the processing reset tree.
    reg pipe_aresetn;
    always @(posedge aclk) begin
        if (!aresetn)
            pipe_aresetn <= 1'b0;
        else
            pipe_aresetn <= cfg_enable & ~cfg_soft_reset;
    end

    // ------------------------------------------------------ processing core
    // Both release sources are required: PL owns the normal handshake while
    // the CSR bit is the software bring-up override.
    wire frame_release = cfg_csr_frame_release | pl_frame_release;

    vision_frontend_core #(
        .MAX_W        (MAX_W),
        .ENABLE_SOBEL (ENABLE_SOBEL)
    ) u_core (
        .aclk           (aclk),
        .aresetn        (pipe_aresetn),
        .cfg_width      (cfg_width),
        .cfg_height     (cfg_height),
        .cfg_fe_mode    (cfg_fe_mode),
        .cfg_thresh     (cfg_thresh),
        .cfg_c          (cfg_c),
        .cfg_fb_inv     (cfg_fb_inv),
        .frame_release  (frame_release),
        .stat_clear     (cfg_stat_clear),
        .cfg_invalid    (sts_cfg_invalid),
        .valid_margin   (sts_valid_margin),

        // The camera FIFO is now in ov7670_axis_top, so S_AXIS connects
        // directly to the processing core.
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tuser   (s_axis_tuser),
        .s_axis_tlast   (s_axis_tlast),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tuser   (m_axis_tuser),
        .m_axis_tlast   (m_axis_tlast),

        .wr_en          (wr_en),
        .wr_addr        (wr_addr),
        .wr_data        (wr_data),

        .fb_axis_tdata  (fb_axis_tdata),
        .fb_axis_tvalid (fb_axis_tvalid),
        .fb_axis_tready (fb_axis_tready),
        .fb_axis_tlast  (fb_axis_tlast),

        .frame_ready    (sts_frame_ready),
        .frame_num      (sts_frame_num),
        .frame_dropped  (sts_frame_dropped),
        .frame_drop_cnt (sts_frame_drop_cnt),
        .dma_overflow   (sts_dma_overflow)
    );

    assign frame_ready  = sts_frame_ready;
    assign valid_margin = sts_valid_margin;

    // ------------------------------------------------ busy and mode_applied
    // A frame is accepted on an SOF transfer only when the frame buffer is free.
    wire core_sof   = s_axis_tvalid & s_axis_tready & s_axis_tuser;
    wire accept_sof = core_sof & ~sts_frame_ready;

    reg       busy_q;
    reg [5:0] mode_applied_q;

    always @(posedge aclk) begin
        if (!pipe_aresetn) begin
            busy_q         <= 1'b0;
            mode_applied_q <= 6'd0;
        end else begin
            if (sts_frame_ready)
                busy_q <= 1'b0;
            else if (accept_sof)
                busy_q <= 1'b1;

            if (accept_sof)
                mode_applied_q <= cfg_fe_mode;
        end
    end

    // ------------------------------------------------------- register bank
    // The register bank uses aresetn rather than pipe_aresetn so software can
    // always re-enable a disabled or soft-reset processing pipeline.
    ip_fe_slave_lite_v1_0_S00_AXI #(
        .C_S_AXI_DATA_WIDTH (32),
        .C_S_AXI_ADDR_WIDTH (ADDR_W)
    ) u_csr (
        .S_AXI_ACLK         (aclk),
        .S_AXI_ARESETN      (aresetn),

        .S_AXI_AWADDR       (s_axi_awaddr),
        .S_AXI_AWPROT       (3'b000),
        .S_AXI_AWVALID      (s_axi_awvalid),
        .S_AXI_AWREADY      (s_axi_awready),
        .S_AXI_WDATA        (s_axi_wdata),
        .S_AXI_WSTRB        (s_axi_wstrb),
        .S_AXI_WVALID       (s_axi_wvalid),
        .S_AXI_WREADY       (s_axi_wready),
        .S_AXI_BRESP        (s_axi_bresp),
        .S_AXI_BVALID       (s_axi_bvalid),
        .S_AXI_BREADY       (s_axi_bready),
        .S_AXI_ARADDR       (s_axi_araddr),
        .S_AXI_ARPROT       (3'b000),
        .S_AXI_ARVALID      (s_axi_arvalid),
        .S_AXI_ARREADY      (s_axi_arready),
        .S_AXI_RDATA        (s_axi_rdata),
        .S_AXI_RRESP        (s_axi_rresp),
        .S_AXI_RVALID       (s_axi_rvalid),
        .S_AXI_RREADY       (s_axi_rready),

        .cfg_enable         (cfg_enable),
        .cfg_soft_reset     (cfg_soft_reset),
        .cfg_frame_release  (cfg_csr_frame_release),
        .cfg_fb_inv         (cfg_fb_inv),
        .cfg_stat_clear     (cfg_stat_clear),
        .cfg_fe_mode        (cfg_fe_mode),
        .cfg_thresh         (cfg_thresh),
        .cfg_c              (cfg_c),
        .cfg_width          (cfg_width),
        .cfg_height         (cfg_height),

        .sts_busy           (busy_q),
        .sts_frame_ready    (sts_frame_ready),
        .sts_frame_dropped  (sts_frame_dropped),
        .sts_cfg_invalid    (sts_cfg_invalid),
        .sts_dma_overflow   (sts_dma_overflow),
        .sts_frame_stuck    (frame_stuck),
        .sts_frame_num      (sts_frame_num),
        .sts_frame_drop_cnt (sts_frame_drop_cnt),
        .sts_mode_applied   (mode_applied_q),
        .sts_valid_margin   (sts_valid_margin)
    );

endmodule
