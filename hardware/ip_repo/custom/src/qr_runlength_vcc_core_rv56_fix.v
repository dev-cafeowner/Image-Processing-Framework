`timescale 1ns / 1ps

/*
 * QR Run-Length / Vertical Cross-Check Core
 * - 125 MHz single clock domain
 * - Binary Frame BRAM Port B, READ_LATENCY_B=1
 * - Safe ROW_DONE ready-valid
 * - scan_vcc_done ready-valid
 * - RV-56 line-end final-run flush fix included
 *
 * Simulation top used with:
 *   tb_qr_runlength_vcc_frontend_p1qr
 */

/* ==================== qr_run_length_scan ==================== */
module qr_run_length_scan (
    input  wire        clk,
    input  wire        reset_p,

    input  wire        pixel_valid,
    input  wire        binary_pixel,

    input  wire [9:0]  pixel_x,
    input  wire [8:0]  pixel_y,

    input  wire        line_start,
    input  wire        line_end,

    output reg         run_valid,
    output reg         run_color,
    output reg  [9:0]  run_length,
    output reg  [9:0]  run_end_x,
    output reg  [8:0]  run_y,

    output reg         pattern_valid,
    output reg  [9:0]  candidate_x,
    output reg  [8:0]  candidate_y,
    output reg  [12:0] pattern_total,

    output reg  [9:0]  pattern_run0,
    output reg  [9:0]  pattern_run1,
    output reg  [9:0]  pattern_run2,
    output reg  [9:0]  pattern_run3,
    output reg  [9:0]  pattern_run4
);

    reg       run_active;
    reg       current_color;
    reg [9:0] current_length;

    reg [9:0] previous_run0;
    reg [9:0] previous_run1;
    reg [9:0] previous_run2;
    reg [9:0] previous_run3;

    reg [2:0] completed_run_count;

    wire [13:0] run0_value;
    wire [13:0] run1_value;
    wire [13:0] run2_value;
    wire [13:0] run3_value;
    wire [13:0] run4_value;

    wire [13:0] run0_mul7;
    wire [13:0] run1_mul7;
    wire [13:0] run2_mul7;
    wire [13:0] run3_mul7;
    wire [13:0] run4_mul7;

    wire [13:0] total_value;
    wire [13:0] total_mul3;

    wire [13:0] error0;
    wire [13:0] error1;
    wire [13:0] error2;
    wire [13:0] error3;
    wire [13:0] error4;

    wire [13:0] normal_tolerance;
    wire [13:0] center_tolerance;

    wire ratio_match;

    assign run0_value = {4'd0, previous_run0};
    assign run1_value = {4'd0, previous_run1};
    assign run2_value = {4'd0, previous_run2};
    assign run3_value = {4'd0, previous_run3};
    /*
     * RV-56 Line-End Flush:
     * 같은 색의 마지막 픽셀이 line_end에서 들어오면
     * current_length 레지스터에는 아직 그 픽셀이 반영되지 않았다.
     * 조합 비교용 run4_value만 현재 픽셀 1개를 미리 포함한다.
     */
    assign run4_value =
        {4'd0, current_length} +
        ((pixel_valid && line_end && run_active &&
          (binary_pixel == current_color)) ? 14'd1 : 14'd0);

    assign run0_mul7 = (run0_value << 3) - run0_value;
    assign run1_mul7 = (run1_value << 3) - run1_value;
    assign run2_mul7 = (run2_value << 3) - run2_value;
    assign run3_mul7 = (run3_value << 3) - run3_value;
    assign run4_mul7 = (run4_value << 3) - run4_value;

    assign total_value = run0_value + run1_value + run2_value + run3_value + run4_value;

    assign total_mul3 = (total_value << 1) + total_value;

    assign error0 = (run0_mul7 >= total_value) ? run0_mul7 - total_value : total_value - run0_mul7;
    assign error1 = (run1_mul7 >= total_value) ? run1_mul7 - total_value : total_value - run1_mul7;
    assign error2 = (run2_mul7 >= total_mul3) ? run2_mul7 - total_mul3 : total_mul3 - run2_mul7;
    assign error3 = (run3_mul7 >= total_value) ? run3_mul7 - total_value : total_value - run3_mul7;
    assign error4 = (run4_mul7 >= total_value) ? run4_mul7 - total_value : total_value - run4_mul7;

    assign normal_tolerance = total_value >> 2;
    assign center_tolerance = total_value >> 1;

    assign ratio_match = (completed_run_count >= 3'd4) && (current_color == 1'b1) &&
                         (previous_run0 != 10'd0) &&
                         (previous_run1 != 10'd0) &&
                         (previous_run2 != 10'd0) &&
                         (previous_run3 != 10'd0) &&
                         (current_length != 10'd0) &&
                         (error0 <= normal_tolerance) &&
                         (error1 <= normal_tolerance) &&
                         (error2 <= center_tolerance) &&
                         (error3 <= normal_tolerance) &&
                         (error4 <= normal_tolerance);

    always @(posedge clk or posedge reset_p) begin
        if (reset_p) begin
            run_active          <= 1'b0;
            current_color       <= 1'b0;
            current_length      <= 10'd0;

            previous_run0       <= 10'd0;
            previous_run1       <= 10'd0;
            previous_run2       <= 10'd0;
            previous_run3       <= 10'd0;

            completed_run_count <= 3'd0;

            run_valid           <= 1'b0;
            run_color           <= 1'b0;
            run_length          <= 10'd0;
            run_end_x           <= 10'd0;
            run_y               <= 9'd0;

            pattern_valid       <= 1'b0;
            candidate_x         <= 10'd0;
            candidate_y         <= 9'd0;
            pattern_total       <= 13'd0;

            pattern_run0        <= 10'd0;
            pattern_run1        <= 10'd0;
            pattern_run2        <= 10'd0;
            pattern_run3        <= 10'd0;
            pattern_run4        <= 10'd0;
        end
        else begin
            run_valid     <= 1'b0;
            pattern_valid <= 1'b0;

            if (pixel_valid) begin
                if (line_start) begin
                    run_active     <= 1'b1;
                    current_color  <= binary_pixel;
                    current_length <= 10'd1;

                    previous_run0 <= 10'd0;
                    previous_run1 <= 10'd0;
                    previous_run2 <= 10'd0;
                    previous_run3 <= 10'd0;

                    completed_run_count <= 3'd0;
                end
                else if (run_active) begin
                    if (binary_pixel == current_color) begin
                        current_length <= current_length + 10'd1;

                        if (line_end) begin
                            run_valid  <= 1'b1;
                            run_color  <= current_color;
                            run_length <= current_length + 10'd1;
                            run_end_x  <= pixel_x;
                            run_y      <= pixel_y;

                            /*
                             * RV-56:
                             * 행 마지막 픽셀까지 포함한 다섯 번째 Run으로
                             * 1:1:3:1:1을 검사한다.
                             */
                            if (ratio_match) begin
                                pattern_valid <= 1'b1;

                                /*
                                 * 현재 pixel_x는 마지막 Run의 마지막 픽셀이다.
                                 * current_length는 현재 픽셀을 제외한 길이이므로
                                 * 아래 식이 중심 좌표를 정확히 계산한다.
                                 */
                                candidate_x <=
                                    pixel_x -
                                    current_length -
                                    previous_run3 -
                                    (previous_run2 >> 1);

                                candidate_y   <= pixel_y;
                                pattern_total <= total_value[12:0];

                                pattern_run0 <= previous_run0;
                                pattern_run1 <= previous_run1;
                                pattern_run2 <= previous_run2;
                                pattern_run3 <= previous_run3;
                                pattern_run4 <= current_length + 10'd1;
                            end

                            run_active <= 1'b0;
                        end
                    end
                    else begin
                        run_valid  <= 1'b1;
                        run_color  <= current_color;
                        run_length <= current_length;
                        run_end_x  <= pixel_x - 10'd1;
                        run_y      <= pixel_y;

                        if (ratio_match) begin
                            pattern_valid <= 1'b1;

                            candidate_x <= pixel_x - current_length - previous_run3 - (previous_run2 >> 1);

                            candidate_y   <= pixel_y;
                            pattern_total <= total_value[12:0];

                            pattern_run0 <= previous_run0;
                            pattern_run1 <= previous_run1;
                            pattern_run2 <= previous_run2;
                            pattern_run3 <= previous_run3;
                            pattern_run4 <= current_length;
                        end

                        previous_run0 <= previous_run1;
                        previous_run1 <= previous_run2;
                        previous_run2 <= previous_run3;
                        previous_run3 <= current_length;

                        if (completed_run_count < 3'd4) begin
                            completed_run_count <= completed_run_count + 3'd1;
                        end

                        current_color  <= binary_pixel;
                        current_length <= 10'd1;

                        if (line_end) begin
                            run_active <= 1'b0;
                        end
                    end
                end
                else begin
                    run_active     <= 1'b1;
                    current_color  <= binary_pixel;
                    current_length <= 10'd1;
                end
            end
        end
    end

endmodule

/* ==================== qr_vertical_cross_check ==================== */
module qr_vertical_cross_check (
    input  wire        clk,
    input  wire        reset_p,


    // qr_run_length_scan 결과
    input  wire        pattern_valid,
    input  wire [9:0]  candidate_x,
    input  wire [8:0]  candidate_y,
    input  wire [12:0] pattern_total,


    // 1이면 새로운 수평 후보를 받을 수 있음
    output wire        candidate_ready,

    // Binary Frame BRAM Port B
    // Read Width   : 32 bit
    // Read Latency : 1 clock 기준
    
    output reg         bram_en,
    output reg  [13:0] bram_addr,
    input  wire [31:0] bram_rd_data,

    // Candidate Grouping Event 출력
    // event_type = 2'b00 : HIT
    
    output reg         event_valid,
    input  wire        event_ready,
    output wire [1:0]  event_type,
    output reg  [9:0]  event_x,
    output reg  [8:0]  event_y,

    // 상태 및 오류
    
    output wire        busy,
    output reg         candidate_drop_error,
    output reg         coordinate_error,
    input  wire        error_clear,

    // 디버깅 출력

    output reg  [12:0] vertical_total,

    output reg  [9:0]  vertical_run0,
    output reg  [9:0]  vertical_run1,
    output reg  [9:0]  vertical_run2,
    output reg  [9:0]  vertical_run3,
    output reg  [9:0]  vertical_run4,

    output reg         vertical_ratio_match,
    output reg         vertical_size_match
);

    // Main FSM
    
    localparam S_IDLE       = 3'd0;
    localparam S_READ_REQ   = 3'd1;
    localparam S_READ_WAIT  = 3'd2;
    localparam S_READ_CHECK = 3'd3;
    localparam S_RATIO      = 3'd4;
    localparam S_EVENT      = 3'd5;

    // Vertical Scan Phase

    // 위쪽:
    // 중앙 검정 → 흰색 → 외곽 검정

    // 아래쪽:
    // 중앙 검정 → 흰색 → 외곽 검정

    localparam P_UP_CENTER   = 3'd0;
    localparam P_UP_WHITE    = 3'd1;
    localparam P_UP_BLACK    = 3'd2;

    localparam P_DOWN_CENTER = 3'd3;
    localparam P_DOWN_WHITE  = 3'd4;
    localparam P_DOWN_BLACK  = 3'd5;

    reg [2:0] state;
    reg [2:0] phase;

    // 현재 검사 중인 수평 후보

    reg [9:0]  candidate_x_reg;
    reg [8:0]  candidate_y_reg;
    reg [12:0] horizontal_total_reg;

    // 현재 BRAM에서 읽을 Y 좌표

    reg [8:0] y_cursor;

    // 무한 탐색 방지용 최대 탐색 범위
    // 수평 Pattern 전체 길이를 기준으로 제한한다.

    reg [9:0] max_span;
    reg [9:0] up_steps;
    reg [9:0] down_steps;

    // 위쪽 Run-Length

    reg [9:0] up_center_count;
    reg [9:0] up_white_count;
    reg [9:0] up_black_count;

    // 아래쪽 Run-Length
    reg [9:0] down_center_count;
    reg [9:0] down_white_count;
    reg [9:0] down_black_count;

    // BRAM 주소 및 픽셀 선택
     
    wire [13:0] y_extended;
    wire [13:0] word_x_extended;
    wire [13:0] current_word_addr;

    wire [4:0] current_bit_index;
    wire       sampled_pixel;

    // 수직 Run 계산용 신호
     
    wire [10:0] center_count_value;

    wire [13:0] run0_value;
    wire [13:0] run1_value;
    wire [13:0] run2_value;
    wire [13:0] run3_value;
    wire [13:0] run4_value;

    wire [13:0] run0_mul7;
    wire [13:0] run1_mul7;
    wire [13:0] run2_mul7;
    wire [13:0] run3_mul7;
    wire [13:0] run4_mul7;

    wire [13:0] vertical_total_value;
    wire [13:0] vertical_total_mul3;

    wire [13:0] error0;
    wire [13:0] error1;
    wire [13:0] error2;
    wire [13:0] error3;
    wire [13:0] error4;

    wire [13:0] normal_tolerance;
    wire [13:0] center_tolerance;

    wire [13:0] horizontal_total_value;
    wire [13:0] size_error;
    wire [13:0] size_tolerance;

    wire ratio_match_comb;
    wire size_match_comb;

    // Candidate Grouping Event Type

    // 2'b00 = HIT

    assign event_type = 2'b00;

    // IDLE 상태에서만 새로운 후보를 받을 수 있다.

    // Candidate Grouping이 event_ready를 내리면
    // S_EVENT에서 대기하므로 candidate_ready도 0이 된다.

    assign candidate_ready =
        (state == S_IDLE) &&
        (event_valid == 1'b0);

    assign busy = (state != S_IDLE);

    // Binary Frame 주소 계산

    // word_addr = y × 20 + floor(x / 32)

    // y × 20 = y × 16 + y × 4

    assign y_extended      = {5'd0, y_cursor};
    assign word_x_extended = {9'd0, candidate_x_reg[9:5]};

    assign current_word_addr = (y_extended << 4) + (y_extended << 2) + word_x_extended;

    // 한 Word의 MSB가 왼쪽 픽셀

    // bit_index = 31 - (x mod 32)

    assign current_bit_index = 5'd31 - candidate_x_reg[4:0];

    assign sampled_pixel = bram_rd_data[current_bit_index];

    // 중앙 검정 Run은 중심 위쪽과 아래쪽의 합이다.

    // 위쪽 탐색에는 candidate_y 픽셀을 포함하고,
    // 아래쪽 탐색은 candidate_y + 1부터 시작한다.

    assign center_count_value = {1'b0, up_center_count} + {1'b0, down_center_count};

    // 최종 수직 Run 순서

    // run0 : 위쪽 외곽 검정
    // run1 : 위쪽 흰색
    // run2 : 중앙 검정
    // run3 : 아래쪽 흰색
    // run4 : 아래쪽 외곽 검정

    assign run0_value = {4'd0, up_black_count};
    assign run1_value = {4'd0, up_white_count};
    assign run2_value = {3'd0, center_count_value};
    assign run3_value = {4'd0, down_white_count};
    assign run4_value = {4'd0, down_black_count};

    // 각 Run의 7배 계산
    
    // value × 7 = value × 8 - value

    assign run0_mul7 = (run0_value << 3) - run0_value;

    assign run1_mul7 = (run1_value << 3) - run1_value;

    assign run2_mul7 = (run2_value << 3) - run2_value;

    assign run3_mul7 = (run3_value << 3) - run3_value;

    assign run4_mul7 = (run4_value << 3) - run4_value;

    // 수직 Pattern 전체 길이

    assign vertical_total_value = run0_value + run1_value + run2_value + run3_value + run4_value;

    // 수직 전체 길이 × 3
    
    assign vertical_total_mul3 = (vertical_total_value << 1) + vertical_total_value;

    // 절댓값 오차 계산
    
    assign error0 = (run0_mul7 >= vertical_total_value) ? run0_mul7 - vertical_total_value : vertical_total_value - run0_mul7;

    assign error1 = (run1_mul7 >= vertical_total_value) ? run1_mul7 - vertical_total_value : vertical_total_value - run1_mul7;

    assign error2 = (run2_mul7 >= vertical_total_mul3) ? run2_mul7 - vertical_total_mul3 : vertical_total_mul3 - run2_mul7;

    assign error3 = (run3_mul7 >= vertical_total_value) ? run3_mul7 - vertical_total_value : vertical_total_value - run3_mul7;

    assign error4 = (run4_mul7 >= vertical_total_value) ? run4_mul7 - vertical_total_value : vertical_total_value - run4_mul7;

    // 비율 허용 오차
    // Run-Length 모듈과 동일한 초기 설정
    assign normal_tolerance = vertical_total_value >> 2;

    assign center_tolerance =  vertical_total_value >> 1;

    // 수평 길이와 수직 길이 비교
    assign horizontal_total_value = {1'b0, horizontal_total_reg};

    assign size_error = (vertical_total_value >= horizontal_total_value) ? vertical_total_value - horizontal_total_value : horizontal_total_value - vertical_total_value;

    // 수평 전체 길이의 50%까지 초기 허용

    // 실제 영상 확인 후 줄이는 것이 좋다.

    assign size_tolerance = horizontal_total_value >> 1;

    // 수직 1:1:3:1:1 검사
    assign ratio_match_comb = (vertical_total_value >= 14'd7) &&
        (run0_value != 14'd0) &&
        (run1_value != 14'd0) &&
        (run2_value != 14'd0) &&
        (run3_value != 14'd0) &&
        (run4_value != 14'd0) &&

        (error0 <= normal_tolerance) &&
        (error1 <= normal_tolerance) &&
        (error2 <= center_tolerance) &&
        (error3 <= normal_tolerance) &&
        (error4 <= normal_tolerance);

    // 수평 크기와 수직 크기 비교

    assign size_match_comb = (horizontal_total_value >= 14'd7) && (size_error <= size_tolerance);

    // Main FSM

    always @(posedge clk or posedge reset_p) begin
        if (reset_p) begin
            state                <= S_IDLE;
            phase                <= P_UP_CENTER;

            candidate_x_reg      <= 10'd0;
            candidate_y_reg      <= 9'd0;
            horizontal_total_reg <= 13'd0;

            y_cursor             <= 9'd0;

            max_span             <= 10'd0;
            up_steps             <= 10'd0;
            down_steps           <= 10'd0;

            up_center_count      <= 10'd0;
            up_white_count       <= 10'd0;
            up_black_count       <= 10'd0;

            down_center_count    <= 10'd0;
            down_white_count     <= 10'd0;
            down_black_count     <= 10'd0;

            bram_en              <= 1'b0;
            bram_addr            <= 14'd0;

            event_valid          <= 1'b0;
            event_x              <= 10'd0;
            event_y              <= 9'd0;

            candidate_drop_error <= 1'b0;
            coordinate_error     <= 1'b0;

            vertical_total       <= 13'd0;

            vertical_run0        <= 10'd0;
            vertical_run1        <= 10'd0;
            vertical_run2        <= 10'd0;
            vertical_run3        <= 10'd0;
            vertical_run4        <= 10'd0;

            vertical_ratio_match <= 1'b0;
            vertical_size_match  <= 1'b0;
        end
        else begin
        
            // BRAM Enable은 요청 상태에서만 1
            bram_en <= 1'b0;

            // 오류 Flag Clear
            if (error_clear) begin
                candidate_drop_error <= 1'b0;
                coordinate_error     <= 1'b0;
            end

            // 처리 중 새로운 Pattern이 들어온 경우
            // 정상 통합에서는 Frame Reader를 Pause하여
            // 이 오류가 발생하지 않게 해야 한다.
            if (pattern_valid && !candidate_ready) begin
                candidate_drop_error <= 1'b1;
            end

            case (state)
                // 새로운 수평 후보 대기
                S_IDLE: begin
                    event_valid <= 1'b0;

                    if (pattern_valid && candidate_ready) begin
                        // 좌표 유효성 검사
                        if ((candidate_x <= 10'd639) && (candidate_y <= 9'd479)  && (pattern_total >= 13'd7)) begin

                            candidate_x_reg      <= candidate_x;
                            candidate_y_reg      <= candidate_y;
                            horizontal_total_reg <= pattern_total;

                            // 중심 좌표부터 위쪽으로 검사
                            y_cursor <= candidate_y;
                            phase    <= P_UP_CENTER;

                            up_steps   <= 10'd0;
                            down_steps <= 10'd0;

                            up_center_count   <= 10'd0;
                            up_white_count    <= 10'd0;
                            up_black_count    <= 10'd0;

                            down_center_count <= 10'd0;
                            down_white_count  <= 10'd0;
                            down_black_count  <= 10'd0;

                            vertical_total       <= 13'd0;

                            vertical_run0        <= 10'd0;
                            vertical_run1        <= 10'd0;
                            vertical_run2        <= 10'd0;
                            vertical_run3        <= 10'd0;
                            vertical_run4        <= 10'd0;

                            vertical_ratio_match <= 1'b0;
                            vertical_size_match  <= 1'b0;

                            // 탐색 범위 제한
                            if (pattern_total > 13'd480)
                                max_span <= 10'd480;
                            else
                                max_span <= pattern_total[9:0];

                            state <= S_READ_REQ;
                        end
                        else begin
                            coordinate_error <= 1'b1;
                        end
                    end
                end

                // BRAM 주소 및 Enable 출력
                S_READ_REQ: begin
                    bram_en   <= 1'b1;
                    bram_addr <= current_word_addr;

                    state <= S_READ_WAIT;
                end

                // 동기식 BRAM Read Latency 대기
                S_READ_WAIT: begin
                    state <= S_READ_CHECK;
                end

                // BRAM에서 읽은 픽셀 판정
                S_READ_CHECK: begin
                    case (phase)

                        // 중심에서 위쪽 방향의 중앙 검정 영역
                        P_UP_CENTER: begin
                            if (sampled_pixel == 1'b1) begin
                                up_center_count <= up_center_count + 10'd1;

                                up_steps <= up_steps + 10'd1;

                                if ((up_steps + 10'd1) >= max_span) begin
                                    state <= S_IDLE;
                                end
                                else if (y_cursor == 9'd0) begin
                                    state <= S_IDLE;
                                end
                                else begin
                                    y_cursor <= y_cursor - 9'd1;
                                    state    <= S_READ_REQ;
                                end
                            end
                            else if (up_center_count != 10'd0) begin

                                // 현재 흰색 픽셀을 다음 Phase에서
                                // 다시 읽어 첫 흰색 픽셀로 처리
                                phase <= P_UP_WHITE;
                                state <= S_READ_REQ;
                            end
                            else begin
                                state <= S_IDLE;
                            end
                        end

                        // 위쪽 흰색 영역
                        P_UP_WHITE: begin
                            if (sampled_pixel == 1'b0) begin
                                up_white_count <= up_white_count + 10'd1;

                                up_steps <= up_steps + 10'd1;

                                if ((up_steps + 10'd1) >= max_span) begin
                                    state <= S_IDLE;
                                end
                                else if (y_cursor == 9'd0) begin
                                    state <= S_IDLE;
                                end
                                else begin
                                    y_cursor <= y_cursor - 9'd1;
                                    state    <= S_READ_REQ;
                                end
                            end
                            else if (up_white_count != 10'd0) begin
                                phase <= P_UP_BLACK;
                                state <= S_READ_REQ;
                            end
                            else begin
                                state <= S_IDLE;
                            end
                        end

                        // 위쪽 외곽 검정 영역
                        P_UP_BLACK: begin
                            if (sampled_pixel == 1'b1) begin
                                up_black_count <= up_black_count + 10'd1;

                                up_steps <= up_steps + 10'd1;

                                if ((up_steps + 10'd1) >= max_span) begin
                                    state <= S_IDLE;
                                end
                                else if (y_cursor == 9'd0) begin

                                    // 화면 경계까지 외곽 검정 영역이
                                    // 이어진 경우 아래쪽 검사로 이동
                                    if (candidate_y_reg < 9'd479) begin
                                        y_cursor <= candidate_y_reg + 9'd1;

                                        phase      <= P_DOWN_CENTER;
                                        down_steps <= 10'd0;

                                        state <= S_READ_REQ;
                                    end
                                    else begin
                                        state <= S_IDLE;
                                    end
                                end
                                else begin
                                    y_cursor <= y_cursor - 9'd1;
                                    state    <= S_READ_REQ;
                                end
                            end
                            else if (up_black_count != 10'd0) begin

                                // 위쪽 3개 Run 완료
                                // 중심 바로 아래부터 아래쪽 검사
                                if (candidate_y_reg < 9'd479) begin
                                    y_cursor <= candidate_y_reg + 9'd1;

                                    phase      <= P_DOWN_CENTER;
                                    down_steps <= 10'd0;

                                    state <= S_READ_REQ;
                                end
                                else begin
                                    state <= S_IDLE;
                                end
                            end
                            else begin
                                state <= S_IDLE;
                            end
                        end


                        // 중심에서 아래쪽 방향의 중앙 검정 영역
                        
                        // candidate_y + 1부터 시작하므로
                        // 중심 픽셀은 중복 계산되지 않는다.
                        P_DOWN_CENTER: begin
                            if (sampled_pixel == 1'b1) begin
                                down_center_count <= down_center_count + 10'd1;

                                down_steps <= down_steps + 10'd1;

                                if ((down_steps + 10'd1) >= max_span) begin
                                    state <= S_IDLE;
                                end
                                else if (y_cursor == 9'd479) begin
                                    state <= S_IDLE;
                                end
                                else begin
                                    y_cursor <= y_cursor + 9'd1;
                                    state    <= S_READ_REQ;
                                end
                            end
                            else begin
                            
                                // 중앙 검정이 중심 한 픽셀뿐이어도
                                // 위쪽 count에 중심이 포함돼 있으므로
                                // 흰색 Phase로 넘어갈 수 있다.
                                phase <= P_DOWN_WHITE;
                                state <= S_READ_REQ;
                            end
                        end

                        // 아래쪽 흰색 영역
                        P_DOWN_WHITE: begin
                            if (sampled_pixel == 1'b0) begin
                                down_white_count <= down_white_count + 10'd1;

                                down_steps <= down_steps + 10'd1;

                                if ((down_steps + 10'd1) >= max_span) begin
                                    state <= S_IDLE;
                                end
                                else if (y_cursor == 9'd479) begin
                                    state <= S_IDLE;
                                end
                                else begin
                                    y_cursor <= y_cursor + 9'd1;
                                    state    <= S_READ_REQ;
                                end
                            end
                            else if (down_white_count != 10'd0) begin
                                phase <= P_DOWN_BLACK;
                                state <= S_READ_REQ;
                            end
                            else begin
                                state <= S_IDLE;
                            end
                        end

                         // 아래쪽 외곽 검정 영역
                        P_DOWN_BLACK: begin
                            if (sampled_pixel == 1'b1) begin
                                down_black_count <= down_black_count + 10'd1;

                                down_steps <= down_steps + 10'd1;

                                if ((down_steps + 10'd1) >= max_span) begin
                                    state <= S_IDLE;
                                end
                                else if (y_cursor == 9'd479) begin
                                    state <= S_RATIO;
                                end
                                else begin
                                    y_cursor <= y_cursor + 9'd1;
                                    state    <= S_READ_REQ;
                                end
                            end
                            else if (down_black_count != 10'd0) begin
                                // 아래쪽 외곽 검정 Run 완료
                                state <= S_RATIO;
                            end
                            else begin
                                state <= S_IDLE;
                            end
                        end

                        default: begin
                            state <= S_IDLE;
                        end
                    endcase
                end
                
                // 수직 비율 및 수평/수직 크기 검사
                S_RATIO: begin
                    vertical_total <= vertical_total_value[12:0];

                    vertical_run0 <= up_black_count;
                    vertical_run1 <= up_white_count;

                    vertical_run2 <= center_count_value[9:0];

                    vertical_run3 <= down_white_count;
                    vertical_run4 <= down_black_count;

                    vertical_ratio_match <= ratio_match_comb;

                    vertical_size_match <= size_match_comb;
                        
                     // 수직 비율과 크기 검사를 모두 통과하면
                     // Candidate Grouping에 HIT Event 전송
                    if (ratio_match_comb && size_match_comb) begin

                        event_valid <= 1'b1;
                        event_x     <= candidate_x_reg;
                        event_y     <= candidate_y_reg;

                        state <= S_EVENT;
                    end
                    else begin
                        state <= S_IDLE;
                    end
                end

                // Event Ready/Valid Handshake
                // event_ready=0이면 Event 값을 유지한다.
                S_EVENT: begin
                    if (event_valid && event_ready) begin
                        event_valid <= 1'b0;
                        state       <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

/* ==================== qr_frame_reader ==================== */
module qr_frame_reader (
    input  wire        clk,
    input  wire        reset_p,

    /*
     * Frame Controller에서 1클록 Pulse로 입력
     */
    input  wire        start,

    /*
     * Vertical Cross-Check가 BRAM Port B를 사용할 때
     * Frame Reader 정지 요청
     */
    input  wire        pause,

    /*
     * Reader가 안전하게 정지된 상태
     *
     * 나중에 BRAM Arbiter는 paused=1을 확인한 뒤
     * Port B를 Vertical Cross-Check에 넘기면 된다.
     */
    output wire        paused,

    /*
     * Binary Frame BRAM Port B
     */
    output reg         bram_en,
    output reg  [13:0] bram_addr,
    input  wire [31:0] bram_rd_data,

    /*
     * Reader 상태
     */
    output reg         busy,
    output reg         frame_done,

    /*
     * 1bit Pixel Stream
     */
    output reg         pixel_valid,
    output reg         binary_pixel,

    output reg  [9:0]  pixel_x,
    output reg  [8:0]  pixel_y,

    output reg         frame_start,
    output reg         line_start,
    output reg         line_end
);

    localparam S_IDLE      = 3'd0;
    localparam S_READ_REQ  = 3'd1;
    localparam S_READ_WAIT = 3'd2;
    localparam S_LOAD_WORD = 3'd3;
    localparam S_OUTPUT    = 3'd4;

    reg [2:0] state;

    /*
     * BRAM에서 읽은 32bit Word
     */
    reg [31:0] word_buffer;

    /*
     * 현재 Word 내부 Pixel 위치
     *
     * bit_index = 0  → word_buffer[31]
     * bit_index = 31 → word_buffer[0]
     */
    reg [4:0] bit_index;

    /*
     * 현재 행의 Word 위치
     *
     * 0~19
     */
    reg [4:0] word_x;

    /*
     * 현재 행
     *
     * 0~479
     */
    reg [8:0] row_y;

    /*
     * BRAM Word 주소
     *
     * 0~9599
     */
    reg [13:0] word_addr_counter;

    /*
     * 다음 상태에서는 BRAM 응답을 기다리지 않으므로
     * Port B를 다른 모듈에 넘길 수 있다.
     */
    assign paused =
        pause &&
        (
            (state == S_IDLE)     ||
            (state == S_READ_REQ) ||
            (state == S_OUTPUT)
        );

    always @(posedge clk or posedge reset_p) begin
        if (reset_p) begin
            state             <= S_IDLE;

            word_buffer       <= 32'd0;
            bit_index         <= 5'd0;
            word_x            <= 5'd0;
            row_y             <= 9'd0;
            word_addr_counter <= 14'd0;

            bram_en           <= 1'b0;
            bram_addr         <= 14'd0;

            busy              <= 1'b0;
            frame_done        <= 1'b0;

            pixel_valid       <= 1'b0;
            binary_pixel      <= 1'b0;

            pixel_x           <= 10'd0;
            pixel_y           <= 9'd0;

            frame_start       <= 1'b0;
            line_start        <= 1'b0;
            line_end          <= 1'b0;
        end
        else begin
            /*
             * Pulse 출력 기본값
             */
            bram_en     <= 1'b0;
            frame_done  <= 1'b0;
            pixel_valid <= 1'b0;
            frame_start <= 1'b0;
            line_start  <= 1'b0;
            line_end    <= 1'b0;

            case (state)
                /*
                 * Frame 처리 시작 대기
                 */
                S_IDLE: begin
                    busy <= 1'b0;

                    if (start) begin
                        busy              <= 1'b1;

                        bit_index         <= 5'd0;
                        word_x            <= 5'd0;
                        row_y             <= 9'd0;
                        word_addr_counter <= 14'd0;

                        state <= S_READ_REQ;
                    end
                end

                /*
                 * BRAM Read 요청
                 *
                 * pause가 들어오면 새로운 BRAM 요청을
                 * 발생시키지 않고 현재 상태에서 대기한다.
                 */
                S_READ_REQ: begin
                    if (!pause) begin
                        bram_en   <= 1'b1;
                        bram_addr <= word_addr_counter;

                        state <= S_READ_WAIT;
                    end
                end

                /*
                 * 동기식 BRAM의 Read Latency 대기
                 *
                 * 이미 BRAM Read 요청이 발생했으므로
                 * pause가 들어와도 읽기 응답까지 완료한다.
                 */
                S_READ_WAIT: begin
                    state <= S_LOAD_WORD;
                end

                /*
                 * BRAM 출력 데이터를 내부 Buffer에 저장
                 */
                S_LOAD_WORD: begin
                    word_buffer <= bram_rd_data;
                    bit_index   <= 5'd0;

                    state <= S_OUTPUT;
                end

                /*
                 * 32bit Word를 1bit Pixel로 출력
                 */
                S_OUTPUT: begin
                    if (!pause) begin
                        pixel_valid  <= 1'b1;

                        /*
                         * MSB가 왼쪽 Pixel
                         */
                        binary_pixel <=
                            word_buffer[5'd31 - bit_index];

                        /*
                         * pixel_x = word_x × 32 + bit_index
                         */
                        pixel_x <=
                            {word_x, 5'b00000} +
                            bit_index;

                        pixel_y <= row_y;

                        /*
                         * Frame 첫 Pixel
                         */
                        if ((row_y == 9'd0)  &&
                            (word_x == 5'd0) &&
                            (bit_index == 5'd0)) begin

                            frame_start <= 1'b1;
                        end

                        /*
                         * 각 행의 첫 Pixel
                         */
                        if ((word_x == 5'd0) &&
                            (bit_index == 5'd0)) begin

                            line_start <= 1'b1;
                        end

                        /*
                         * 각 행의 마지막 Pixel
                         */
                        if ((word_x == 5'd19) &&
                            (bit_index == 5'd31)) begin

                            line_end <= 1'b1;
                        end

                        /*
                         * 현재 Word의 마지막 Pixel
                         */
                        if (bit_index == 5'd31) begin
                            bit_index <= 5'd0;

                            /*
                             * 현재 행의 마지막 Word
                             */
                            if (word_x == 5'd19) begin
                                word_x <= 5'd0;

                                /*
                                 * 전체 Frame의 마지막 행
                                 */
                                if (row_y == 9'd479) begin
                                    busy       <= 1'b0;
                                    frame_done <= 1'b1;

                                    state <= S_IDLE;
                                end
                                else begin
                                    row_y <= row_y + 9'd1;

                                    word_addr_counter <=
                                        word_addr_counter + 14'd1;

                                    state <= S_READ_REQ;
                                end
                            end
                            else begin
                                word_x <= word_x + 5'd1;

                                word_addr_counter <=
                                    word_addr_counter + 14'd1;

                                state <= S_READ_REQ;
                            end
                        end
                        else begin
                            bit_index <= bit_index + 5'd1;
                        end
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

/* ==================== qr_bram_port_b_arbiter ==================== */
module qr_bram_port_b_arbiter (
    input  wire        clk,
    input  wire        reset_p,

    /*
     * ==================================================
     * Frame Reader 인터페이스
     * ==================================================
     */
    input  wire        reader_bram_en,
    input  wire [13:0] reader_bram_addr,

    /*
     * Arbiter → Frame Reader
     *
     * 1:
     * 새로운 Pixel 출력과 BRAM 요청을 정지
     */
    output wire        reader_pause,

    /*
     * Frame Reader → Arbiter
     *
     * 1:
     * 진행 중인 BRAM Read가 없고
     * Port B를 넘겨도 안전한 상태
     */
    input  wire        reader_paused,

    /*
     * ==================================================
     * Vertical Cross-Check 인터페이스
     * ==================================================
     */

    /*
     * VCC가 BRAM Port B 사용을 요청
     *
     * 1클록 Pulse 또는 Grant까지 유지하는 Level
     * 두 방식 모두 허용
     */
    input  wire        vcc_request,

    /*
     * VCC가 BRAM Port B를 사용할 수 있는 상태
     */
    output wire        vcc_grant,

    /*
     * VCC의 모든 BRAM 접근 종료
     *
     * 1클록 Pulse
     */
    input  wire        vcc_done,

    input  wire        vcc_bram_en,
    input  wire [13:0] vcc_bram_addr,

    /*
     * ==================================================
     * 실제 Binary Frame BRAM Port B
     * ==================================================
     */
    output wire        bram_en,
    output wire [13:0] bram_addr,

    /*
     * ==================================================
     * 상태 및 오류 출력
     * ==================================================
     */
    output wire        owner_vcc,
    output wire        arbiter_busy,
    output wire [1:0]  arbiter_state,

    output reg         protocol_error,
    input  wire        error_clear
);

    /*
     * Arbiter State
     */
    localparam A_READER           = 2'd0;
    localparam A_WAIT_PAUSE       = 2'd1;
    localparam A_VCC_ACTIVE       = 2'd2;
    localparam A_WAIT_REQUEST_LOW = 2'd3;

    reg [1:0] state;

    assign arbiter_state = state;

    /*
     * vcc_request가 들어오는 순간부터
     * Frame Reader에 정지를 요청한다.
     *
     * A_WAIT_REQUEST_LOW에서는 이미 Port B가
     * Reader에게 돌아갔으므로 pause를 해제한다.
     */
    assign reader_pause =
        (state == A_WAIT_PAUSE) ||
        (state == A_VCC_ACTIVE) ||
        (
            (state == A_READER) &&
            vcc_request
        );

    /*
     * VCC는 Grant가 1일 때만
     * BRAM 요청을 발생시켜야 한다.
     */
    assign vcc_grant =
        (state == A_VCC_ACTIVE);

    assign owner_vcc =
        (state == A_VCC_ACTIVE);

    /*
     * 요청 처리 또는 재무장 중임을 표시
     */
    assign arbiter_busy =
        (state != A_READER);

    /*
     * BRAM Port B 2:1 MUX
     *
     * VCC가 소유한 경우에만
     * VCC 주소와 Enable을 실제 BRAM에 전달한다.
     */
    assign bram_en =
        owner_vcc
        ? vcc_bram_en
        : reader_bram_en;

    assign bram_addr =
        owner_vcc
        ? vcc_bram_addr
        : reader_bram_addr;

    always @(posedge clk or posedge reset_p) begin
        if (reset_p) begin
            state          <= A_READER;
            protocol_error <= 1'b0;
        end
        else begin
            /*
             * Sticky Error Clear
             */
            if (error_clear) begin
                protocol_error <= 1'b0;
            end
            else begin
                /*
                 * VCC가 소유권 없이 BRAM을 요청한 경우
                 */
                if ((state != A_VCC_ACTIVE) &&
                    vcc_bram_en) begin

                    protocol_error <= 1'b1;
                end

                /*
                 * VCC가 Port B를 사용하는 동안
                 * Reader가 BRAM 요청을 발생시킨 경우
                 */
                if ((state == A_VCC_ACTIVE) &&
                    reader_bram_en) begin

                    protocol_error <= 1'b1;
                end

                /*
                 * VCC Active가 아닌데
                 * vcc_done이 들어온 경우
                 */
                if ((state != A_VCC_ACTIVE) &&
                    vcc_done) begin

                    protocol_error <= 1'b1;
                end
            end

            case (state)
                /*
                 * Frame Reader가 Port B 소유
                 */
                A_READER: begin
                    if (vcc_request) begin
                        state <= A_WAIT_PAUSE;
                    end
                end

                /*
                 * Frame Reader가 진행 중이던
                 * BRAM Read를 완료하기를 기다린다.
                 *
                 * 이 상태까지는 Port B가 Reader에 연결된다.
                 */
                A_WAIT_PAUSE: begin
                    if (reader_paused) begin
                        state <= A_VCC_ACTIVE;
                    end
                end

                /*
                 * Vertical Cross-Check가 Port B 소유
                 */
                A_VCC_ACTIVE: begin
                    if (vcc_done) begin
                        state <= A_WAIT_REQUEST_LOW;
                    end
                end

                /*
                 * Port B는 Reader에게 반환된 상태
                 *
                 * 이전 요청이 계속 High일 때
                 * 같은 요청이 다시 처리되는 것을 방지한다.
                 */
                A_WAIT_REQUEST_LOW: begin
                    if (!vcc_request) begin
                        state <= A_READER;
                    end
                end

                default: begin
                    state <= A_READER;
                end
            endcase
        end
    end

endmodule

/* ==================== qr_row_done_completion_ctrl ==================== */
module qr_row_done_completion_ctrl (
    input  wire       clk,
    input  wire       reset_p,

    input  wire       start,

    input  wire       reader_line_end,
    input  wire [8:0] reader_line_y,
    input  wire       reader_frame_done,

    input  wire       candidate_new_valid,
    input  wire       candidate_pending,
    input  wire       arbiter_busy,
    input  wire       vcc_busy,
    input  wire       hit_valid,

    output reg        row_done_valid,
    input  wire       row_done_ready,
    output reg  [8:0] row_done_y,

    output reg        scan_vcc_done_valid,
    input  wire       scan_vcc_done_ready,

    output wire       row_pause_request,
    output wire       control_busy,

    input  wire       error_clear,
    output reg        row_done_overrun_error
);

    reg row_done_pending;
    reg frame_scan_complete;
    reg last_row_done_seen;
    reg frame_active;

    /*
     * line_end를 본 순간부터 ROW_DONE handshake가 끝날 때까지
     * Reader가 다음 행으로 진행하지 못하게 한다.
     */
    assign row_pause_request =
        reader_line_end  ||
        row_done_pending ||
        row_done_valid;

    /*
     * start 수락 시점부터 scan_vcc_done handshake 완료까지 Busy 유지.
     */
    assign control_busy =
        frame_active          ||
        row_done_pending      ||
        row_done_valid        ||
        scan_vcc_done_valid;

    always @(posedge clk or posedge reset_p) begin
        if (reset_p) begin
            row_done_pending       <= 1'b0;
            row_done_valid         <= 1'b0;
            row_done_y             <= 9'd0;

            frame_scan_complete    <= 1'b0;
            last_row_done_seen     <= 1'b0;
            frame_active           <= 1'b0;

            scan_vcc_done_valid    <= 1'b0;
            row_done_overrun_error <= 1'b0;
        end
        else begin
            /* Sticky Error Clear */
            if (error_clear) begin
                row_done_overrun_error <= 1'b0;
            end

            /* 새 프레임 시작 */
            if (start &&
                !frame_active &&
                !scan_vcc_done_valid) begin

                row_done_pending    <= 1'b0;
                row_done_valid      <= 1'b0;
                row_done_y          <= 9'd0;

                frame_scan_complete <= 1'b0;
                last_row_done_seen  <= 1'b0;
                frame_active        <= 1'b1;

                scan_vcc_done_valid <= 1'b0;
            end

            /* Reader의 전체 프레임 스캔 완료 Pulse 저장 */
            if (frame_active && reader_frame_done) begin
                frame_scan_complete <= 1'b1;
            end

            /* 행 스캔 완료 좌표 저장 */
            if (frame_active && reader_line_end) begin
                if (row_done_pending || row_done_valid) begin
                    row_done_overrun_error <= 1'b1;
                end
                else begin
                    row_done_pending <= 1'b1;
                    row_done_y       <= reader_line_y;
                end
            end

            /*
             * Safe ROW_DONE 생성.
             * candidate_new_valid도 확인하여 line_end와 같은 시점에
             * Run-Length가 만든 후보가 누락되지 않게 한다.
             */
            if (row_done_pending &&
                !candidate_new_valid &&
                !candidate_pending &&
                !arbiter_busy &&
                !vcc_busy &&
                !hit_valid) begin

                row_done_pending <= 1'b0;
                row_done_valid   <= 1'b1;
            end

            /* ROW_DONE Handshake */
            if (row_done_valid && row_done_ready) begin
                row_done_valid <= 1'b0;

                if (row_done_y == 9'd479) begin
                    last_row_done_seen <= 1'b1;
                end
            end

            /*
             * 마지막 행 ROW_DONE handshake와 모든 내부 처리가 끝난 뒤
             * scan_vcc_done_valid을 발생시킨다.
             */
            if (frame_active &&
                frame_scan_complete &&
                last_row_done_seen &&
                !row_done_pending &&
                !row_done_valid &&
                !candidate_new_valid &&
                !candidate_pending &&
                !arbiter_busy &&
                !vcc_busy &&
                !hit_valid &&
                !scan_vcc_done_valid) begin

                scan_vcc_done_valid <= 1'b1;
            end

            /* 완료 Handshake 이후 IDLE 복귀 */
            if (scan_vcc_done_valid && scan_vcc_done_ready) begin
                scan_vcc_done_valid <= 1'b0;

                frame_scan_complete <= 1'b0;
                last_row_done_seen  <= 1'b0;
                frame_active        <= 1'b0;
            end
        end
    end

endmodule

/* ==================== qr_feature_reader_top ==================== */
module qr_feature_reader_top (
    input  wire        clk,
    input  wire        reset_p,

    input  wire        start,

    output wire        bram_en,
    output wire [13:0] bram_addr,
    input  wire [31:0] bram_rd_data,

    /* Vertical Cross-Check HIT */
    output wire        event_valid,
    input  wire        event_ready,
    output wire [1:0]  event_type,
    output wire [9:0]  event_x,
    output wire [8:0]  event_y,

    /* Safe ROW_DONE */
    output wire        row_done_valid,
    input  wire        row_done_ready,
    output wire [8:0]  row_done_y,

    /* Run-Length/VCC 완료 */
    output wire        scan_vcc_done_valid,
    input  wire        scan_vcc_done_ready,

    /* Reader / 전체 상태 */
    output wire        reader_busy,
    output wire        reader_frame_done,
    output wire        processing_busy,

    /* Debug */
    output wire        reader_pause,
    output wire        reader_paused,

    output wire        vcc_grant,
    output wire        owner_vcc,
    output wire [1:0]  arbiter_state,

    output wire        candidate_pending,
    output wire [2:0]  candidate_state,

    output wire        run_pattern_valid,
    output wire [9:0]  run_candidate_x,
    output wire [8:0]  run_candidate_y,
    output wire [12:0] run_pattern_total,

    /* Error */
    output reg         candidate_overrun_error,
    output wire        candidate_drop_error,
    output wire        coordinate_error,
    output wire        arbiter_protocol_error,
    output wire        row_done_overrun_error,
    input  wire        error_clear
);

    /* ==================================================
     * Frame Reader Pixel Stream
     * ================================================== */
    wire        pixel_valid;
    wire        binary_pixel;
    wire [9:0]  pixel_x;
    wire [8:0]  pixel_y;

    wire frame_start;
    wire line_start;
    wire line_end;

    /* Frame Reader BRAM Request */
    wire        reader_bram_en;
    wire [13:0] reader_bram_addr;

    /* Reader Pause Control */
    wire arbiter_reader_pause;
    wire row_pause_request;
    wire row_control_busy;

    /* ==================================================
     * Run-Length Output
     * ================================================== */
    wire        pattern_valid;
    wire [9:0]  candidate_x;
    wire [8:0]  candidate_y;
    wire [12:0] pattern_total;

    assign run_pattern_valid = pattern_valid;
    assign run_candidate_x   = candidate_x;
    assign run_candidate_y   = candidate_y;
    assign run_pattern_total = pattern_total;

    /* ==================================================
     * Pending Candidate Register
     * ================================================== */
    reg         pending_valid;
    reg  [9:0]  pending_x;
    reg  [8:0]  pending_y;
    reg  [12:0] pending_total;

    assign candidate_pending = pending_valid;

    /* ==================================================
     * Vertical Cross-Check / Arbiter Signals
     * ================================================== */
    reg  vcc_pattern_valid;
    reg  vcc_done;

    wire vcc_candidate_ready;
    wire vcc_busy;

    wire        vcc_bram_en;
    wire [13:0] vcc_bram_addr;

    wire arbiter_busy;

    wire vcc_request;

    assign vcc_request =
        pattern_valid ||
        pending_valid;

    /* ==================================================
     * Candidate Control State
     * ================================================== */
    localparam C_IDLE       = 3'd0;
    localparam C_WAIT_GRANT = 3'd1;
    localparam C_WAIT_BUSY  = 3'd2;
    localparam C_WAIT_DONE  = 3'd3;

    reg [2:0] candidate_control_state;

    assign candidate_state = candidate_control_state;

    always @(posedge clk or posedge reset_p) begin
        if (reset_p) begin
            pending_valid <= 1'b0;
            pending_x     <= 10'd0;
            pending_y     <= 9'd0;
            pending_total <= 13'd0;

            vcc_pattern_valid <= 1'b0;
            vcc_done          <= 1'b0;

            candidate_control_state <= C_IDLE;
            candidate_overrun_error <= 1'b0;
        end
        else begin
            vcc_pattern_valid <= 1'b0;
            vcc_done          <= 1'b0;

            if (error_clear) begin
                candidate_overrun_error <= 1'b0;
            end
            else if (pattern_valid && pending_valid) begin
                candidate_overrun_error <= 1'b1;
            end

            if (pattern_valid && !pending_valid) begin
                pending_valid <= 1'b1;
                pending_x     <= candidate_x;
                pending_y     <= candidate_y;
                pending_total <= pattern_total;
            end

            case (candidate_control_state)
                C_IDLE: begin
                    if (pending_valid) begin
                        candidate_control_state <= C_WAIT_GRANT;
                    end
                end

                C_WAIT_GRANT: begin
                    if (vcc_grant && vcc_candidate_ready) begin
                        vcc_pattern_valid <= 1'b1;
                        candidate_control_state <= C_WAIT_BUSY;
                    end
                end

                C_WAIT_BUSY: begin
                    if (vcc_busy) begin
                        candidate_control_state <= C_WAIT_DONE;
                    end
                end

                C_WAIT_DONE: begin
                    if (!vcc_busy) begin
                        vcc_done     <= 1'b1;
                        pending_valid <= 1'b0;
                        candidate_control_state <= C_IDLE;
                    end
                end

                default: begin
                    pending_valid <= 1'b0;
                    candidate_control_state <= C_IDLE;
                end
            endcase
        end
    end

    /* ==================================================
     * Reader Pause Combination
     * ================================================== */
    assign reader_pause =
        arbiter_reader_pause ||
        row_pause_request;

    /* ==================================================
     * Frame Reader
     * ================================================== */
    qr_frame_reader frame_reader_inst (
        .clk          (clk),
        .reset_p      (reset_p),

        .start        (start),
        .pause        (reader_pause),
        .paused       (reader_paused),

        .bram_en      (reader_bram_en),
        .bram_addr    (reader_bram_addr),
        .bram_rd_data (bram_rd_data),

        .busy         (reader_busy),
        .frame_done   (reader_frame_done),

        .pixel_valid  (pixel_valid),
        .binary_pixel (binary_pixel),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),

        .frame_start  (frame_start),
        .line_start   (line_start),
        .line_end     (line_end)
    );

    /* ==================================================
     * Run-Length Scan
     * ================================================== */
    qr_run_length_scan run_length_inst (
        .clk           (clk),
        .reset_p       (reset_p),

        .pixel_valid   (pixel_valid),
        .binary_pixel  (binary_pixel),
        .pixel_x       (pixel_x),
        .pixel_y       (pixel_y),
        .line_start    (line_start),
        .line_end      (line_end),

        .run_valid     (),
        .run_color     (),
        .run_length    (),
        .run_end_x     (),
        .run_y         (),

        .pattern_valid (pattern_valid),
        .candidate_x   (candidate_x),
        .candidate_y   (candidate_y),
        .pattern_total (pattern_total),

        .pattern_run0  (),
        .pattern_run1  (),
        .pattern_run2  (),
        .pattern_run3  (),
        .pattern_run4  ()
    );

    /* ==================================================
     * BRAM Port B Arbiter
     * ================================================== */
    qr_bram_port_b_arbiter arbiter_inst (
        .clk              (clk),
        .reset_p          (reset_p),

        .reader_bram_en   (reader_bram_en),
        .reader_bram_addr (reader_bram_addr),

        .reader_pause     (arbiter_reader_pause),
        .reader_paused    (reader_paused),

        .vcc_request      (vcc_request),
        .vcc_grant        (vcc_grant),
        .vcc_done         (vcc_done),

        .vcc_bram_en      (vcc_bram_en),
        .vcc_bram_addr    (vcc_bram_addr),

        .bram_en          (bram_en),
        .bram_addr        (bram_addr),

        .owner_vcc        (owner_vcc),
        .arbiter_busy     (arbiter_busy),
        .arbiter_state    (arbiter_state),

        .protocol_error   (arbiter_protocol_error),
        .error_clear      (error_clear)
    );

    /* ==================================================
     * Vertical Cross-Check
     * ================================================== */
    qr_vertical_cross_check vertical_check_inst (
        .clk                  (clk),
        .reset_p              (reset_p),

        .pattern_valid        (vcc_pattern_valid),
        .candidate_x          (pending_x),
        .candidate_y          (pending_y),
        .pattern_total        (pending_total),
        .candidate_ready      (vcc_candidate_ready),

        .bram_en              (vcc_bram_en),
        .bram_addr            (vcc_bram_addr),
        .bram_rd_data         (bram_rd_data),

        .event_valid          (event_valid),
        .event_ready          (event_ready),
        .event_type           (event_type),
        .event_x              (event_x),
        .event_y              (event_y),

        .busy                 (vcc_busy),

        .candidate_drop_error (candidate_drop_error),
        .coordinate_error     (coordinate_error),
        .error_clear          (error_clear),

        .vertical_total       (),
        .vertical_run0        (),
        .vertical_run1        (),
        .vertical_run2        (),
        .vertical_run3        (),
        .vertical_run4        (),
        .vertical_ratio_match (),
        .vertical_size_match  ()
    );

    /* ==================================================
     * Safe ROW_DONE / Completion Controller
     * ================================================== */
    qr_row_done_completion_ctrl row_done_ctrl_inst (
        .clk                     (clk),
        .reset_p                 (reset_p),

        .start                   (start),

        .reader_line_end         (line_end),
        .reader_line_y           (pixel_y),
        .reader_frame_done       (reader_frame_done),

        .candidate_new_valid     (pattern_valid),
        .candidate_pending       (pending_valid),
        .arbiter_busy            (arbiter_busy),
        .vcc_busy                (vcc_busy),
        .hit_valid               (event_valid),

        .row_done_valid          (row_done_valid),
        .row_done_ready          (row_done_ready),
        .row_done_y              (row_done_y),

        .scan_vcc_done_valid     (scan_vcc_done_valid),
        .scan_vcc_done_ready     (scan_vcc_done_ready),

        .row_pause_request       (row_pause_request),
        .control_busy            (row_control_busy),

        .error_clear             (error_clear),
        .row_done_overrun_error  (row_done_overrun_error)
    );

    /* ==================================================
     * Aggregate Processing Busy
     * ================================================== */
    assign processing_busy =
        reader_busy       ||
        pattern_valid     ||
        pending_valid     ||
        arbiter_busy      ||
        vcc_busy          ||
        event_valid       ||
        row_control_busy;

endmodule

/* ==================== qr_runlength_vcc_top ==================== */
module qr_runlength_vcc_top (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire        start,

    output wire        scan_vcc_busy,
    output wire        scan_vcc_done_valid,
    input  wire        scan_vcc_done_ready,

    output wire        reader_frame_done,

    output wire        bram_en,
    output wire [13:0] bram_addr,
    input  wire [31:0] bram_rd_data,

    output wire        hit_valid,
    input  wire        hit_ready,
    output wire [9:0]  hit_x,
    output wire [8:0]  hit_y,

    output wire        row_done_valid,
    input  wire        row_done_ready,
    output wire [8:0]  row_done_y,

    input  wire        error_clear,

    output wire        candidate_overrun_error,
    output wire        candidate_drop_error,
    output wire        coordinate_error,
    output wire        arbiter_protocol_error,
    output wire        row_done_overrun_error,
    output wire        scan_vcc_error,

    output wire        reader_busy,
    output wire        reader_pause,
    output wire        reader_paused,

    output wire        candidate_pending,
    output wire [2:0]  candidate_state,

    output wire        vcc_grant,
    output wire        owner_vcc,
    output wire [1:0]  arbiter_state,

    output wire        run_pattern_valid,
    output wire [9:0]  run_candidate_x,
    output wire [8:0]  run_candidate_y,
    output wire [12:0] run_pattern_total
);

    wire reset_p;
    assign reset_p = ~aresetn;

    wire        internal_event_valid;
    wire [1:0]  internal_event_type;
    wire [9:0]  internal_event_x;
    wire [8:0]  internal_event_y;

    wire internal_processing_busy;
    wire internal_reader_busy;
    wire internal_reader_frame_done;
    wire internal_reader_pause;
    wire internal_reader_paused;

    wire internal_candidate_pending;
    wire [2:0] internal_candidate_state;

    wire internal_vcc_grant;
    wire internal_owner_vcc;
    wire [1:0] internal_arbiter_state;

    wire        internal_run_pattern_valid;
    wire [9:0]  internal_run_candidate_x;
    wire [8:0]  internal_run_candidate_y;
    wire [12:0] internal_run_pattern_total;

    wire core_start;

    assign core_start =
        start &&
        !internal_processing_busy;

    assign scan_vcc_busy = internal_processing_busy;

    assign hit_valid = internal_event_valid;
    assign hit_x     = internal_event_x;
    assign hit_y     = internal_event_y;

    assign reader_busy       = internal_reader_busy;
    assign reader_frame_done = internal_reader_frame_done;
    assign reader_pause      = internal_reader_pause;
    assign reader_paused     = internal_reader_paused;

    assign candidate_pending = internal_candidate_pending;
    assign candidate_state   = internal_candidate_state;

    assign vcc_grant     = internal_vcc_grant;
    assign owner_vcc     = internal_owner_vcc;
    assign arbiter_state = internal_arbiter_state;

    assign run_pattern_valid = internal_run_pattern_valid;
    assign run_candidate_x   = internal_run_candidate_x;
    assign run_candidate_y   = internal_run_candidate_y;
    assign run_pattern_total = internal_run_pattern_total;

    qr_feature_reader_top feature_reader_core_inst (
        .clk                      (aclk),
        .reset_p                  (reset_p),

        .start                    (core_start),

        .bram_en                  (bram_en),
        .bram_addr                (bram_addr),
        .bram_rd_data             (bram_rd_data),

        .event_valid              (internal_event_valid),
        .event_ready              (hit_ready),
        .event_type               (internal_event_type),
        .event_x                  (internal_event_x),
        .event_y                  (internal_event_y),

        .row_done_valid           (row_done_valid),
        .row_done_ready           (row_done_ready),
        .row_done_y               (row_done_y),

        .scan_vcc_done_valid      (scan_vcc_done_valid),
        .scan_vcc_done_ready      (scan_vcc_done_ready),

        .reader_busy              (internal_reader_busy),
        .reader_frame_done        (internal_reader_frame_done),
        .processing_busy          (internal_processing_busy),

        .reader_pause             (internal_reader_pause),
        .reader_paused            (internal_reader_paused),

        .vcc_grant                (internal_vcc_grant),
        .owner_vcc                (internal_owner_vcc),
        .arbiter_state            (internal_arbiter_state),

        .candidate_pending        (internal_candidate_pending),
        .candidate_state          (internal_candidate_state),

        .run_pattern_valid        (internal_run_pattern_valid),
        .run_candidate_x          (internal_run_candidate_x),
        .run_candidate_y          (internal_run_candidate_y),
        .run_pattern_total        (internal_run_pattern_total),

        .candidate_overrun_error  (candidate_overrun_error),
        .candidate_drop_error     (candidate_drop_error),
        .coordinate_error         (coordinate_error),
        .arbiter_protocol_error   (arbiter_protocol_error),
        .row_done_overrun_error   (row_done_overrun_error),
        .error_clear              (error_clear)
    );

    assign scan_vcc_error =
        candidate_overrun_error ||
        candidate_drop_error    ||
        coordinate_error        ||
        arbiter_protocol_error  ||
        row_done_overrun_error;

endmodule
