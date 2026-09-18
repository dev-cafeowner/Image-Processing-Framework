`timescale 1ns/1ps
// Diagnostic-only identity marks. Camera instance sits on the preview branch
// BEFORE VDMA, never on Gray8/binary QR input. Scan instance is AFTER the HUD.
// 48 MSB-first cells, x=128..511, eight pixels/cell: preamble, ID, ~ID, check.
// Two camera bands expose mixed-frame tearing. IDs wrap modulo 65536.
module video_frame_tag #(
    parameter integer SCAN_TAG = 0
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis, ASSOCIATED_RESET aresetn" *) input wire aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *) input wire aresetn,
    input wire [23:0] s_axis_tdata, input wire s_axis_tvalid,
    output wire s_axis_tready, input wire s_axis_tuser, input wire s_axis_tlast,
    output reg [23:0] m_axis_tdata, output reg m_axis_tvalid,
    input wire m_axis_tready, output reg m_axis_tuser, output reg m_axis_tlast
);
    reg [15:0] frame_id;
    reg [9:0] x,y;
    wire [9:0] px=s_axis_tuser ? 10'd0:x;
    wire [9:0] py=s_axis_tuser ? 10'd0:y;
    localparam [7:0] PREAMBLE=SCAN_TAG ? 8'ha6:8'hd3;
    // Tag bands never contain SOF. Use the registered ID, without an adder in
    // the pixel path. Power-of-two cells avoid a wide constant divide/multiply.
    wire [47:0] code={PREAMBLE,frame_id,~frame_id,(frame_id[15:8]^frame_id[7:0]^PREAMBLE^8'h5a)};
    wire band=SCAN_TAG ? (py>=464 && py<476):
                         ((py>=64 && py<76)||(py>=448 && py<460));
    wire is_tag_pixel=band && px>=128 && px<512;
    wire [5:0] cell_index=px[8:3]-6'd16;
    wire [5:0] bit_index=6'd47-cell_index;
    wire bit_value=code[bit_index];
    assign s_axis_tready=!m_axis_tvalid || m_axis_tready;
    always @(posedge aclk) begin
        if(!aresetn) begin
            frame_id<=0;x<=0;y<=0;
            m_axis_tvalid<=0;m_axis_tdata<=0;m_axis_tuser<=0;m_axis_tlast<=0;
        end else if(s_axis_tready) begin
            m_axis_tvalid<=s_axis_tvalid;
            if(s_axis_tvalid) begin
                m_axis_tdata<=is_tag_pixel ? {24{bit_value}}:s_axis_tdata;
                m_axis_tuser<=s_axis_tuser;m_axis_tlast<=s_axis_tlast;
                if(s_axis_tuser) frame_id<=frame_id+16'd1;
                x<=s_axis_tlast ? 10'd0:px+10'd1;
                y<=s_axis_tlast ? py+10'd1:py;
            end
        end
    end
endmodule
