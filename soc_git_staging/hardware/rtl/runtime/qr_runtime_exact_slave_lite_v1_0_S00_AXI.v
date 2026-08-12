`timescale 1 ns / 1 ps

/*
 * ============================================================================
 * Module : qr_runtime_exact_slave_lite_v1_0_S00_AXI
 *
 * AXI4-Lite transport shell for qr_runtime_exact.
 *
 * This module intentionally does NOT implement the QR register semantics.
 * It converts AXI4-Lite transactions into a small internal CSR bus:
 *
 *   write : csr_wr_en / csr_wr_addr / csr_wr_data / csr_wr_strb
 *   read  : csr_rd_addr -> csr_rd_data
 *
 * qr_runtime_csr_core is instantiated one level above this module.
 *
 * Notes
 *   - 32-bit AXI4-Lite data width is assumed by the CSR interface.
 *   - 6-bit byte address supports 0x00 .. 0x3C.
 *   - One outstanding write and one outstanding read are supported.
 *   - AW and W may arrive independently.
 * ============================================================================
 */

module qr_runtime_exact_slave_lite_v1_0_S00_AXI #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6
)(
    // -------------------------------------------------------------------------
    // Internal CSR bridge
    // -------------------------------------------------------------------------
    output reg                          csr_wr_en,
    output reg  [C_S_AXI_ADDR_WIDTH-1:0] csr_wr_addr,
    output reg  [31:0]                 csr_wr_data,
    output reg  [3:0]                  csr_wr_strb,

    output wire [C_S_AXI_ADDR_WIDTH-1:0] csr_rd_addr,
    input  wire [31:0]                 csr_rd_data,

    // -------------------------------------------------------------------------
    // AXI4-Lite
    // -------------------------------------------------------------------------
    input  wire                         S_AXI_ACLK,
    input  wire                         S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire [2:0]                   S_AXI_AWPROT,
    input  wire                         S_AXI_AWVALID,
    output wire                         S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                         S_AXI_WVALID,
    output wire                         S_AXI_WREADY,

    output wire [1:0]                   S_AXI_BRESP,
    output wire                         S_AXI_BVALID,
    input  wire                         S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire [2:0]                   S_AXI_ARPROT,
    input  wire                         S_AXI_ARVALID,
    output wire                         S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output wire [1:0]                   S_AXI_RRESP,
    output wire                         S_AXI_RVALID,
    input  wire                         S_AXI_RREADY
);

    // Protection attributes are not used by this peripheral.
    wire unused_prot;
    assign unused_prot = ^{S_AXI_AWPROT, S_AXI_ARPROT};

    // =========================================================================
    // Write channel
    // =========================================================================

    reg [C_S_AXI_ADDR_WIDTH-1:0] awaddr_hold;
    reg                          aw_hold_valid;

    reg [31:0]                   wdata_hold;
    reg [3:0]                    wstrb_hold;
    reg                          w_hold_valid;

    reg                          bvalid_reg;

    wire aw_fire;
    wire w_fire;
    wire have_aw;
    wire have_w;
    wire write_commit;

    /*
     * Do not accept another write transaction while a BRESP is outstanding.
     * AW and W themselves may arrive in either order.
     */
    assign S_AXI_AWREADY = !aw_hold_valid && !bvalid_reg;
    assign S_AXI_WREADY  = !w_hold_valid  && !bvalid_reg;

    assign aw_fire = S_AXI_AWVALID && S_AXI_AWREADY;
    assign w_fire  = S_AXI_WVALID  && S_AXI_WREADY;

    assign have_aw = aw_hold_valid || aw_fire;
    assign have_w  = w_hold_valid  || w_fire;

    /*
     * Commit exactly once when both address and data are available.
     */
    assign write_commit = have_aw && have_w && !bvalid_reg;

    assign S_AXI_BVALID = bvalid_reg;
    assign S_AXI_BRESP  = 2'b00; // OKAY

    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            awaddr_hold  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            aw_hold_valid <= 1'b0;

            wdata_hold   <= 32'd0;
            wstrb_hold   <= 4'd0;
            w_hold_valid <= 1'b0;

            bvalid_reg   <= 1'b0;

            csr_wr_en    <= 1'b0;
            csr_wr_addr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            csr_wr_data  <= 32'd0;
            csr_wr_strb  <= 4'd0;
        end
        else begin
            // csr_wr_en is a one-clock pulse.
            csr_wr_en <= 1'b0;

            // Capture AW independently.
            if (aw_fire) begin
                awaddr_hold   <= S_AXI_AWADDR;
                aw_hold_valid <= 1'b1;
            end

            // Capture W independently.
            if (w_fire) begin
                wdata_hold   <= S_AXI_WDATA[31:0];
                wstrb_hold   <= S_AXI_WSTRB[3:0];
                w_hold_valid <= 1'b1;
            end

            // Once both pieces exist, emit one CSR write transaction.
            if (write_commit) begin
                csr_wr_en   <= 1'b1;
                csr_wr_addr <= aw_fire ? S_AXI_AWADDR       : awaddr_hold;
                csr_wr_data <= w_fire  ? S_AXI_WDATA[31:0] : wdata_hold;
                csr_wr_strb <= w_fire  ? S_AXI_WSTRB[3:0]  : wstrb_hold;

                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;
                bvalid_reg    <= 1'b1;
            end

            // Complete write response.
            if (bvalid_reg && S_AXI_BREADY)
                bvalid_reg <= 1'b0;
        end
    end

    // =========================================================================
    // Read channel
    // =========================================================================

    reg [C_S_AXI_ADDR_WIDTH-1:0] araddr_hold;
    reg                          rvalid_reg;

    wire ar_fire;

    /*
     * One outstanding read. A new address is accepted after the previous
     * RVALID/RREADY handshake completes.
     */
    assign S_AXI_ARREADY = !rvalid_reg;
    assign ar_fire       = S_AXI_ARVALID && S_AXI_ARREADY;

    assign S_AXI_RVALID  = rvalid_reg;
    assign S_AXI_RRESP   = 2'b00; // OKAY

    /*
     * qr_runtime_csr_core uses byte addresses (0x00, 0x04, ... 0x3C).
     * Preserve the AXI byte address exactly; do not convert it to a word index.
     */
    assign csr_rd_addr = araddr_hold;

    /*
     * CSR read data is combinational in qr_runtime_csr_core and remains stable
     * because araddr_hold is held for the complete read response.
     */
    assign S_AXI_RDATA = csr_rd_data;

    always @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
        if (!S_AXI_ARESETN) begin
            araddr_hold <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            rvalid_reg  <= 1'b0;
        end
        else begin
            if (ar_fire) begin
                araddr_hold <= S_AXI_ARADDR;
                rvalid_reg  <= 1'b1;
            end

            if (rvalid_reg && S_AXI_RREADY)
                rvalid_reg <= 1'b0;
        end
    end

endmodule
