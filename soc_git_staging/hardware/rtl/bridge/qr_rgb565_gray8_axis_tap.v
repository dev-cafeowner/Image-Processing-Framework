`timescale 1ns / 1ps
/*
 * AXI RGB565 pass-through with a passive Gray8 DMA tap.
 *
 * The Front-End path owns backpressure. A pixel is converted only when the
 * RGB565 beat is actually accepted by the Front-End (TVALID && TREADY).
 * Four Gray8 pixels are packed into one 32-bit word in little-endian byte-lane
 * order: first pixel -> TDATA[7:0].
 *
 * The image DMA must be armed before capture_enable is asserted. A local FIFO
 * absorbs short TREADY stalls without backpressuring the camera path.
 */
module qr_rgb565_gray8_axis_tap #(
    parameter integer FIFO_DEPTH = 128,
    parameter integer FIFO_AW = 7,
    parameter integer EXPECTED_WORDS = 76800
)(
    input  wire         aclk,
    input  wire         aresetn,

    input  wire [11:0]  cfg_width,
    input  wire [11:0]  cfg_height,
    input  wire         capture_enable,
    input  wire         frame_slot_available,
    input  wire [31:0]  next_frame_id,
    input  wire         stat_clear,

    input  wire [15:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tuser,
    input  wire         s_axis_tlast,

    output wire [15:0]  m_fe_axis_tdata,
    output wire         m_fe_axis_tvalid,
    input  wire         m_fe_axis_tready,
    output wire         m_fe_axis_tuser,
    output wire         m_fe_axis_tlast,

    output wire [31:0]  m_img_axis_tdata,
    output wire         m_img_axis_tvalid,
    input  wire         m_img_axis_tready,
    output wire [3:0]   m_img_axis_tkeep,
    output wire         m_img_axis_tuser,
    output wire         m_img_axis_tlast,

    output wire         frame_sof_accept,
    output wire         image_tx_done,
    output reg  [31:0]  image_frame_id,
    output reg  [16:0]  image_word_count,

    output reg          image_overflow_error,
    output reg          image_frame_drop_error,
    output reg          image_geometry_error
);
    localparam [7:0] COEF_R = 8'd77;
    localparam [7:0] COEF_G = 8'd150;
    localparam [7:0] COEF_B = 8'd29;

    assign m_fe_axis_tdata  = s_axis_tdata;
    assign m_fe_axis_tvalid = s_axis_tvalid;
    assign m_fe_axis_tuser  = s_axis_tuser;
    assign m_fe_axis_tlast  = s_axis_tlast;
    assign s_axis_tready    = m_fe_axis_tready;

    wire rgb_fire = s_axis_tvalid && s_axis_tready;
    assign frame_sof_accept =
        rgb_fire &&
        s_axis_tuser &&
        capture_enable &&
        frame_slot_available;

    wire [4:0] r5 = s_axis_tdata[15:11];
    wire [5:0] g6 = s_axis_tdata[10:5];
    wire [4:0] b5 = s_axis_tdata[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};

    wire [15:0] mul_r = r8 * COEF_R;
    wire [15:0] mul_g = g8 * COEF_G;
    wire [15:0] mul_b = b8 * COEF_B;

    reg [15:0] s1_r;
    reg [15:0] s1_g;
    reg [15:0] s1_b;
    reg        s1_valid;
    reg        s1_user;
    reg        s1_last;
    reg        s1_accept;
    reg [31:0] s1_frame_id;

    reg [7:0]  gray_data;
    reg        gray_valid;
    reg        gray_user;
    reg        gray_last;
    reg        gray_accept;
    reg [31:0] gray_frame_id;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s1_r <= 16'd0;
            s1_g <= 16'd0;
            s1_b <= 16'd0;
            s1_valid <= 1'b0;
            s1_user <= 1'b0;
            s1_last <= 1'b0;
            s1_accept <= 1'b0;
            s1_frame_id <= 32'd0;

            gray_data <= 8'd0;
            gray_valid <= 1'b0;
            gray_user <= 1'b0;
            gray_last <= 1'b0;
            gray_accept <= 1'b0;
            gray_frame_id <= 32'd0;
        end
        else begin
            s1_valid <= rgb_fire;
            if (rgb_fire) begin
                s1_r <= mul_r;
                s1_g <= mul_g;
                s1_b <= mul_b;
                s1_user <= s_axis_tuser;
                s1_last <= s_axis_tlast;
                s1_accept <=
                    s_axis_tuser &&
                    capture_enable &&
                    frame_slot_available;
                s1_frame_id <= next_frame_id;
            end

            gray_valid <= s1_valid;
            if (s1_valid) begin
                gray_data <= (s1_r + s1_g + s1_b) >> 8;
                gray_user <= s1_user;
                gray_last <= s1_last;
                gray_accept <= s1_accept;
                gray_frame_id <= s1_frame_id;
            end
        end
    end

    reg        capturing;
    reg [1:0]  byte_count;
    reg [31:0] pack_reg;
    reg [11:0] row_count;
    reg        first_word_pending;

    wire start_gray =
        gray_valid &&
        gray_user &&
        gray_accept;

    wire active_gray =
        gray_valid &&
        (capturing || start_gray);

    wire [1:0] byte_eff =
        start_gray ? 2'd0 : byte_count;

    wire [11:0] row_eff =
        start_gray ? 12'd0 : row_count;

    reg [31:0] pack_next;
    always @(*) begin
        case (byte_eff)
            2'd0: pack_next = {24'd0, gray_data};
            2'd1: pack_next = {16'd0, gray_data, pack_reg[7:0]};
            2'd2: pack_next = {8'd0, gray_data, pack_reg[15:0]};
            default: pack_next = {gray_data, pack_reg[23:0]};
        endcase
    end

    wire word_ready = active_gray && (byte_eff == 2'd3);
    wire last_row = (row_eff == cfg_height - 12'd1);
    wire frame_end = active_gray && gray_last && last_row;

    reg [31:0] fifo_data [0:FIFO_DEPTH-1];
    reg [3:0]  fifo_keep [0:FIFO_DEPTH-1];
    reg        fifo_user [0:FIFO_DEPTH-1];
    reg        fifo_last [0:FIFO_DEPTH-1];

    reg [FIFO_AW-1:0] wr_ptr;
    reg [FIFO_AW-1:0] rd_ptr;
    reg [FIFO_AW:0] fifo_count;

    wire fifo_empty = (fifo_count == 0);
    wire fifo_full = (fifo_count == FIFO_DEPTH);

    assign m_img_axis_tvalid = !fifo_empty;
    assign m_img_axis_tdata = fifo_data[rd_ptr];
    assign m_img_axis_tkeep = fifo_keep[rd_ptr];
    assign m_img_axis_tuser = fifo_user[rd_ptr];
    assign m_img_axis_tlast = fifo_last[rd_ptr];

    wire fifo_pop =
        m_img_axis_tvalid &&
        m_img_axis_tready;

    wire fifo_can_push =
        !fifo_full ||
        fifo_pop;

    wire fifo_push =
        word_ready &&
        fifo_can_push;

    assign image_tx_done =
        fifo_pop &&
        m_img_axis_tlast;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            capturing <= 1'b0;
            byte_count <= 2'd0;
            pack_reg <= 32'd0;
            row_count <= 12'd0;
            first_word_pending <= 1'b0;

            wr_ptr <= {FIFO_AW{1'b0}};
            rd_ptr <= {FIFO_AW{1'b0}};
            fifo_count <= {(FIFO_AW+1){1'b0}};

            image_frame_id <= 32'd0;
            image_word_count <= 17'd0;

            image_overflow_error <= 1'b0;
            image_frame_drop_error <= 1'b0;
            image_geometry_error <= 1'b0;
        end
        else begin
            if (stat_clear) begin
                image_overflow_error <= 1'b0;
                image_frame_drop_error <= 1'b0;
                image_geometry_error <= 1'b0;
            end

            if (rgb_fire && s_axis_tuser &&
                !(capture_enable && frame_slot_available))
                image_frame_drop_error <= 1'b1;

            if (gray_valid && gray_user) begin
                if (gray_accept) begin
                    if (!fifo_empty)
                        image_geometry_error <= 1'b1;

                    capturing <= 1'b1;
                    byte_count <= 2'd0;
                    pack_reg <= 32'd0;
                    row_count <= 12'd0;
                    image_frame_id <= gray_frame_id;
                    image_word_count <= 17'd0;
                    first_word_pending <= 1'b1;
                end
                else begin
                    capturing <= 1'b0;
                end
            end

            if (active_gray) begin
                pack_reg <= pack_next;

                if (word_ready) begin
                    byte_count <= 2'd0;
                    if (fifo_can_push) begin
                        image_word_count <= image_word_count + 17'd1;
                        if (first_word_pending)
                            first_word_pending <= 1'b0;
                    end
                    else
                        image_overflow_error <= 1'b1;
                end
                else begin
                    byte_count <= byte_eff + 2'd1;
                end

                if (gray_last) begin
                    if (byte_eff != 2'd3)
                        image_geometry_error <= 1'b1;

                    if (last_row) begin
                        capturing <= 1'b0;
                        if (image_word_count != EXPECTED_WORDS - 1)
                            image_geometry_error <= 1'b1;
                    end
                    else begin
                        row_count <= row_eff + 12'd1;
                    end
                end
            end

            if (fifo_push) begin
                fifo_data[wr_ptr] <= pack_next;
                fifo_keep[wr_ptr] <= 4'hF;
                fifo_user[wr_ptr] <= first_word_pending;
                fifo_last[wr_ptr] <= frame_end;

                if (wr_ptr == FIFO_DEPTH-1)
                    wr_ptr <= {FIFO_AW{1'b0}};
                else
                    wr_ptr <= wr_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
            end
            else if (word_ready && !fifo_can_push) begin
                image_overflow_error <= 1'b1;
            end

            if (fifo_pop) begin
                if (rd_ptr == FIFO_DEPTH-1)
                    rd_ptr <= {FIFO_AW{1'b0}};
                else
                    rd_ptr <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
            end

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + {{FIFO_AW{1'b0}}, 1'b1};
                2'b01: fifo_count <= fifo_count - {{FIFO_AW{1'b0}}, 1'b1};
                default: fifo_count <= fifo_count;
            endcase
        end
    end
endmodule
