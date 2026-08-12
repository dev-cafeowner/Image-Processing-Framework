`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : ov7670_axis_top
// Project     : OV7670 + AXI4-Stream FIFO IP
// Target      : xc7z020clg400-1
//
// Description :
//   Sensor-specific capture block packaged separately from the reusable Vision
//   Front-End. The OV7670 cannot be stalled, so the elastic FIFO belongs at the
//   camera boundary rather than inside the processing IP.
//
//     OV7670 pins -> ov7670_capture -> axis_fifo -> M_AXIS RGB565
//
// Clocking:
//   Everything runs in aclk. cam_pclk is oversampled by ov7670_capture and is
//   not a separate clock domain. At the validated configuration:
//
//     aclk = 125 MHz
//     XCLK = aclk / 10 = 12.5 MHz
//
// Reset and enable:
//   The receiver remains alive on aresetn while capture_en is low so software
//   can read cam_status before enabling the processing pipeline. The FIFO is
//   held in reset while capture_en is low, matching the old integrated design.
//
// Control/status ownership:
//   capture_en and stat_clear come from the Vision Front-End CSR block.
//   cam_status, fifo_full and fifo_max_level return to that same CSR block.
//   This preserves the existing software register map while separating the RTL
//   into two packaged IPs.
//
// NOTE: This file is intentionally ASCII-only.
//////////////////////////////////////////////////////////////////////////////////

module ov7670_axis_top #(
    parameter integer XCLK_DIV          = 10,
    parameter integer VSYNC_ACTIVE_HIGH = 1,
    parameter integer FIFO_DEPTH        = 128
)(
    // ---- common clock and reset --------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF M_AXIS, ASSOCIATED_RESET aresetn, FREQ_HZ 125000000" *)
    input  wire         aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    input  wire         aresetn,

    // ---- OV7670 parallel pixel interface -----------------------------------
    input  wire         cam_pclk,
    input  wire         cam_href,
    input  wire         cam_vsync,
    input  wire [7:0]   cam_data,
    output wire         cam_xclk,

    // ---- control from the Vision Front-End CSR -----------------------------
    // Both inputs must be synchronous to aclk.
    input  wire         capture_en,
    input  wire         stat_clear,

    // ---- AXI4-Stream master: RGB565, SOF=TUSER, EOL=TLAST ------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXIS, TDATA_NUM_BYTES 2, TUSER_WIDTH 1, HAS_TLAST 1, HAS_TREADY 1" *)
    output wire [15:0]  m_axis_tdata,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire         m_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire         m_axis_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
    output wire         m_axis_tuser,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire         m_axis_tlast,

    // ---- status to the Vision Front-End CSR --------------------------------
    output wire [31:0]  cam_status,
    output wire         fifo_full,
    output wire [15:0]  fifo_max_level
);

    // The receiver must continue measuring the sensor while capture is
    // disabled. Only the elastic FIFO follows the processing-pipeline enable.
    wire fifo_aresetn = aresetn & capture_en;

    wire [15:0] rx_tdata;
    wire        rx_tvalid;
    wire        rx_tready;
    wire        rx_tuser;
    wire        rx_tlast;

    // Detailed receiver status remains internal because cam_status contains
    // the same fields in the software-compatible 32-bit layout.
    wire [11:0] cam_line_len_unused;
    wire [11:0] cam_frame_lines_unused;
    wire        cam_overflow_unused;
    wire        cam_vsync_seen_unused;

    ov7670_capture #(
        .XCLK_DIV          (XCLK_DIV),
        .VSYNC_ACTIVE_HIGH (VSYNC_ACTIVE_HIGH)
    ) u_capture (
        .aclk            (aclk),
        .aresetn         (aresetn),

        .cam_pclk        (cam_pclk),
        .cam_href        (cam_href),
        .cam_vsync       (cam_vsync),
        .cam_data        (cam_data),
        .cam_xclk        (cam_xclk),

        .capture_en      (capture_en),
        .stat_clear      (stat_clear),

        .m_axis_tdata    (rx_tdata),
        .m_axis_tvalid   (rx_tvalid),
        .m_axis_tready   (rx_tready),
        .m_axis_tuser    (rx_tuser),
        .m_axis_tlast    (rx_tlast),

        .cam_line_len    (cam_line_len_unused),
        .cam_frame_lines (cam_frame_lines_unused),
        .cam_overflow    (cam_overflow_unused),
        .cam_vsync_seen  (cam_vsync_seen_unused),
        .cam_status      (cam_status)
    );

    axis_fifo #(
        .DW    (16),
        .DEPTH (FIFO_DEPTH)
    ) u_fifo (
        .aclk           (aclk),
        .aresetn        (fifo_aresetn),
        .stat_clear     (stat_clear),

        .s_axis_tdata   (rx_tdata),
        .s_axis_tvalid  (rx_tvalid),
        .s_axis_tready  (rx_tready),
        .s_axis_tuser   (rx_tuser),
        .s_axis_tlast   (rx_tlast),

        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tready  (m_axis_tready),
        .m_axis_tuser   (m_axis_tuser),
        .m_axis_tlast   (m_axis_tlast),

        .fifo_full      (fifo_full),
        .fifo_max_level (fifo_max_level)
    );

    // Elaboration-time parameter checks. The child FIFO checks the power-of-two
    // requirement as well; these messages make the wrapper error self-contained.
    // synthesis translate_off
    initial begin
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0)
            $fatal(1, "[OV7670_AXIS] FIFO_DEPTH %0d is not a power of two",
                   FIFO_DEPTH);
        if (XCLK_DIV < 2 || (XCLK_DIV & 1) != 0)
            $fatal(1, "[OV7670_AXIS] XCLK_DIV %0d must be positive and even",
                   XCLK_DIV);
    end
    // synthesis translate_on

endmodule
