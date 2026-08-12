`timescale 1ns / 1ps

/*
 * ============================================================================
 * Module : qr_frame_ctrl_runtime
 *
 * Role
 *   - Held frontend frame에 대해 start를 1회만 발생
 *   - Auto Start / Manual Start 지원
 *   - IP2 + IP3가 모두 준비되었을 때만 processing start
 *   - final_processing_done 이후 frontend frame release
 *
 * NOTE
 *   final_processing_done은 최종 Exact-Sync 구조에서
 *   packet_tx_done이 아니라 qr_frame_completion_ctrl의
 *   frame_complete에 연결된다.
 * ============================================================================
 */

module qr_frame_ctrl_runtime #(
    parameter integer TIMEOUT_W = 24
)(
    input  wire aclk,
    input  wire aresetn,

    // --------------------------------------------------------- Control
    input  wire enable,
    input  wire auto_start_enable,
    input  wire manual_start_pulse,

    // --------------------------------------------------------- Frame state
    input  wire frame_ready,
    input  wire frame_id_valid,

    /*
     * IP2 + IP3가 모두 새로운 frame 처리를 받을 준비가 되었는지 표시.
     *
     * Top에서:
     *
     * pipeline_start_ready =
     *     ip2_start_ready &&
     *     post_start_ready;
     */
    input  wire pipeline_start_ready,

    // --------------------------------------------------------- Outputs
    output reg  frame_release,
    output reg  start,
    output wire start_ready,

    // --------------------------------------------------------- Pipeline status
    input  wire processing_busy,

    /*
     * 최종 구조에서는:
     *
     * image_tx_done
     *      +
     * result_tx_done
     *      +
     * frame_ack
     *      ↓
     * qr_frame_completion_ctrl
     *      ↓
     * frame_complete
     *
     * frame_complete를 여기에 연결한다.
     */
    input  wire final_processing_done,

    // --------------------------------------------------------- Error / status
    input  wire stat_clear,

    output reg  stuck,
    output reg  control_protocol_error
);

    // -------------------------------------------------------------------------
    // Internal state
    // -------------------------------------------------------------------------

    reg launched;
    reg armed;
    reg manual_pending;

    reg [TIMEOUT_W-1:0] watchdog;

    wire request_present;
    wire can_start;

    /*
     * Auto Start가 켜져 있거나,
     * PS에서 Manual Start 요청이 pending 상태이면
     * 처리 요청이 존재한다.
     */
    assign request_present =
        auto_start_enable ||
        manual_pending;

    /*
     * 실제 start 발생 조건.
     *
     * 중요:
     * pipeline_start_ready를 포함하여
     * IP2와 IP3가 모두 준비된 경우에만 start한다.
     */
    assign can_start =
        enable                 &&
        frame_ready            &&
        frame_id_valid         &&
        pipeline_start_ready   &&
        armed                  &&
        !processing_busy       &&
        !launched              &&
        request_present;

    /*
     * PS가 Manual Start 가능 여부를 확인할 수 있는 상태.
     *
     * request_present는 조건에 넣지 않는다.
     * 즉 "현재 start 요청을 받아도 되는 상태인가?"를 의미한다.
     */
    assign start_ready =
        enable                 &&
        frame_ready            &&
        frame_id_valid         &&
        pipeline_start_ready   &&
        armed                  &&
        !processing_busy       &&
        !launched;

    // -------------------------------------------------------------------------
    // Sequential control
    // -------------------------------------------------------------------------

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin

            frame_release <= 1'b0;
            start <= 1'b0;

            launched <= 1'b0;
            armed <= 1'b1;

            manual_pending <= 1'b0;

            watchdog <= {TIMEOUT_W{1'b0}};

            stuck <= 1'b0;
            control_protocol_error <= 1'b0;
        end
        else begin

            /*
             * Pulse outputs
             */
            frame_release <= 1'b0;
            start <= 1'b0;

            // -------------------------------------------------------------
            // Re-arm
            // -------------------------------------------------------------
            /*
             * frontend_frame_ready가 실제로 Low가 된 이후에만
             * 다음 frame start를 허용한다.
             *
             * downstream busy 변화만으로 다시 arm 되는 것을 방지한다.
             */
            if (!frame_ready)
                armed <= 1'b1;

            // -------------------------------------------------------------
            // Manual start request
            // -------------------------------------------------------------
            if (manual_start_pulse) begin

                /*
                 * 이미 요청이 pending이거나 현재 frame을 처리 중인데
                 * 또 Manual Start가 들어오면 protocol error.
                 */
                if (manual_pending || launched)
                    control_protocol_error <= 1'b1;
                else
                    manual_pending <= 1'b1;
            end

            // -------------------------------------------------------------
            // Start
            // -------------------------------------------------------------
            if (can_start) begin

                start <= 1'b1;

                launched <= 1'b1;
                armed <= 1'b0;

                manual_pending <= 1'b0;

                watchdog <= {TIMEOUT_W{1'b0}};
            end

            // -------------------------------------------------------------
            // Full frame completion
            // -------------------------------------------------------------
            if (final_processing_done) begin

                /*
                 * 처리 시작 없이 completion이 발생했다면
                 * 정상적인 protocol이 아니다.
                 */
                if (!launched)
                    control_protocol_error <= 1'b1;

                launched <= 1'b0;

                /*
                 * frontend에게 현재 frame 사용 완료 통보.
                 *
                 * Exact-Sync에서는 final_processing_done 자체가
                 * PS FRAME_ACK 이후에만 들어오므로,
                 * 여기서는 별도의 ACK 판단을 하지 않는다.
                 */
                frame_release <= 1'b1;

                watchdog <= {TIMEOUT_W{1'b0}};
            end

            // -------------------------------------------------------------
            // Watchdog
            // -------------------------------------------------------------
            else if (launched) begin

                if (&watchdog)
                    stuck <= 1'b1;
                else
                    watchdog <=
                        watchdog +
                        {{(TIMEOUT_W-1){1'b0}}, 1'b1};
            end

            // -------------------------------------------------------------
            // Status clear
            // -------------------------------------------------------------
            if (stat_clear) begin

                stuck <= 1'b0;
                control_protocol_error <= 1'b0;

                watchdog <= {TIMEOUT_W{1'b0}};
            end
        end
    end

endmodule