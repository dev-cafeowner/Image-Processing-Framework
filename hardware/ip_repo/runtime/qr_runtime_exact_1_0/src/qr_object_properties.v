`timescale 1ns / 1ps

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
