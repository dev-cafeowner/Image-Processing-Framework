`timescale 1ns/1ps
// Common video infrastructure, independent of QR/Barcode feature extraction.
// RGB888 AXIS -> optional gray + opaque, double-buffered monochrome bitmap HUD.
// Little-endian bitmap: first pixel in bit 0. Bank stride 0x2000 bytes.
// All ports use aclk. Monitor inputs only observe the accepted camera stream.
module video_preview_overlay #(
    parameter integer WIDTH = 640,
    parameter integer HEIGHT = 480,
    parameter integer HUD_HEIGHT = 64,
    parameter integer HUD_TIMEOUT_CYCLES = 31250000
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis:s_axi, ASSOCIATED_RESET aresetn" *)
    input wire aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *) input wire aresetn,
    input wire [23:0] s_axis_tdata, input wire s_axis_tvalid,
    output wire s_axis_tready, input wire s_axis_tuser, input wire s_axis_tlast,
    output wire [23:0] m_axis_tdata, output wire m_axis_tvalid,
    input wire m_axis_tready, output wire m_axis_tuser, output wire m_axis_tlast,
    input wire [14:0] s_axi_awaddr, input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid, input wire s_axi_bready,
    input wire [14:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready,
    input wire camera_valid, input wire camera_ready, input wire camera_sof
);
    localparam integer WORDS = (WIDTH * HUD_HEIGHT + 31) / 32;
    // Allocate physical bank strides for inexpensive address decoding.
    (* ram_style = "block" *) reg [31:0] bitmap [0:4095];
    reg aw_hold, w_hold;
    reg [14:0] aw_addr;
    reg [31:0] w_data;
    reg [3:0] w_strb;
    reg [2:0] config_active, config_pending;
    reg pending;
    reg [31:0] commits, rejected, hud_age;
    reg [31:0] ticks, camera_count, scan_count, camera_last, scan_last;
    reg [31:0] camera_period, scan_period, camera_max, scan_max;
    reg [31:0] geometry_errors;
    reg [11:0] x, y;
    reg [18:0] position;
    wire [11:0] px = s_axis_tuser ? 12'd0 : x;
    wire [11:0] py = s_axis_tuser ? 12'd0 : y;
    wire [18:0] pos = s_axis_tuser ? 19'd0 : position;
    wire [2:0] pixel_config = (s_axis_tuser && pending) ? config_pending : config_active;
    reg frame_hud_fresh;
    wire hud_fresh = s_axis_tuser ? (pending || hud_age < HUD_TIMEOUT_CYCLES) : frame_hud_fresh;
    wire [11:0] bitmap_index = {pixel_config[2],11'b0} + pos[15:5];
    wire [15:0] luminance = 16'd77 * s_axis_tdata[23:16] +
                           16'd150 * s_axis_tdata[15:8] + 16'd29 * s_axis_tdata[7:0];

    // One elastic stage with synchronous RAM read. RAM data and pixel metadata
    // advance together; all output fields remain stable under backpressure.
    reg valid_q, user_q, last_q, hud_q, gray_q;
    reg [23:0] rgb_q;
    reg [7:0] luma_q;
    reg [4:0] bit_q;
    reg [31:0] bitmap_q;
    assign s_axis_tready = !valid_q || m_axis_tready;
    wire fire = s_axis_tvalid && s_axis_tready;
    wire frame_start = fire && s_axis_tuser;
    assign m_axis_tvalid = valid_q;
    assign m_axis_tuser = user_q;
    assign m_axis_tlast = last_q;
    assign m_axis_tdata = hud_q ? {24{bitmap_q[bit_q]}} :
                         gray_q ? {luma_q,luma_q,luma_q} : rgb_q;
    always @(posedge aclk) begin
        if (s_axis_tready && s_axis_tvalid)
            bitmap_q <= bitmap[bitmap_index];
    end
    always @(posedge aclk) begin
        if (!aresetn) begin
            valid_q <= 0; user_q <= 0; last_q <= 0; hud_q <= 0; gray_q <= 0;
            rgb_q <= 0; luma_q <= 0; bit_q <= 0;
            x <= 0; y <= 0; position <= 0; geometry_errors <= 0; frame_hud_fresh <= 0;
        end else begin
            if (s_axis_tready) begin
                valid_q <= s_axis_tvalid;
                if (s_axis_tvalid) begin
                    rgb_q <= s_axis_tdata; luma_q <= luminance[15:8];
                    bit_q <= pos[4:0]; user_q <= s_axis_tuser; last_q <= s_axis_tlast;
                    hud_q <= pixel_config[0] && hud_fresh && py < HUD_HEIGHT;
                    gray_q <= pixel_config[1];
                end
            end
            if (fire) begin
                if (s_axis_tuser) frame_hud_fresh <= hud_fresh;
                if (s_axis_tlast != (px == WIDTH-1) || py >= HEIGHT)
                    geometry_errors <= geometry_errors + 1;
                x <= s_axis_tlast ? 12'd0 : px + 1'b1;
                y <= s_axis_tlast ? py + 1'b1 : py;
                position <= pos + 1'b1;
            end
        end
    end

    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready = !w_hold && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;
    wire write_fire = aw_hold && w_hold && !s_axi_bvalid;
    wire bitmap_address = aw_addr >= 15'h2000 && aw_addr < 15'h6000;
    wire write_bank = aw_addr[14]; // bank0 0x2000, bank1 0x4000
    wire [10:0] bank_word = aw_addr[12:2];
    wire [11:0] write_index = {write_bank, bank_word};
    wire bitmap_ok = bitmap_address && bank_word < WORDS && aw_addr[1:0] == 0 &&
                     !(config_active[0] && write_bank == config_active[2]) &&
                     !(pending && write_bank == config_pending[2]);
    integer lane;
    // Separate RAM write process enables simple dual-port BRAM inference.
    always @(posedge aclk) begin
        if (aresetn && write_fire && bitmap_ok)
            for (lane=0; lane<4; lane=lane+1)
                if (w_strb[lane]) bitmap[write_index][lane*8 +: 8] <= w_data[lane*8 +: 8];
    end
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_hold <= 0; w_hold <= 0; aw_addr <= 0; w_data <= 0; w_strb <= 0;
            s_axi_bvalid <= 0; s_axi_bresp <= 0;
            s_axi_rvalid <= 0; s_axi_rdata <= 0; s_axi_rresp <= 0;
            config_active <= 3'b010; config_pending <= 3'b010; pending <= 0;
            commits <= 0; rejected <= 0; hud_age <= HUD_TIMEOUT_CYCLES;
            ticks <= 0; camera_count <= 0; scan_count <= 0;
            camera_last <= 0; scan_last <= 0; camera_period <= 0; scan_period <= 0;
            camera_max <= 0; scan_max <= 0;
        end else begin
            ticks <= ticks + 1;
            if (hud_age < HUD_TIMEOUT_CYCLES) hud_age <= hud_age + 1;
            if (camera_valid && camera_ready && camera_sof) begin
                camera_count <= camera_count + 1; camera_last <= ticks;
                if (camera_count != 0) begin
                    camera_period <= ticks - camera_last;
                    if (ticks-camera_last > camera_max) camera_max <= ticks-camera_last;
                end
            end
            if (frame_start) begin
                scan_count <= scan_count + 1; scan_last <= ticks;
                if (scan_count != 0) begin
                    scan_period <= ticks - scan_last;
                    if (ticks-scan_last > scan_max) scan_max <= ticks-scan_last;
                end
                if (pending) begin
                    config_active <= config_pending; pending <= 0;
                    commits <= commits + 1; hud_age <= 0;
                end
            end
            if (s_axi_awvalid && s_axi_awready) begin aw_hold <= 1; aw_addr <= s_axi_awaddr; end
            if (s_axi_wvalid && s_axi_wready) begin w_hold <= 1; w_data <= s_axi_wdata; w_strb <= s_axi_wstrb; end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (write_fire) begin
                aw_hold <= 0; w_hold <= 0; s_axi_bvalid <= 1; s_axi_bresp <= 0;
                if (bitmap_ok) begin end
                else if (aw_addr == 15'h8 && w_strb == 4'hf && !pending && w_data[31:3] == 0) begin
                    config_pending <= w_data[2:0]; pending <= 1;
                end else begin s_axi_bresp <= 2'b10; rejected <= rejected + 1; end
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1; s_axi_rresp <= 0;
                case (s_axi_araddr)
                    15'h00: s_axi_rdata <= 32'h50525631; // PRV1
                    15'h04: s_axi_rdata <= {28'b0,pending,config_active};
                    15'h0c: s_axi_rdata <= commits;
                    15'h10: s_axi_rdata <= camera_count;
                    15'h14: s_axi_rdata <= scan_count;
                    15'h18: s_axi_rdata <= camera_period;
                    15'h1c: s_axi_rdata <= scan_period;
                    15'h20: s_axi_rdata <= camera_max;
                    15'h24: s_axi_rdata <= scan_max;
                    15'h28: s_axi_rdata <= rejected;
                    15'h2c: s_axi_rdata <= geometry_errors;
                    15'h30: s_axi_rdata <= hud_age;
                    15'h34: s_axi_rdata <= ticks;
                    default: begin s_axi_rdata <= 0; s_axi_rresp <= 2'b10; end
                endcase
            end
        end
    end
endmodule
