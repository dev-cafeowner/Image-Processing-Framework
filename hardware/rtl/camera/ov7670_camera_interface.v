`timescale 1ns/1ps
// CAM3: ABI-compatible first four registers; extra read-only source metrics.
module ov7670_camera_interface (
    (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF s_axi:m_axis, ASSOCIATED_RESET aresetn, FREQ_HZ 62500000" *)
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 aclk CLK" *) input wire aclk,
    (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 aresetn RST" *) input wire aresetn,
    (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME refclk100, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 refclk100 CLK" *) input wire refclk100,
    input wire cam_pclk, cam_href, cam_vsync,
    input wire [7:0] cam_data,
    output wire cam_xclk,
    input wire [5:0] s_axi_awaddr, s_axi_araddr,
    input wire [2:0] s_axi_awprot, s_axi_arprot,
    input wire s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    output wire s_axi_awready, s_axi_wready, s_axi_arready,
    output reg [1:0] s_axi_bresp, s_axi_rresp,
    output reg s_axi_bvalid, s_axi_rvalid,
    output reg [31:0] s_axi_rdata,
    (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 2, TUSER_WIDTH 1, HAS_TLAST 1, HAS_TREADY 1" *)
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis TDATA" *) output wire [15:0] m_axis_tdata,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis TSTRB" *) output wire [1:0] m_axis_tstrb,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis TVALID" *) output wire m_axis_tvalid,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis TREADY" *) input wire m_axis_tready,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis TUSER" *) output wire m_axis_tuser,
    (* X_INTERFACE_INFO="xilinx.com:interface:axis:1.0 m_axis TLAST" *) output wire m_axis_tlast
);
    wire clock_locked, locked_a, pclk;
    reg rx_enable;
    wire rx_locked, rx_locked_a, rx_reset;
    reg rx_was_locked, rx_loss_sticky;
    reg [31:0] rx_lock_losses;
    ov7670_pclk_conditioner return_clock (.pclk_in(cam_pclk), .enable(aresetn && rx_enable), .pclk_out(pclk), .locked(rx_locked));
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1))
        rx_lock_sync (.src_clk(pclk),.src_in(rx_locked),.dest_clk(aclk),.dest_out(rx_locked_a));
    xpm_cdc_async_rst #(.DEST_SYNC_FF(4),.INIT_SYNC_FF(0),.RST_ACTIVE_HIGH(1))
        rx_reset_sync (.src_arst(!aresetn || !rx_enable || !rx_locked),.dest_clk(aclk),.dest_arst(rx_reset));
    always @(posedge aclk) begin
        if (!aresetn) begin rx_was_locked<=0; rx_loss_sticky<=0; rx_lock_losses<=0; end
        else begin
            rx_was_locked<=rx_locked_a;
            if (rx_was_locked && !rx_locked_a) begin rx_loss_sticky<=1; rx_lock_losses<=rx_lock_losses+1; end
        end
    end
    ov7670_camera_clock clock_source (.refclk100(refclk100),.aresetn(aresetn),.cam_xclk(cam_xclk),.locked(clock_locked));
    // Returned PCLK is deskewed/filtered; raw edges do not clock the receiver.
    xpm_cdc_single #(.DEST_SYNC_FF(3),.SRC_INPUT_REG(0),.INIT_SYNC_FF(1))
        lock_sync (.src_clk(refclk100),.src_in(clock_locked),.dest_clk(aclk),.dest_out(locked_a));
    reg capture_en, stat_clear;
    wire clear_busy;
    wire [31:0] cam_status, fifo_status, pclk_count, lost_tokens;
    wire [31:0] frame_count, pixel_count, bad_lines, frame_period, frame_period_max;
    assign m_axis_tstrb=2'b11;
    ov7670_pclk_rx receiver (
        .aclk(aclk),.aresetn(!rx_reset),.pclk(pclk),
        .cam_href(cam_href),.cam_vsync(cam_vsync),.cam_data(cam_data),
        .capture_en(capture_en),.stat_clear(stat_clear),.clear_busy(clear_busy),
        .m_axis_tdata(m_axis_tdata),.m_axis_tvalid(m_axis_tvalid),.m_axis_tready(m_axis_tready),
        .m_axis_tuser(m_axis_tuser),.m_axis_tlast(m_axis_tlast),
        .cam_status(cam_status),.fifo_status(fifo_status),.pclk_count(pclk_count),.lost_tokens(lost_tokens),
        .frame_count(frame_count),.pixel_count(pixel_count),.bad_lines(bad_lines),
        .frame_period(frame_period),.frame_period_max(frame_period_max));

    reg aw_hold,w_hold;
    reg [5:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    assign s_axi_awready=!aw_hold && !s_axi_bvalid;
    assign s_axi_wready=!w_hold && !s_axi_bvalid;
    assign s_axi_arready=!s_axi_rvalid;
    always @(posedge aclk) begin
        if (!aresetn) begin
            capture_en<=0; stat_clear<=0; rx_enable<=0; aw_hold<=0; w_hold<=0;
            awaddr<=0; wdata<=0; wstrb<=0;
            s_axi_bvalid<=0; s_axi_bresp<=0; s_axi_rvalid<=0; s_axi_rresp<=0; s_axi_rdata<=0;
        end else begin
            stat_clear<=0;
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if (s_axi_awready && s_axi_awvalid) begin aw_hold<=1; awaddr<=s_axi_awaddr; end
            if (s_axi_wready && s_axi_wvalid) begin w_hold<=1; wdata<=s_axi_wdata; wstrb<=s_axi_wstrb; end
            if (aw_hold && w_hold && !s_axi_bvalid) begin
                aw_hold<=0; w_hold<=0; s_axi_bvalid<=1; s_axi_bresp<=0;
                if (awaddr==6'h34) begin
                    // Clock changes are rejected while a capture is active.
                    if (wstrb[0] && capture_en && wdata[0]!=rx_enable) s_axi_bresp<=2;
                    else if (wstrb[0]) rx_enable<=wdata[0];
                end else if (awaddr!=0 || (wstrb[0] && wdata[1] && (clear_busy || stat_clear))) s_axi_bresp<=2;
                else if (wstrb[0]) begin capture_en<=wdata[0]; stat_clear<=wdata[1]; end
            end
            if (s_axi_arready && s_axi_arvalid) begin
                s_axi_rvalid<=1; s_axi_rresp<=0;
                case (s_axi_araddr)
                    'h00: s_axi_rdata<={31'd0,capture_en};
                    'h04: s_axi_rdata<=cam_status;
                    'h08: s_axi_rdata<=fifo_status;
                    'h0c: s_axi_rdata<=32'h00030000;
                    'h10: s_axi_rdata<=32'h43414d33;
                    'h14: s_axi_rdata<=pclk_count;
                    'h18: s_axi_rdata<=frame_count;
                    'h1c: s_axi_rdata<=pixel_count;
                    'h20: s_axi_rdata<=lost_tokens;
                    'h24: s_axi_rdata<=bad_lines;
                    'h28: s_axi_rdata<=frame_period;
                    'h2c: s_axi_rdata<=frame_period_max;
                    'h30: s_axi_rdata<={30'd0,clear_busy,locked_a};
                    'h34: s_axi_rdata<={29'd0,rx_loss_sticky,rx_locked_a,rx_enable};
                    'h38: s_axi_rdata<=rx_lock_losses;
                    default: begin s_axi_rdata<=0; s_axi_rresp<=2; end
                endcase
            end
        end
    end
endmodule
