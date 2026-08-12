`timescale 1ns / 1ps

module qr_event_fifo #(
    parameter DATA_WIDTH = 21,
    parameter DEPTH      = 32,
    parameter ADDR_WIDTH = 5
) (
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire [DATA_WIDTH-1:0] s_data,

    output wire                  m_valid,
    input  wire                  m_ready,
    output wire [DATA_WIDTH-1:0] m_data,

    output wire                  full,
    output wire                  empty
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;

    wire push;
    wire pop;

    assign full    = (count == DEPTH);
    assign empty   = (count == 0);
    assign m_valid = !empty;
    assign m_data  = mem[rd_ptr];

    assign s_ready = !full;
    assign push    = s_valid && s_ready;
    assign pop     = m_valid && m_ready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            if (push) begin
                mem[wr_ptr] <= s_data;
                if (wr_ptr == DEPTH-1)
                    wr_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (pop) begin
                if (rd_ptr == DEPTH-1)
                    rd_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule


module qr_event_controller (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        start,

    input  wire        hit_valid,
    output wire        hit_ready,
    input  wire [9:0]  hit_x,
    input  wire [8:0]  hit_y,

    input  wire        row_done_valid,
    output wire        row_done_ready,
    input  wire [8:0]  row_done_y,

    input  wire        scan_vcc_done_valid,
    output wire        scan_vcc_done_ready,

    output wire        fifo_s_valid,
    input  wire        fifo_s_ready,
    output wire [20:0] fifo_s_data,

    input  wire        frame_done_event_handshake,

    output wire        event_busy,
    output reg         processing_done,
    input  wire        error_clear,
    output reg         event_overflow_error,
    output reg         row_order_error,
    output reg         protocol_error
);

    localparam STATE_IDLE       = 2'd0;
    localparam STATE_ACTIVE     = 2'd1;
    localparam STATE_FD_PENDING = 2'd2;
    localparam STATE_DRAIN      = 2'd3;

    localparam EVENT_HIT        = 2'b00;
    localparam EVENT_ROW_DONE   = 2'b01;
    localparam EVENT_FRAME_DONE = 2'b10;

    reg [1:0]  state;
    reg [9:0]  expected_row;
    reg        last_row_seen;
    reg        blocked_valid;
    reg [1:0]  blocked_source;
    reg [18:0] blocked_payload;

    wire active;
    wire multiple_inputs;
    wire selected_hit;
    wire selected_row;
    wire selected_done;
    wire input_blocked;
    wire [1:0]  current_blocked_source;
    wire [18:0] current_blocked_payload;

    assign active = (state == STATE_ACTIVE);

    assign multiple_inputs =
        (hit_valid && row_done_valid) ||
        (hit_valid && scan_vcc_done_valid) ||
        (row_done_valid && scan_vcc_done_valid);

    assign selected_hit =
        active && hit_valid;

    assign selected_row =
        active && !hit_valid && row_done_valid;

    assign selected_done =
        active && !hit_valid && !row_done_valid &&
        scan_vcc_done_valid && last_row_seen;

    assign hit_ready =
        selected_hit && fifo_s_ready;

    assign row_done_ready =
        selected_row && fifo_s_ready;

    assign scan_vcc_done_ready =
        selected_done && fifo_s_ready;

    assign fifo_s_valid =
        (state == STATE_FD_PENDING) ||
        selected_hit ||
        selected_row;

    assign fifo_s_data =
        (state == STATE_FD_PENDING) ?
            {EVENT_FRAME_DONE, 10'd0, 9'd479} :
        selected_hit ?
            {EVENT_HIT, hit_x, hit_y} :
            {EVENT_ROW_DONE, 10'd0, row_done_y};

    assign event_busy =
        (state != STATE_IDLE);

    assign input_blocked =
        (selected_hit && !hit_ready) ||
        (selected_row && !row_done_ready) ||
        (selected_done && !scan_vcc_done_ready);

    assign current_blocked_source =
        selected_hit ? EVENT_HIT :
        selected_row ? EVENT_ROW_DONE :
                       EVENT_FRAME_DONE;

    assign current_blocked_payload =
        selected_hit ? {hit_x, hit_y} :
        selected_row ? {10'd0, row_done_y} :
                       19'd0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state                <= STATE_IDLE;
            expected_row         <= 10'd0;
            last_row_seen        <= 1'b0;
            processing_done      <= 1'b0;
            event_overflow_error <= 1'b0;
            row_order_error      <= 1'b0;
            protocol_error       <= 1'b0;
            blocked_valid        <= 1'b0;
            blocked_source       <= 2'b00;
            blocked_payload      <= 19'd0;
        end else begin
            processing_done <= 1'b0;

            if (error_clear) begin
                event_overflow_error <= 1'b0;
                row_order_error      <= 1'b0;
                protocol_error       <= 1'b0;
            end

            if (state == STATE_IDLE) begin
                blocked_valid <= 1'b0;

                if (hit_valid || row_done_valid || scan_vcc_done_valid)
                    protocol_error <= 1'b1;

                if (start) begin
                    state         <= STATE_ACTIVE;
                    expected_row  <= 10'd0;
                    last_row_seen <= 1'b0;
                end
            end else begin
                if (start)
                    protocol_error <= 1'b1;

                if (multiple_inputs)
                    protocol_error <= 1'b1;

                if ((state == STATE_ACTIVE) &&
                    scan_vcc_done_valid && !last_row_seen)
                    protocol_error <= 1'b1;

                if (blocked_valid) begin
                    if ((!selected_hit && !selected_row && !selected_done) ||
                        (blocked_source != current_blocked_source) ||
                        (blocked_payload != current_blocked_payload)) begin
                        event_overflow_error <= 1'b1;
                        blocked_valid <= 1'b0;
                    end else if ((selected_hit && hit_ready) ||
                                 (selected_row && row_done_ready) ||
                                 (selected_done && scan_vcc_done_ready)) begin
                        blocked_valid <= 1'b0;
                    end
                end else if (input_blocked) begin
                    blocked_valid   <= 1'b1;
                    blocked_source  <= current_blocked_source;
                    blocked_payload <= current_blocked_payload;
                end
            end

            case (state)
                STATE_IDLE: begin
                end

                STATE_ACTIVE: begin
                    if (hit_valid && hit_ready) begin
                        if ((hit_x >= 10'd640) ||
                            (hit_y >= 9'd480))
                            protocol_error <= 1'b1;
                    end

                    if (row_done_valid && row_done_ready) begin
                        if ({1'b0, row_done_y} != expected_row)
                            row_order_error <= 1'b1;

                        if (row_done_y == 9'd479) begin
                            last_row_seen <= 1'b1;
                            expected_row  <= 10'd480;
                        end else begin
                            expected_row <= expected_row + 1'b1;
                        end
                    end

                    if (scan_vcc_done_valid &&
                        scan_vcc_done_ready)
                        state <= STATE_FD_PENDING;
                end

                STATE_FD_PENDING: begin
                    if (fifo_s_valid && fifo_s_ready)
                        state <= STATE_DRAIN;
                end

                STATE_DRAIN: begin
                    if (frame_done_event_handshake) begin
                        processing_done <= 1'b1;
                        state           <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule


module qr_event_controller_top #(
    parameter integer EVENT_FIFO_DEPTH = 32,
    parameter integer EVENT_FIFO_ADDR_WIDTH = 5
)(
    input  wire       aclk,
    input  wire       aresetn,
    input  wire       start,

    input  wire       hit_valid,
    output wire       hit_ready,
    input  wire [9:0] hit_x,
    input  wire [8:0] hit_y,

    input  wire       row_done_valid,
    output wire       row_done_ready,
    input  wire [8:0] row_done_y,

    input  wire       scan_vcc_done_valid,
    output wire       scan_vcc_done_ready,

    output wire       event_valid,
    input  wire       event_ready,
    output wire [1:0] event_type,
    output wire [9:0] event_x,
    output wire [8:0] event_y,

    output wire       event_busy,
    output wire       processing_done,

    input  wire       error_clear,
    output wire       event_overflow_error,
    output wire       row_order_error,
    output wire       protocol_error,

    output wire       fifo_full,
    output wire       fifo_empty
);

    wire        fifo_s_valid;
    wire        fifo_s_ready;
    wire [20:0] fifo_s_data;

    wire        fifo_m_valid;
    wire        fifo_m_ready;
    wire [20:0] fifo_m_data;

    wire frame_done_event_handshake;

    assign fifo_m_ready = event_ready;

    assign event_valid = fifo_m_valid;
    assign event_type  = fifo_m_data[20:19];
    assign event_x     = fifo_m_data[18:9];
    assign event_y     = fifo_m_data[8:0];

    assign frame_done_event_handshake =
        fifo_m_valid &&
        fifo_m_ready &&
        (fifo_m_data[20:19] == 2'b10);

    qr_event_controller u_event_controller (
        .aclk                       (aclk),
        .aresetn                    (aresetn),
        .start                      (start),

        .hit_valid                  (hit_valid),
        .hit_ready                  (hit_ready),
        .hit_x                      (hit_x),
        .hit_y                      (hit_y),

        .row_done_valid             (row_done_valid),
        .row_done_ready             (row_done_ready),
        .row_done_y                 (row_done_y),

        .scan_vcc_done_valid        (scan_vcc_done_valid),
        .scan_vcc_done_ready        (scan_vcc_done_ready),

        .fifo_s_valid               (fifo_s_valid),
        .fifo_s_ready               (fifo_s_ready),
        .fifo_s_data                (fifo_s_data),

        .frame_done_event_handshake (frame_done_event_handshake),

        .event_busy                 (event_busy),
        .processing_done            (processing_done),

        .error_clear                (error_clear),
        .event_overflow_error       (event_overflow_error),
        .row_order_error            (row_order_error),
        .protocol_error             (protocol_error)
    );

    qr_event_fifo #(
        .DATA_WIDTH (21),
        .DEPTH      (EVENT_FIFO_DEPTH),
        .ADDR_WIDTH (EVENT_FIFO_ADDR_WIDTH)
    ) u_event_fifo (
        .aclk    (aclk),
        .aresetn (aresetn),

        .s_valid (fifo_s_valid),
        .s_ready (fifo_s_ready),
        .s_data  (fifo_s_data),

        .m_valid (fifo_m_valid),
        .m_ready (fifo_m_ready),
        .m_data  (fifo_m_data),

        .full    (fifo_full),
        .empty   (fifo_empty)
    );
endmodule


module qr_sparse_ccl #(
    parameter integer MAX_HITS             = 256,
    parameter integer HIT_ADDR_WIDTH       = 8,
    parameter integer HIT_COUNT_WIDTH      = 9,
    parameter integer MAX_LABELS           = 32,
    parameter integer LABEL_WIDTH          = 5,
    parameter integer LABEL_COUNT_WIDTH    = 6,
    parameter [9:0]   X_LINK_THRESHOLD     = 10'd4,
    parameter [8:0]   Y_LINK_THRESHOLD     = 9'd2
) (
    input  wire                         aclk,
    input  wire                         aresetn,
    input  wire                         start,

    input  wire                         event_valid,
    output wire                         event_ready,
    input  wire [1:0]                   event_type,
    input  wire [9:0]                   event_x,
    input  wire [8:0]                   event_y,

    output wire                         labeled_hit_valid,
    input  wire                         labeled_hit_ready,
    output wire [9:0]                   labeled_hit_x,
    output wire [8:0]                   labeled_hit_y,
    output wire [LABEL_WIDTH-1:0]       labeled_hit_label,
    output wire                         labeled_hit_last,

    output wire                         ccl_done_valid,
    input  wire                         ccl_done_ready,

    output wire                         ccl_busy,
    output wire [HIT_COUNT_WIDTH-1:0]   stored_hit_count,
    output wire [LABEL_COUNT_WIDTH-1:0] allocated_label_count,

    input  wire                         error_clear,
    output reg                          hit_overflow_error,
    output reg                          label_overflow_error,
    output reg                          protocol_error
);

    localparam [2:0] STATE_IDLE     = 3'd0;
    localparam [2:0] STATE_WAIT     = 3'd1;
    localparam [2:0] STATE_SCAN     = 3'd2;
    localparam [2:0] STATE_CLASSIFY = 3'd3;
    localparam [2:0] STATE_OUTPUT   = 3'd4;
    localparam [2:0] STATE_DONE     = 3'd5;

    localparam [1:0] EVENT_HIT        = 2'b00;
    localparam [1:0] EVENT_ROW_DONE   = 2'b01;
    localparam [1:0] EVENT_FRAME_DONE = 2'b10;

    reg [2:0] state;

    reg [9:0]                   hit_x_mem     [0:MAX_HITS-1];
    reg [8:0]                   hit_y_mem     [0:MAX_HITS-1];
    reg [LABEL_WIDTH-1:0]       hit_label_mem [0:MAX_HITS-1];
    reg [LABEL_WIDTH-1:0]       label_parent  [0:MAX_LABELS-1];

    reg [HIT_COUNT_WIDTH-1:0]   hit_count;
    reg [LABEL_COUNT_WIDTH-1:0] label_count;

    reg [9:0]                   pending_x;
    reg [8:0]                   pending_y;
    reg [HIT_ADDR_WIDTH-1:0]    scan_index;
    reg [MAX_LABELS-1:0]        merge_mask;
    reg [HIT_ADDR_WIDTH-1:0]    output_index;

    wire                        event_handshake;
    wire                        scan_x_match;
    wire                        scan_y_match;
    wire [9:0]                  scan_dx;
    wire [8:0]                  scan_dy;
    wire [LABEL_WIDTH-1:0]      scan_root_label;

    reg                         selected_label_valid;
    reg [LABEL_WIDTH-1:0]       selected_label;

    integer select_index;
    integer merge_index;
    integer reset_index;

    assign event_ready     = (state == STATE_WAIT);
    assign event_handshake = event_valid && event_ready;

    assign labeled_hit_valid = (state == STATE_OUTPUT);
    assign labeled_hit_x =
        hit_x_mem[output_index];
    assign labeled_hit_y =
        hit_y_mem[output_index];
    assign labeled_hit_label =
        label_parent[hit_label_mem[output_index]];
    assign labeled_hit_last =
        (state == STATE_OUTPUT) &&
        (output_index == (hit_count - 1'b1));

    assign ccl_done_valid = (state == STATE_DONE);
    assign ccl_busy       = (state != STATE_IDLE);

    assign stored_hit_count      = hit_count;
    assign allocated_label_count = label_count;

    assign scan_dx =
        (pending_x >= hit_x_mem[scan_index]) ?
        (pending_x - hit_x_mem[scan_index]) :
        (hit_x_mem[scan_index] - pending_x);

    assign scan_dy =
        (pending_y >= hit_y_mem[scan_index]) ?
        (pending_y - hit_y_mem[scan_index]) :
        (hit_y_mem[scan_index] - pending_y);

    assign scan_x_match =
        (scan_dx <= X_LINK_THRESHOLD);

    assign scan_y_match =
        (scan_dy <= Y_LINK_THRESHOLD);

    assign scan_root_label =
        label_parent[hit_label_mem[scan_index]];

    always @(*) begin
        selected_label_valid = 1'b0;
        selected_label       = {LABEL_WIDTH{1'b0}};

        for (select_index = 0;
             select_index < MAX_LABELS;
             select_index = select_index + 1) begin
            if (!selected_label_valid &&
                merge_mask[select_index]) begin
                selected_label_valid = 1'b1;
                selected_label       = select_index;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            state                <= STATE_IDLE;
            hit_count            <= {HIT_COUNT_WIDTH{1'b0}};
            label_count          <= {LABEL_COUNT_WIDTH{1'b0}};
            pending_x            <= 10'd0;
            pending_y            <= 9'd0;
            scan_index           <= {HIT_ADDR_WIDTH{1'b0}};
            merge_mask           <= {MAX_LABELS{1'b0}};
            output_index         <= {HIT_ADDR_WIDTH{1'b0}};
            hit_overflow_error   <= 1'b0;
            label_overflow_error <= 1'b0;
            protocol_error       <= 1'b0;

            for (reset_index = 0;
                 reset_index < MAX_LABELS;
                 reset_index = reset_index + 1) begin
                label_parent[reset_index] <= reset_index;
            end
        end else begin
            if (error_clear) begin
                hit_overflow_error   <= 1'b0;
                label_overflow_error <= 1'b0;
                protocol_error       <= 1'b0;
            end

            if ((state != STATE_IDLE) && start)
                protocol_error <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    if (event_valid)
                        protocol_error <= 1'b1;

                    if (start) begin
                        state         <= STATE_WAIT;
                        hit_count     <= {HIT_COUNT_WIDTH{1'b0}};
                        label_count   <= {LABEL_COUNT_WIDTH{1'b0}};
                        merge_mask    <= {MAX_LABELS{1'b0}};
                        scan_index    <= {HIT_ADDR_WIDTH{1'b0}};
                        output_index  <= {HIT_ADDR_WIDTH{1'b0}};
                    end
                end

                STATE_WAIT: begin
                    if (event_handshake) begin
                        case (event_type)
                            EVENT_HIT: begin
                                if ((event_x >= 10'd640) ||
                                    (event_y >= 9'd480)) begin
                                    protocol_error <= 1'b1;
                                end else if (hit_count == MAX_HITS) begin
                                    hit_overflow_error <= 1'b1;
                                end else begin
                                    pending_x   <= event_x;
                                    pending_y   <= event_y;
                                    scan_index  <= {HIT_ADDR_WIDTH{1'b0}};
                                    merge_mask <= {MAX_LABELS{1'b0}};

                                    if (hit_count == 0)
                                        state <= STATE_CLASSIFY;
                                    else
                                        state <= STATE_SCAN;
                                end
                            end

                            EVENT_ROW_DONE: begin
                                if (event_x != 10'd0)
                                    protocol_error <= 1'b1;
                            end

                            EVENT_FRAME_DONE: begin
                                if ((event_x != 10'd0) ||
                                    (event_y != 9'd479))
                                    protocol_error <= 1'b1;

                                output_index <=
                                    {HIT_ADDR_WIDTH{1'b0}};

                                if (hit_count == 0)
                                    state <= STATE_DONE;
                                else
                                    state <= STATE_OUTPUT;
                            end

                            default: begin
                                protocol_error <= 1'b1;
                            end
                        endcase
                    end
                end

                STATE_SCAN: begin
                    if (scan_x_match && scan_y_match)
                        merge_mask[scan_root_label] <= 1'b1;

                    if (scan_index == (hit_count - 1'b1))
                        state <= STATE_CLASSIFY;
                    else
                        scan_index <= scan_index + 1'b1;
                end

                STATE_CLASSIFY: begin
                    if (selected_label_valid) begin
                        hit_x_mem[
                            hit_count[HIT_ADDR_WIDTH-1:0]
                        ] <= pending_x;

                        hit_y_mem[
                            hit_count[HIT_ADDR_WIDTH-1:0]
                        ] <= pending_y;

                        hit_label_mem[
                            hit_count[HIT_ADDR_WIDTH-1:0]
                        ] <= selected_label;

                        hit_count <= hit_count + 1'b1;

                        for (merge_index = 0;
                             merge_index < MAX_LABELS;
                             merge_index = merge_index + 1) begin
                            if ((merge_index < label_count) &&
                                merge_mask[
                                    label_parent[merge_index]
                                ])
                                label_parent[merge_index]
                                    <= selected_label;
                        end
                    end else if (label_count == MAX_LABELS) begin
                        label_overflow_error <= 1'b1;
                    end else begin
                        hit_x_mem[
                            hit_count[HIT_ADDR_WIDTH-1:0]
                        ] <= pending_x;

                        hit_y_mem[
                            hit_count[HIT_ADDR_WIDTH-1:0]
                        ] <= pending_y;

                        hit_label_mem[
                            hit_count[HIT_ADDR_WIDTH-1:0]
                        ] <= label_count;

                        label_parent[label_count]
                            <= label_count;

                        hit_count   <= hit_count + 1'b1;
                        label_count <= label_count + 1'b1;
                    end

                    state <= STATE_WAIT;
                end

                STATE_OUTPUT: begin
                    if (labeled_hit_valid &&
                        labeled_hit_ready) begin
                        if (labeled_hit_last)
                            state <= STATE_DONE;
                        else
                            output_index <= output_index + 1'b1;
                    end
                end

                STATE_DONE: begin
                    if (ccl_done_valid &&
                        ccl_done_ready)
                        state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end
endmodule



/*
 * ============================================================================
 * Module : qr_object_properties
 *
 * Purpose
 *   qr_sparse_ccl의 labeled HIT Stream을 Label별로 누적하여
 *   Bounding Box, HIT Count, 좌표 합을 출력한다.
 *
 * Input connection from qr_sparse_ccl
 *   labeled_hit_valid / labeled_hit_ready
 *   labeled_hit_x[9:0]
 *   labeled_hit_y[8:0]
 *   labeled_hit_label[LABEL_WIDTH-1:0]
 *   labeled_hit_last
 *   ccl_done_valid / ccl_done_ready
 *
 * Label rule
 *   Sparse CCL에서는 Label 0도 정상 객체 Label이다.
 *   유효 범위는 0 ~ MAX_LABELS-1이다.
 *
 * Output rule
 *   hit_count >= MIN_RECORD_HITS인 Label만 Label 오름차순으로 출력한다.
 *   property_valid && !property_ready 동안 모든 Property 필드를 유지한다.
 *   마지막 Property 출력 후 properties_done_valid/ready Handshake를 수행한다.
 *
 * Reset
 *   aresetn : Active-Low
 *
 * RTL coding restriction
 *   synthesizable RTL 내부 task/function 미사용
 * ============================================================================
 */
module qr_object_properties #(
    parameter integer MAX_HITS           = 256,
    parameter integer HIT_COUNT_WIDTH     = 19,

    parameter integer MAX_LABELS          = 32,
    parameter integer LABEL_WIDTH         = 5,
    parameter integer LABEL_ADDR_WIDTH    = 5,
    parameter integer LABEL_COUNT_WIDTH   = 6,

    parameter integer SUM_X_WIDTH         = 28,
    parameter integer SUM_Y_WIDTH         = 28,

    parameter integer MIN_RECORD_HITS     = 3
)(
    input  wire                         aclk,
    input  wire                         aresetn,

    /*
     * Frame control
     * start는 IDLE에서만 수락하는 1클록 Pulse다.
     */
    input  wire                         start,

    /*
     * Labeled HIT input from qr_sparse_ccl
     */
    input  wire                         labeled_hit_valid,
    output wire                         labeled_hit_ready,
    input  wire [9:0]                   labeled_hit_x,
    input  wire [8:0]                   labeled_hit_y,
    input  wire [LABEL_WIDTH-1:0]       labeled_hit_label,
    input  wire                         labeled_hit_last,

    /*
     * CCL completion Handshake
     */
    input  wire                         ccl_done_valid,
    output wire                         ccl_done_ready,

    /*
     * Property output
     */
    output wire                         property_valid,
    input  wire                         property_ready,

    output wire [LABEL_WIDTH-1:0]       property_label,
    output wire [9:0]                   property_min_x,
    output wire [9:0]                   property_max_x,
    output wire [8:0]                   property_min_y,
    output wire [8:0]                   property_max_y,
    output wire [HIT_COUNT_WIDTH-1:0]   property_hit_count,
    output wire [SUM_X_WIDTH-1:0]       property_sum_x,
    output wire [SUM_Y_WIDTH-1:0]       property_sum_y,

    /*
     * Final completion
     */
    output wire                         properties_done_valid,
    input  wire                         properties_done_ready,

    /*
     * Status
     */
    output wire                         properties_busy,
    output reg  [HIT_COUNT_WIDTH-1:0]   accumulated_hit_count,
    output reg  [LABEL_COUNT_WIDTH-1:0] qualified_property_count,

    /*
     * Sticky errors
     */
    input  wire                         error_clear,
    output reg                          accumulation_overflow_error,
    output reg                          protocol_error
);

    /*
     * FSM
     */
    localparam [2:0] STATE_IDLE   = 3'd0;
    localparam [2:0] STATE_ACCUM  = 3'd1;
    localparam [2:0] STATE_SCAN   = 3'd2;
    localparam [2:0] STATE_OUTPUT = 3'd3;
    localparam [2:0] STATE_DONE   = 3'd4;

    reg [2:0] state;

    /*
     * Per-Label Property memories
     */
    reg [9:0] min_x_mem [0:MAX_LABELS-1];
    reg [9:0] max_x_mem [0:MAX_LABELS-1];
    reg [8:0] min_y_mem [0:MAX_LABELS-1];
    reg [8:0] max_y_mem [0:MAX_LABELS-1];

    reg [HIT_COUNT_WIDTH-1:0] hit_count_mem [0:MAX_LABELS-1];
    reg [SUM_X_WIDTH-1:0]     sum_x_mem     [0:MAX_LABELS-1];
    reg [SUM_Y_WIDTH-1:0]     sum_y_mem     [0:MAX_LABELS-1];

    /*
     * Scan and output registers
     */
    reg [LABEL_ADDR_WIDTH-1:0] scan_label;

    reg [LABEL_WIDTH-1:0]     property_label_reg;
    reg [9:0]                 property_min_x_reg;
    reg [9:0]                 property_max_x_reg;
    reg [8:0]                 property_min_y_reg;
    reg [8:0]                 property_max_y_reg;
    reg [HIT_COUNT_WIDTH-1:0] property_hit_count_reg;
    reg [SUM_X_WIDTH-1:0]     property_sum_x_reg;
    reg [SUM_Y_WIDTH-1:0]     property_sum_y_reg;

    reg                       saw_last;

    integer i;

    /*
     * Constant-width values
     */
    localparam [HIT_COUNT_WIDTH-1:0] HIT_COUNT_MAX =
        {HIT_COUNT_WIDTH{1'b1}};

    localparam [SUM_X_WIDTH-1:0] SUM_X_MAX =
        {SUM_X_WIDTH{1'b1}};

    localparam [SUM_Y_WIDTH-1:0] SUM_Y_MAX =
        {SUM_Y_WIDTH{1'b1}};

    localparam [HIT_COUNT_WIDTH-1:0] MAX_HITS_VALUE =
        MAX_HITS;

    localparam [HIT_COUNT_WIDTH-1:0] MIN_RECORD_HITS_VALUE =
        MIN_RECORD_HITS;

    wire [LABEL_ADDR_WIDTH-1:0] input_label_index;
    assign input_label_index =
        labeled_hit_label[LABEL_ADDR_WIDTH-1:0];

    wire label_in_range;
    assign label_in_range =
        (labeled_hit_label < MAX_LABELS);

    wire coordinate_in_range;
    assign coordinate_in_range =
        (labeled_hit_x < 10'd640) &&
        (labeled_hit_y < 9'd480);

    wire [SUM_X_WIDTH-1:0] labeled_hit_x_ext;
    wire [SUM_Y_WIDTH-1:0] labeled_hit_y_ext;

    assign labeled_hit_x_ext =
        {{(SUM_X_WIDTH-10){1'b0}}, labeled_hit_x};

    assign labeled_hit_y_ext =
        {{(SUM_Y_WIDTH-9){1'b0}}, labeled_hit_y};

    wire labeled_hit_handshake;
    wire ccl_done_handshake;
    wire property_handshake;
    wire properties_done_handshake;

    assign labeled_hit_ready =
        (state == STATE_ACCUM);

    /*
     * 같은 클록에 HIT와 CCL Done을 동시에 수락하지 않는다.
     */
    assign ccl_done_ready =
        (state == STATE_ACCUM) &&
        !labeled_hit_valid;

    assign property_valid =
        (state == STATE_OUTPUT);

    assign properties_done_valid =
        (state == STATE_DONE);

    assign properties_busy =
        (state != STATE_IDLE);

    assign labeled_hit_handshake =
        labeled_hit_valid &&
        labeled_hit_ready;

    assign ccl_done_handshake =
        ccl_done_valid &&
        ccl_done_ready;

    assign property_handshake =
        property_valid &&
        property_ready;

    assign properties_done_handshake =
        properties_done_valid &&
        properties_done_ready;

    assign property_label =
        property_label_reg;

    assign property_min_x =
        property_min_x_reg;

    assign property_max_x =
        property_max_x_reg;

    assign property_min_y =
        property_min_y_reg;

    assign property_max_y =
        property_max_y_reg;

    assign property_hit_count =
        property_hit_count_reg;

    assign property_sum_x =
        property_sum_x_reg;

    assign property_sum_y =
        property_sum_y_reg;

    wire current_label_qualified;
    assign current_label_qualified =
        (hit_count_mem[scan_label] >= MIN_RECORD_HITS_VALUE);

    /*
     * Main sequential logic
     */
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state                       <= STATE_IDLE;
            scan_label                  <= {LABEL_ADDR_WIDTH{1'b0}};
            saw_last                    <= 1'b0;

            accumulated_hit_count       <= {HIT_COUNT_WIDTH{1'b0}};
            qualified_property_count    <= {LABEL_COUNT_WIDTH{1'b0}};

            property_label_reg          <= {LABEL_WIDTH{1'b0}};
            property_min_x_reg          <= 10'd0;
            property_max_x_reg          <= 10'd0;
            property_min_y_reg          <= 9'd0;
            property_max_y_reg          <= 9'd0;
            property_hit_count_reg      <= {HIT_COUNT_WIDTH{1'b0}};
            property_sum_x_reg          <= {SUM_X_WIDTH{1'b0}};
            property_sum_y_reg          <= {SUM_Y_WIDTH{1'b0}};

            accumulation_overflow_error <= 1'b0;
            protocol_error              <= 1'b0;

            for (i = 0; i < MAX_LABELS; i = i + 1) begin
                min_x_mem[i]     <= 10'd0;
                max_x_mem[i]     <= 10'd0;
                min_y_mem[i]     <= 9'd0;
                max_y_mem[i]     <= 9'd0;
                hit_count_mem[i] <= {HIT_COUNT_WIDTH{1'b0}};
                sum_x_mem[i]     <= {SUM_X_WIDTH{1'b0}};
                sum_y_mem[i]     <= {SUM_Y_WIDTH{1'b0}};
            end
        end
        else begin
            /*
             * Sticky error clear
             */
            if (error_clear) begin
                accumulation_overflow_error <= 1'b0;
                protocol_error              <= 1'b0;
            end

            /*
             * Inputs outside their valid operating state are protocol errors.
             */
            if ((state != STATE_IDLE) && start)
                protocol_error <= 1'b1;

            if ((state != STATE_ACCUM) && labeled_hit_valid)
                protocol_error <= 1'b1;

            if ((state != STATE_ACCUM) && ccl_done_valid)
                protocol_error <= 1'b1;

            case (state)
                STATE_IDLE: begin
                    if (labeled_hit_valid || ccl_done_valid)
                        protocol_error <= 1'b1;

                    if (start) begin
                        scan_label               <= {LABEL_ADDR_WIDTH{1'b0}};
                        saw_last                 <= 1'b0;
                        accumulated_hit_count    <= {HIT_COUNT_WIDTH{1'b0}};
                        qualified_property_count <= {LABEL_COUNT_WIDTH{1'b0}};

                        property_label_reg       <= {LABEL_WIDTH{1'b0}};
                        property_min_x_reg       <= 10'd0;
                        property_max_x_reg       <= 10'd0;
                        property_min_y_reg       <= 9'd0;
                        property_max_y_reg       <= 9'd0;
                        property_hit_count_reg   <= {HIT_COUNT_WIDTH{1'b0}};
                        property_sum_x_reg       <= {SUM_X_WIDTH{1'b0}};
                        property_sum_y_reg       <= {SUM_Y_WIDTH{1'b0}};

                        for (i = 0; i < MAX_LABELS; i = i + 1) begin
                            min_x_mem[i]     <= 10'd0;
                            max_x_mem[i]     <= 10'd0;
                            min_y_mem[i]     <= 9'd0;
                            max_y_mem[i]     <= 9'd0;
                            hit_count_mem[i] <= {HIT_COUNT_WIDTH{1'b0}};
                            sum_x_mem[i]     <= {SUM_X_WIDTH{1'b0}};
                            sum_y_mem[i]     <= {SUM_Y_WIDTH{1'b0}};
                        end

                        state <= STATE_ACCUM;
                    end
                end

                STATE_ACCUM: begin
                    if (labeled_hit_handshake) begin
                        /*
                         * last 이후 추가 HIT는 소비하되 Property에는 반영하지 않는다.
                         */
                        if (saw_last) begin
                            protocol_error <= 1'b1;
                        end
                        else begin
                            if (labeled_hit_last)
                                saw_last <= 1'b1;

                            if (!label_in_range ||
                                !coordinate_in_range) begin
                                protocol_error <= 1'b1;
                            end
                            else if (accumulated_hit_count >=
                                     MAX_HITS_VALUE) begin
                                accumulation_overflow_error <= 1'b1;
                            end
                            else begin
                                accumulated_hit_count <=
                                    accumulated_hit_count + 1'b1;

                                /*
                                 * First HIT initializes the Bounding Box.
                                 */
                                if (hit_count_mem[input_label_index] == 0) begin
                                    min_x_mem[input_label_index] <=
                                        labeled_hit_x;
                                    max_x_mem[input_label_index] <=
                                        labeled_hit_x;
                                    min_y_mem[input_label_index] <=
                                        labeled_hit_y;
                                    max_y_mem[input_label_index] <=
                                        labeled_hit_y;
                                end
                                else begin
                                    if (labeled_hit_x <
                                        min_x_mem[input_label_index])
                                        min_x_mem[input_label_index] <=
                                            labeled_hit_x;

                                    if (labeled_hit_x >
                                        max_x_mem[input_label_index])
                                        max_x_mem[input_label_index] <=
                                            labeled_hit_x;

                                    if (labeled_hit_y <
                                        min_y_mem[input_label_index])
                                        min_y_mem[input_label_index] <=
                                            labeled_hit_y;

                                    if (labeled_hit_y >
                                        max_y_mem[input_label_index])
                                        max_y_mem[input_label_index] <=
                                            labeled_hit_y;
                                end

                                /*
                                 * Per-Label count overflow protection.
                                 */
                                if (hit_count_mem[input_label_index] ==
                                    HIT_COUNT_MAX) begin
                                    accumulation_overflow_error <= 1'b1;
                                end
                                else begin
                                    hit_count_mem[input_label_index] <=
                                        hit_count_mem[input_label_index] +
                                        1'b1;
                                end

                                /*
                                 * Sum overflow protection. Wrap-around하지 않고
                                 * 최대값으로 Saturation한다.
                                 */
                                if (sum_x_mem[input_label_index] >
                                    (SUM_X_MAX - labeled_hit_x_ext)) begin
                                    sum_x_mem[input_label_index] <=
                                        SUM_X_MAX;
                                    accumulation_overflow_error <= 1'b1;
                                end
                                else begin
                                    sum_x_mem[input_label_index] <=
                                        sum_x_mem[input_label_index] +
                                        labeled_hit_x_ext;
                                end

                                if (sum_y_mem[input_label_index] >
                                    (SUM_Y_MAX - labeled_hit_y_ext)) begin
                                    sum_y_mem[input_label_index] <=
                                        SUM_Y_MAX;
                                    accumulation_overflow_error <= 1'b1;
                                end
                                else begin
                                    sum_y_mem[input_label_index] <=
                                        sum_y_mem[input_label_index] +
                                        labeled_hit_y_ext;
                                end
                            end
                        end
                    end

                    if (ccl_done_handshake) begin
                        /*
                         * 빈 Frame은 last가 없어도 정상이다.
                         * HIT가 있었다면 labeled_hit_last를 확인한다.
                         */
                        if ((accumulated_hit_count != 0) &&
                            !saw_last)
                            protocol_error <= 1'b1;

                        scan_label <= {LABEL_ADDR_WIDTH{1'b0}};
                        state      <= STATE_SCAN;
                    end
                end

                STATE_SCAN: begin
                    if (current_label_qualified) begin
                        /*
                         * scan_label이 더 좁은 경우 Verilog의 자동
                         * Zero-extension을 사용한다.
                         */
                        property_label_reg <= scan_label;

                        property_min_x_reg <= min_x_mem[scan_label];
                        property_max_x_reg <= max_x_mem[scan_label];
                        property_min_y_reg <= min_y_mem[scan_label];
                        property_max_y_reg <= max_y_mem[scan_label];

                        property_hit_count_reg <=
                            hit_count_mem[scan_label];

                        property_sum_x_reg <=
                            sum_x_mem[scan_label];

                        property_sum_y_reg <=
                            sum_y_mem[scan_label];

                        state <= STATE_OUTPUT;
                    end
                    else begin
                        if (scan_label == MAX_LABELS-1) begin
                            state <= STATE_DONE;
                        end
                        else begin
                            scan_label <= scan_label + 1'b1;
                        end
                    end
                end

                STATE_OUTPUT: begin
                    /*
                     * 출력 Register는 Handshake 전까지 변경하지 않는다.
                     */
                    if (property_handshake) begin
                        qualified_property_count <=
                            qualified_property_count + 1'b1;

                        if (scan_label == MAX_LABELS-1) begin
                            state <= STATE_DONE;
                        end
                        else begin
                            scan_label <= scan_label + 1'b1;
                            state      <= STATE_SCAN;
                        end
                    end
                end

                STATE_DONE: begin
                    if (properties_done_handshake)
                        state <= STATE_IDLE;
                end

                default: begin
                    state          <= STATE_IDLE;
                    protocol_error <= 1'b1;
                end
            endcase
        end
    end

endmodule
