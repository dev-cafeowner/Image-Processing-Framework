`timescale 1ns / 1ps

// Sparse HIT connected-component labeling stage.
//
// The module consumes the 21-bit Event Stream produced by
// qr_event_controller_top.  HIT events are stored and compared sequentially
// against earlier HITs.  Two HITs belong to the same component when both
// |dx| <= X_LINK_THRESHOLD and |dy| <= Y_LINK_THRESHOLD.
//
// Provisional labels are merged with a flat parent table.  After FRAME_DONE,
// every stored HIT is replayed in input order with its final root label.  This
// labeled stream is intended for the following Object Properties stage.
module qr_sparse_ccl #(
    parameter integer MAX_HITS            = 256,
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

    assign scan_x_match = (scan_dx <= X_LINK_THRESHOLD);
    assign scan_y_match = (scan_dy <= Y_LINK_THRESHOLD);
    assign scan_root_label =
        label_parent[hit_label_mem[scan_index]];

    // Lowest numbered matching root becomes the canonical label.
    always @(*) begin
        selected_label_valid = 1'b0;
        selected_label       = {LABEL_WIDTH{1'b0}};

        for (select_index = 0;
             select_index < MAX_LABELS;
             select_index = select_index + 1) begin
            if (!selected_label_valid && merge_mask[select_index]) begin
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
                        state        <= STATE_WAIT;
                        hit_count    <= {HIT_COUNT_WIDTH{1'b0}};
                        label_count  <= {LABEL_COUNT_WIDTH{1'b0}};
                        merge_mask  <= {MAX_LABELS{1'b0}};
                        scan_index  <= {HIT_ADDR_WIDTH{1'b0}};
                        output_index <= {HIT_ADDR_WIDTH{1'b0}};
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
                                    // Consume and drop excess HITs so that the
                                    // frame can still reach FRAME_DONE.
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
                                // ROW_DONE is a sequencing marker.  The Event
                                // Controller already checks row order.
                                if (event_x != 10'd0)
                                    protocol_error <= 1'b1;
                            end

                            EVENT_FRAME_DONE: begin
                                if ((event_x != 10'd0) ||
                                    (event_y != 9'd479))
                                    protocol_error <= 1'b1;

                                output_index <= {HIT_ADDR_WIDTH{1'b0}};
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
                        hit_x_mem[hit_count[HIT_ADDR_WIDTH-1:0]]
                            <= pending_x;
                        hit_y_mem[hit_count[HIT_ADDR_WIDTH-1:0]]
                            <= pending_y;
                        hit_label_mem[hit_count[HIT_ADDR_WIDTH-1:0]]
                            <= selected_label;
                        hit_count <= hit_count + 1'b1;

                        // Keep the parent table flat.  Every label whose root
                        // participated in this connection is redirected to the
                        // smallest matching root.
                        for (merge_index = 0;
                             merge_index < MAX_LABELS;
                             merge_index = merge_index + 1) begin
                            if ((merge_index < label_count) &&
                                merge_mask[label_parent[merge_index]])
                                label_parent[merge_index] <= selected_label;
                        end
                    end else if (label_count == MAX_LABELS) begin
                        // A new isolated component cannot be represented.
                        // Consume the HIT but do not store it.
                        label_overflow_error <= 1'b1;
                    end else begin
                        hit_x_mem[hit_count[HIT_ADDR_WIDTH-1:0]]
                            <= pending_x;
                        hit_y_mem[hit_count[HIT_ADDR_WIDTH-1:0]]
                            <= pending_y;
                        hit_label_mem[hit_count[HIT_ADDR_WIDTH-1:0]]
                            <= label_count;
                        label_parent[label_count]
                            <= label_count;
                        hit_count   <= hit_count + 1'b1;
                        label_count <= label_count + 1'b1;
                    end

                    state <= STATE_WAIT;
                end

                STATE_OUTPUT: begin
                    if (labeled_hit_valid && labeled_hit_ready) begin
                        if (labeled_hit_last)
                            state <= STATE_DONE;
                        else
                            output_index <= output_index + 1'b1;
                    end
                end

                STATE_DONE: begin
                    if (ccl_done_valid && ccl_done_ready)
                        state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
