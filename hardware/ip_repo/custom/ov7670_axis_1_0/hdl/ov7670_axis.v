`timescale 1 ns / 1 ps

// Packaged OV7670 capture peripheral.
//
// Data path:
//   OV7670 pins -> ov7670_axis_top -> M00_AXIS pass-through
//
// Control/status path:
//   S00_AXI <-> capture enable, status clear, camera status and FIFO status
//
// S00_AXI_ACLK and M00_AXIS_ACLK must be connected to the same clock in the
// block design. No clock-domain crossing logic exists between these blocks.

module ov7670_axis #
(
    // OV7670 capture parameters.
    parameter integer C_XCLK_DIV          = 10,
    parameter integer C_VSYNC_ACTIVE_HIGH = 1,
    parameter integer C_FIFO_DEPTH        = 128,

    // Parameters of AXI Slave Bus Interface S00_AXI.
    parameter integer C_S00_AXI_DATA_WIDTH = 32,
    parameter integer C_S00_AXI_ADDR_WIDTH = 4,

    // Parameters of AXI Master Bus Interface M00_AXIS.
    // RGB565 requires exactly two bytes per transfer.
    parameter integer C_M00_AXIS_TDATA_WIDTH = 16,

    // Retained for compatibility with the original Wizard metadata.
    parameter integer C_M00_AXIS_START_COUNT = 32
)
(
    // OV7670 parallel pixel interface.
    input  wire       cam_pclk,
    input  wire       cam_href,
    input  wire       cam_vsync,
    input  wire [7:0] cam_data,
    output wire       cam_xclk,

    // Ports of AXI Slave Bus Interface S00_AXI.
    input  wire                                      s00_axi_aclk,
    input  wire                                      s00_axi_aresetn,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0]        s00_axi_awaddr,
    input  wire [2 : 0]                              s00_axi_awprot,
    input  wire                                      s00_axi_awvalid,
    output wire                                      s00_axi_awready,
    input  wire [C_S00_AXI_DATA_WIDTH-1 : 0]        s00_axi_wdata,
    input  wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0]    s00_axi_wstrb,
    input  wire                                      s00_axi_wvalid,
    output wire                                      s00_axi_wready,
    output wire [1 : 0]                              s00_axi_bresp,
    output wire                                      s00_axi_bvalid,
    input  wire                                      s00_axi_bready,
    input  wire [C_S00_AXI_ADDR_WIDTH-1 : 0]        s00_axi_araddr,
    input  wire [2 : 0]                              s00_axi_arprot,
    input  wire                                      s00_axi_arvalid,
    output wire                                      s00_axi_arready,
    output wire [C_S00_AXI_DATA_WIDTH-1 : 0]        s00_axi_rdata,
    output wire [1 : 0]                              s00_axi_rresp,
    output wire                                      s00_axi_rvalid,
    input  wire                                      s00_axi_rready,

    // Ports of AXI Master Bus Interface M00_AXIS.
    input  wire                                      m00_axis_aclk,
    input  wire                                      m00_axis_aresetn,
    output wire                                      m00_axis_tvalid,
    output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0]      m00_axis_tdata,
    output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0]  m00_axis_tstrb,
    output wire                                      m00_axis_tuser,
    output wire                                      m00_axis_tlast,
    input  wire                                      m00_axis_tready
);

    // S00_AXI control outputs.
    wire        capture_en;
    wire        stat_clear;

    // Camera/FIFO status inputs to S00_AXI.
    wire [31:0] cam_status;
    wire        fifo_full;
    wire [15:0] fifo_max_level;

    // Internal RGB565 AXI4-Stream between the camera FIFO and M00_AXIS.
    wire [15:0] camera_tdata;
    wire        camera_tvalid;
    wire        camera_tready;
    wire        camera_tuser;
    wire        camera_tlast;

    // AXI4-Lite control and status register bank.
    ov7670_axis_slave_lite_v1_0_S00_AXI #(
        .C_S_AXI_DATA_WIDTH (C_S00_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S00_AXI_ADDR_WIDTH)
    ) u_s00_axi (
        .capture_en         (capture_en),
        .stat_clear         (stat_clear),
        .cam_status         (cam_status),
        .fifo_full          (fifo_full),
        .fifo_max_level     (fifo_max_level),

        .S_AXI_ACLK         (s00_axi_aclk),
        .S_AXI_ARESETN      (s00_axi_aresetn),
        .S_AXI_AWADDR       (s00_axi_awaddr),
        .S_AXI_AWPROT       (s00_axi_awprot),
        .S_AXI_AWVALID      (s00_axi_awvalid),
        .S_AXI_AWREADY      (s00_axi_awready),
        .S_AXI_WDATA        (s00_axi_wdata),
        .S_AXI_WSTRB        (s00_axi_wstrb),
        .S_AXI_WVALID       (s00_axi_wvalid),
        .S_AXI_WREADY       (s00_axi_wready),
        .S_AXI_BRESP        (s00_axi_bresp),
        .S_AXI_BVALID       (s00_axi_bvalid),
        .S_AXI_BREADY       (s00_axi_bready),
        .S_AXI_ARADDR       (s00_axi_araddr),
        .S_AXI_ARPROT       (s00_axi_arprot),
        .S_AXI_ARVALID      (s00_axi_arvalid),
        .S_AXI_ARREADY      (s00_axi_arready),
        .S_AXI_RDATA        (s00_axi_rdata),
        .S_AXI_RRESP        (s00_axi_rresp),
        .S_AXI_RVALID       (s00_axi_rvalid),
        .S_AXI_RREADY       (s00_axi_rready)
    );

    // Sensor capture and elastic FIFO.
    ov7670_axis_top #(
        .XCLK_DIV          (C_XCLK_DIV),
        .VSYNC_ACTIVE_HIGH (C_VSYNC_ACTIVE_HIGH),
        .FIFO_DEPTH        (C_FIFO_DEPTH)
    ) u_camera (
        .aclk              (m00_axis_aclk),
        .aresetn           (m00_axis_aresetn),

        .cam_pclk          (cam_pclk),
        .cam_href          (cam_href),
        .cam_vsync         (cam_vsync),
        .cam_data          (cam_data),
        .cam_xclk          (cam_xclk),

        .capture_en        (capture_en),
        .stat_clear        (stat_clear),

        .m_axis_tdata      (camera_tdata),
        .m_axis_tvalid     (camera_tvalid),
        .m_axis_tready     (camera_tready),
        .m_axis_tuser      (camera_tuser),
        .m_axis_tlast      (camera_tlast),

        .cam_status        (cam_status),
        .fifo_full         (fifo_full),
        .fifo_max_level    (fifo_max_level)
    );

    // AXI4-Stream interface adapter.
    ov7670_axis_master_stream_v1_0_M00_AXIS #(
        .C_M_AXIS_TDATA_WIDTH (C_M00_AXIS_TDATA_WIDTH),
        .C_M_START_COUNT      (C_M00_AXIS_START_COUNT)
    ) u_m00_axis (
        .CORE_TVALID          (camera_tvalid),
        .CORE_TDATA           (camera_tdata),
        .CORE_TREADY          (camera_tready),
        .CORE_TUSER           (camera_tuser),
        .CORE_TLAST           (camera_tlast),

        .M_AXIS_ACLK          (m00_axis_aclk),
        .M_AXIS_ARESETN       (m00_axis_aresetn),
        .M_AXIS_TVALID        (m00_axis_tvalid),
        .M_AXIS_TDATA         (m00_axis_tdata),
        .M_AXIS_TSTRB         (m00_axis_tstrb),
        .M_AXIS_TUSER         (m00_axis_tuser),
        .M_AXIS_TLAST         (m00_axis_tlast),
        .M_AXIS_TREADY        (m00_axis_tready)
    );

    // synthesis translate_off
    initial begin
        if (C_M00_AXIS_TDATA_WIDTH != 16)
            $fatal(1,
                   "[OV7670_AXIS] C_M00_AXIS_TDATA_WIDTH must be 16 for RGB565");
    end
    // synthesis translate_on

endmodule
