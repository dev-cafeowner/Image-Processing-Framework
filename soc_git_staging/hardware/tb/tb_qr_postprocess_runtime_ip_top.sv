`timescale 1ns / 1ps

module tb_qr_postprocess_runtime_ip_top;

    localparam [1:0] EVENT_HIT        = 2'b00;
    localparam [1:0] EVENT_ROW_DONE   = 2'b01;
    localparam [1:0] EVENT_FRAME_DONE = 2'b10;

    reg aclk = 1'b0;
    always #4 aclk = ~aclk;  // 125 MHz

    reg aresetn;

    reg [5:0]  s_axi_awaddr;
    reg [2:0]  s_axi_awprot;
    reg        s_axi_awvalid;
    wire       s_axi_awready;

    reg [31:0] s_axi_wdata;
    reg [3:0]  s_axi_wstrb;
    reg        s_axi_wvalid;
    wire       s_axi_wready;

    wire [1:0] s_axi_bresp;
    wire       s_axi_bvalid;
    reg        s_axi_bready;

    reg [5:0]  s_axi_araddr;
    reg [2:0]  s_axi_arprot;
    reg        s_axi_arvalid;
    wire       s_axi_arready;

    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    reg [31:0] s_axis_event_tdata;
    reg [3:0]  s_axis_event_tkeep;
    reg        s_axis_event_tvalid;
    wire       s_axis_event_tready;
    reg        s_axis_event_tlast;

    wire [31:0] m_axis_result_tdata;
    wire [3:0]  m_axis_result_tkeep;
    wire        m_axis_result_tvalid;
    reg         m_axis_result_tready;
    wire        m_axis_result_tlast;

    reg         frontend_frame_ready;
    reg [7:0]   frontend_valid_margin;
    wire        frontend_frame_release;
    wire        frontend_frame_stuck;
    wire        frontend_stat_clear;

    wire        ip2_start;
    reg         ip2_start_ready;
    reg         ip2_processing_busy;
    reg         ip2_processing_done;
    wire        ip2_error_clear;

    reg         ip2_scan_vcc_error;
    reg         ip2_candidate_overrun_error;
    reg         ip2_candidate_drop_error;
    reg         ip2_coordinate_error;
    reg         ip2_arbiter_protocol_error;
    reg         ip2_row_done_overrun_error;
    reg         ip2_event_stability_error;
    reg         ip2_event_row_order_error;
    reg         ip2_event_protocol_error;

    reg         external_fatal_frame_error;

    wire        irq;
    wire [31:0] active_frame_id;
    wire [31:0] next_frame_id;
    wire [31:0] result_error_flags;
    wire [15:0] result_word_length;
    wire [15:0] result_byte_length;
    wire [7:0]  candidate_count;
    wire        result_ready;
    wire        processing_busy;
    wire        postprocess_done;
    wire        result_tx_done;
    wire        system_error;

    wire [8:0]  stored_hit_count;
    wire [5:0]  allocated_label_count;
    wire [18:0] accumulated_hit_count;
    wire [5:0]  qualified_property_count;

    reg [31:0] expected_packet [0:19];

    integer fail_count;
    integer event_count;
    integer hit_count;
    integer row_count;
    integer frame_count;
    integer result_count;
    integer result_tlast_count;
    integer release_count;
    integer start_count;
    integer post_done_count;
    integer tx_done_count;
    integer y;
    integer timeout_count;

    reg [31:0] readback;

    reg result_hold;
    reg [31:0] held_result_data;
    reg held_result_last;

    qr_postprocess_runtime_ip_top dut (
        .aclk                         (aclk),
        .aresetn                      (aresetn),

        .s_axi_awaddr                 (s_axi_awaddr),
        .s_axi_awprot                 (s_axi_awprot),
        .s_axi_awvalid                (s_axi_awvalid),
        .s_axi_awready                (s_axi_awready),
        .s_axi_wdata                  (s_axi_wdata),
        .s_axi_wstrb                  (s_axi_wstrb),
        .s_axi_wvalid                 (s_axi_wvalid),
        .s_axi_wready                 (s_axi_wready),
        .s_axi_bresp                  (s_axi_bresp),
        .s_axi_bvalid                 (s_axi_bvalid),
        .s_axi_bready                 (s_axi_bready),
        .s_axi_araddr                 (s_axi_araddr),
        .s_axi_arprot                 (s_axi_arprot),
        .s_axi_arvalid                (s_axi_arvalid),
        .s_axi_arready                (s_axi_arready),
        .s_axi_rdata                  (s_axi_rdata),
        .s_axi_rresp                  (s_axi_rresp),
        .s_axi_rvalid                 (s_axi_rvalid),
        .s_axi_rready                 (s_axi_rready),

        .s_axis_event_tdata           (s_axis_event_tdata),
        .s_axis_event_tkeep           (s_axis_event_tkeep),
        .s_axis_event_tvalid          (s_axis_event_tvalid),
        .s_axis_event_tready          (s_axis_event_tready),
        .s_axis_event_tlast           (s_axis_event_tlast),

        .m_axis_result_tdata          (m_axis_result_tdata),
        .m_axis_result_tkeep          (m_axis_result_tkeep),
        .m_axis_result_tvalid         (m_axis_result_tvalid),
        .m_axis_result_tready         (m_axis_result_tready),
        .m_axis_result_tlast          (m_axis_result_tlast),

        .frontend_frame_ready         (frontend_frame_ready),
        .frontend_valid_margin        (frontend_valid_margin),
        .frontend_frame_release       (frontend_frame_release),
        .frontend_frame_stuck         (frontend_frame_stuck),
        .frontend_stat_clear          (frontend_stat_clear),

        .ip2_start                    (ip2_start),
        .ip2_start_ready              (ip2_start_ready),
        .ip2_processing_busy          (ip2_processing_busy),
        .ip2_processing_done          (ip2_processing_done),
        .ip2_error_clear              (ip2_error_clear),

        .ip2_scan_vcc_error           (ip2_scan_vcc_error),
        .ip2_candidate_overrun_error  (ip2_candidate_overrun_error),
        .ip2_candidate_drop_error     (ip2_candidate_drop_error),
        .ip2_coordinate_error         (ip2_coordinate_error),
        .ip2_arbiter_protocol_error   (ip2_arbiter_protocol_error),
        .ip2_row_done_overrun_error   (ip2_row_done_overrun_error),
        .ip2_event_stability_error    (ip2_event_stability_error),
        .ip2_event_row_order_error    (ip2_event_row_order_error),
        .ip2_event_protocol_error     (ip2_event_protocol_error),

        .external_fatal_frame_error   (external_fatal_frame_error),

        .irq                          (irq),
        .active_frame_id              (active_frame_id),
        .next_frame_id                (next_frame_id),
        .result_error_flags           (result_error_flags),
        .result_word_length           (result_word_length),
        .result_byte_length           (result_byte_length),
        .candidate_count              (candidate_count),
        .result_ready                 (result_ready),
        .processing_busy              (processing_busy),
        .postprocess_done             (postprocess_done),
        .result_tx_done               (result_tx_done),
        .system_error                 (system_error),

        .stored_hit_count             (stored_hit_count),
        .allocated_label_count        (allocated_label_count),
        .accumulated_hit_count        (accumulated_hit_count),
        .qualified_property_count     (qualified_property_count)
    );

    initial begin
        $dumpfile("tb_qr_postprocess_runtime_ip_top.vcd");
        $dumpvars(0, tb_qr_postprocess_runtime_ip_top);
    end

    task automatic axi_write;
        input [5:0]  addr;
        input [31:0] data;
        begin
            @(negedge aclk);
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF;
            s_axi_wvalid  = 1'b1;
            s_axi_bready  = 1'b1;

            while (!(s_axi_awready && s_axi_wready))
                @(posedge aclk);

            @(negedge aclk);
            s_axi_awvalid = 1'b0;
            s_axi_wvalid  = 1'b0;

            while (!s_axi_bvalid)
                @(posedge aclk);

            @(negedge aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_read;
        input  [5:0]  addr;
        output [31:0] data;
        begin
            @(negedge aclk);
            s_axi_araddr  = addr;
            s_axi_arvalid = 1'b1;
            s_axi_rready  = 1'b1;

            while (!s_axi_arready)
                @(posedge aclk);

            @(negedge aclk);
            s_axi_arvalid = 1'b0;

            while (!s_axi_rvalid)
                @(posedge aclk);

            data = s_axi_rdata;

            @(negedge aclk);
            s_axi_rready = 1'b0;
        end
    endtask

    task automatic send_event;
        input [1:0] type_value;
        input [9:0] x_value;
        input [8:0] y_value;
        input       last_value;
        begin
            @(negedge aclk);
            s_axis_event_tdata  = {
                11'd0,
                type_value,
                x_value,
                y_value
            };
            s_axis_event_tkeep  = 4'hF;
            s_axis_event_tlast  = last_value;
            s_axis_event_tvalid = 1'b1;

            while (!s_axis_event_tready)
                @(posedge aclk);

            @(negedge aclk);
            s_axis_event_tvalid = 1'b0;
            s_axis_event_tlast  = 1'b0;

            event_count = event_count + 1;

            if (type_value == EVENT_HIT)
                hit_count = hit_count + 1;
            else if (type_value == EVENT_ROW_DONE)
                row_count = row_count + 1;
            else if (type_value == EVENT_FRAME_DONE)
                frame_count = frame_count + 1;
        end
    endtask

    task automatic build_expected;
        begin
            expected_packet[0]  = 32'h51525031;
            expected_packet[1]  = 32'h01050500;
            expected_packet[2]  = 32'h00000042;
            expected_packet[3]  = 32'h00140301;
            expected_packet[4]  = 32'h00000000;

            expected_packet[5]  = 32'h00030000;
            expected_packet[6]  = 32'h0200B02C;
            expected_packet[7]  = 32'h00000037;
            expected_packet[8]  = 32'h00000420;
            expected_packet[9]  = 32'h00000414;

            expected_packet[10] = 32'h00030001;
            expected_packet[11] = 32'h02095254;
            expected_packet[12] = 32'h00000037;
            expected_packet[13] = 32'h000037E0;
            expected_packet[14] = 32'h00000414;

            expected_packet[15] = 32'h00030002;
            expected_packet[16] = 32'h1A80B02C;
            expected_packet[17] = 32'h000001BF;
            expected_packet[18] = 32'h00000420;
            expected_packet[19] = 32'h000028D4;
        end
    endtask

    /*
     * Deterministic result-stream backpressure.
     */
    integer result_ready_cycle;
    always @(posedge aclk) begin
        if (!aresetn) begin
            result_ready_cycle   <= 0;
            m_axis_result_tready <= 1'b0;
        end
        else begin
            result_ready_cycle <= result_ready_cycle + 1;
            m_axis_result_tready <=
                ((result_ready_cycle % 11) != 0) &&
                ((result_ready_cycle % 23) != 0);
        end
    end

    /*
     * AXI result stability and packet scoreboard.
     */
    always @(posedge aclk) begin
        if (!aresetn) begin
            result_hold        <= 1'b0;
            held_result_data   <= 32'd0;
            held_result_last   <= 1'b0;
            result_count       <= 0;
            result_tlast_count <= 0;
        end
        else begin
            if (result_hold) begin
                if (!m_axis_result_tvalid ||
                    m_axis_result_tdata != held_result_data ||
                    m_axis_result_tlast != held_result_last) begin
                    $display(
                        "IP3 FAIL: result AXIS changed during stall"
                    );
                    fail_count <= fail_count + 1;
                    result_hold <= 1'b0;
                end
                else if (m_axis_result_tready) begin
                    result_hold <= 1'b0;
                end
            end
            else if (m_axis_result_tvalid &&
                     !m_axis_result_tready) begin
                result_hold      <= 1'b1;
                held_result_data <= m_axis_result_tdata;
                held_result_last <= m_axis_result_tlast;
            end

            if (m_axis_result_tvalid &&
                m_axis_result_tready) begin

                if (result_count >= 20 ||
                    m_axis_result_tdata !==
                    expected_packet[result_count]) begin
                    $display(
                        "IP3 FAIL: result word %0d data=%08h expected=%08h",
                        result_count,
                        m_axis_result_tdata,
                        expected_packet[result_count]
                    );
                    fail_count <= fail_count + 1;
                end

                if (m_axis_result_tkeep != 4'hF) begin
                    $display(
                        "IP3 FAIL: result TKEEP=%h",
                        m_axis_result_tkeep
                    );
                    fail_count <= fail_count + 1;
                end

                if (m_axis_result_tlast) begin
                    result_tlast_count <= result_tlast_count + 1;
                    if (result_count != 19) begin
                        $display(
                            "IP3 FAIL: TLAST at word %0d",
                            result_count
                        );
                        fail_count <= fail_count + 1;
                    end
                end

                result_count <= result_count + 1;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            release_count  <= 0;
            start_count    <= 0;
            post_done_count<= 0;
            tx_done_count  <= 0;
        end
        else begin
            if (ip2_start) begin
                start_count <= start_count + 1;
                ip2_processing_busy <= 1'b1;
            end

            if (postprocess_done)
                post_done_count <= post_done_count + 1;

            if (result_tx_done)
                tx_done_count <= tx_done_count + 1;

            if (frontend_frame_release) begin
                release_count <= release_count + 1;
                frontend_frame_ready <= 1'b0;
            end
        end
    end

    initial begin
        aresetn = 1'b0;

        s_axi_awaddr  = 6'd0;
        s_axi_awprot  = 3'd0;
        s_axi_awvalid = 1'b0;
        s_axi_wdata   = 32'd0;
        s_axi_wstrb   = 4'd0;
        s_axi_wvalid  = 1'b0;
        s_axi_bready  = 1'b0;
        s_axi_araddr  = 6'd0;
        s_axi_arprot  = 3'd0;
        s_axi_arvalid = 1'b0;
        s_axi_rready  = 1'b0;

        s_axis_event_tdata  = 32'd0;
        s_axis_event_tkeep  = 4'hF;
        s_axis_event_tvalid = 1'b0;
        s_axis_event_tlast  = 1'b0;

        frontend_frame_ready  = 1'b0;
        frontend_valid_margin = 8'd19;

        ip2_start_ready     = 1'b1;
        ip2_processing_busy = 1'b0;
        ip2_processing_done = 1'b0;

        ip2_scan_vcc_error          = 1'b0;
        ip2_candidate_overrun_error = 1'b0;
        ip2_candidate_drop_error    = 1'b0;
        ip2_coordinate_error        = 1'b0;
        ip2_arbiter_protocol_error  = 1'b0;
        ip2_row_done_overrun_error  = 1'b0;
        ip2_event_stability_error   = 1'b0;
        ip2_event_row_order_error   = 1'b0;
        ip2_event_protocol_error    = 1'b0;

        external_fatal_frame_error = 1'b0;

        fail_count         = 0;
        event_count        = 0;
        hit_count          = 0;
        row_count          = 0;
        frame_count        = 0;
        result_count       = 0;
        result_tlast_count = 0;
        release_count      = 0;
        start_count        = 0;
        post_done_count    = 0;
        tx_done_count      = 0;
        timeout_count      = 0;
        readback           = 32'd0;
        result_ready_cycle = 0;
        result_hold        = 1'b0;
        held_result_data   = 32'd0;
        held_result_last   = 1'b0;

        build_expected();

        repeat (10) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        /*
         * Frame ID seed = 0x42.
         */
        axi_write(6'h08, 32'h00000042);

        /*
         * IRQ0=result_ready, IRQ1=packet_tx_done.
         */
        axi_write(6'h30, 32'h00000003);

        /*
         * CONTROL:
         *   bit7 auto_start_enable = 1
         *   bit0 enable            = 1
         */
        axi_write(6'h00, 32'h00000081);

        repeat (5) @(posedge aclk);
        @(negedge aclk);
        frontend_frame_ready = 1'b1;

        timeout_count = 0;
        while ((start_count == 0) &&
               (timeout_count < 2000)) begin
            @(posedge aclk);
            timeout_count = timeout_count + 1;
        end

        if (start_count != 1) begin
            $display("IP3 FAIL: coordinated start timeout");
            fail_count = fail_count + 1;
        end

        if (active_frame_id != 32'h00000042) begin
            $display(
                "IP3 FAIL: active_frame_id=%08h",
                active_frame_id
            );
            fail_count = fail_count + 1;
        end

        /*
         * Three synthetic Finder clusters:
         *   label 0: x=44,  y=32..55
         *   label 1: x=596, y=32..55
         *   label 2: x=44,  y=424..447
         */
        for (y = 0; y < 480; y = y + 1) begin
            if ((y >= 32) && (y <= 55)) begin
                send_event(
                    EVENT_HIT,
                    10'd44,
                    y[8:0],
                    1'b0
                );
                send_event(
                    EVENT_HIT,
                    10'd596,
                    y[8:0],
                    1'b0
                );
            end

            if ((y >= 424) && (y <= 447)) begin
                send_event(
                    EVENT_HIT,
                    10'd44,
                    y[8:0],
                    1'b0
                );
            end

            send_event(
                EVENT_ROW_DONE,
                10'd0,
                y[8:0],
                1'b0
            );
        end

        send_event(
            EVENT_FRAME_DONE,
            10'd0,
            9'd479,
            1'b1
        );

        @(negedge aclk);
        ip2_processing_done = 1'b1;
        ip2_processing_busy = 1'b0;
        @(negedge aclk);
        ip2_processing_done = 1'b0;

        timeout_count = 0;
        while (!result_ready &&
               timeout_count < 200000) begin
            @(posedge aclk);
            timeout_count = timeout_count + 1;
        end
        #1;

        if (!result_ready) begin
            $display("IP3 FAIL: result_ready timeout");
            fail_count = fail_count + 1;
        end

        if (candidate_count != 8'd3 ||
            result_word_length != 16'd20 ||
            result_byte_length != 16'd80) begin
            $display(
                "IP3 FAIL: candidate/word/byte=%0d/%0d/%0d",
                candidate_count,
                result_word_length,
                result_byte_length
            );
            fail_count = fail_count + 1;
        end

        if (stored_hit_count != 9'd72 ||
            allocated_label_count != 6'd3 ||
            accumulated_hit_count != 19'd72 ||
            qualified_property_count != 6'd3) begin
            $display(
                "IP3 FAIL: hit/label/accum/qualified=%0d/%0d/%0d/%0d",
                stored_hit_count,
                allocated_label_count,
                accumulated_hit_count,
                qualified_property_count
            );
            fail_count = fail_count + 1;
        end

        axi_read(6'h0C, readback);
        if (readback != 32'd20) begin
            $display(
                "IP3 FAIL: CSR result words=%08h",
                readback
            );
            fail_count = fail_count + 1;
        end

        axi_read(6'h10, readback);
        if (readback != 32'd3) begin
            $display(
                "IP3 FAIL: CSR candidates=%08h",
                readback
            );
            fail_count = fail_count + 1;
        end

        axi_read(6'h14, readback);
        if (readback != 32'd0) begin
            $display(
                "IP3 FAIL: CSR errors=%08h",
                readback
            );
            fail_count = fail_count + 1;
        end

        if (!irq) begin
            $display("IP3 FAIL: IRQ not asserted at result_ready");
            fail_count = fail_count + 1;
        end

        /*
         * CONTROL:
         *   bit7 auto start = 1
         *   bit4 stream start pulse
         *   bit0 enable = 1
         */
        axi_write(6'h00, 32'h00000091);

        timeout_count = 0;
        while ((tx_done_count == 0) &&
               (timeout_count < 200000)) begin
            @(posedge aclk);
            timeout_count = timeout_count + 1;
        end
        repeat (10) @(posedge aclk);
        #1;

        if (event_count != 553 ||
            hit_count != 72 ||
            row_count != 480 ||
            frame_count != 1) begin
            $display(
                "IP3 FAIL: events total/hit/row/frame=%0d/%0d/%0d/%0d",
                event_count,
                hit_count,
                row_count,
                frame_count
            );
            fail_count = fail_count + 1;
        end

        if (result_count != 20 ||
            result_tlast_count != 1) begin
            $display(
                "IP3 FAIL: result count/tlast=%0d/%0d",
                result_count,
                result_tlast_count
            );
            fail_count = fail_count + 1;
        end

        if (start_count != 1 ||
            post_done_count != 1 ||
            tx_done_count != 1 ||
            release_count != 1) begin
            $display(
                "IP3 FAIL: start/post/tx/release=%0d/%0d/%0d/%0d",
                start_count,
                post_done_count,
                tx_done_count,
                release_count
            );
            fail_count = fail_count + 1;
        end

        if (result_error_flags != 32'd0 ||
            system_error ||
            frontend_frame_stuck) begin
            $display(
                "IP3 FAIL: error flags/system/stuck=%08h/%b/%b",
                result_error_flags,
                system_error,
                frontend_frame_stuck
            );
            fail_count = fail_count + 1;
        end

        if (!irq) begin
            $display("IP3 FAIL: IRQ not asserted after packet done");
            fail_count = fail_count + 1;
        end

        /*
         * Clear IRQ0 and IRQ1 through W1C IRQ_STATUS.
         */
        axi_write(6'h2C, 32'h00000003);
        repeat (4) @(posedge aclk);
        #1;

        if (irq) begin
            $display("IP3 FAIL: IRQ did not clear");
            fail_count = fail_count + 1;
        end

        $display("==================================================");
        $display("IP3 Event Total       : %0d", event_count);
        $display("IP3 HIT/ROW/FRAME     : %0d / %0d / %0d",
                 hit_count, row_count, frame_count);
        $display("IP3 Stored Hits       : %0d", stored_hit_count);
        $display("IP3 Allocated Labels  : %0d", allocated_label_count);
        $display("IP3 Qualified Objects : %0d", qualified_property_count);
        $display("IP3 Candidate Count   : %0d", candidate_count);
        $display("IP3 Result Words      : %0d", result_count);
        $display("IP3 Frame ID          : %08h", active_frame_id);
        $display("IP3 Fail Count        : %0d", fail_count);
        $display("==================================================");

        if (fail_count == 0)
            $display("QR POSTPROCESS RUNTIME IP3 TEST PASS");
        else
            $display("QR POSTPROCESS RUNTIME IP3 TEST FAIL");

        #1;
        $dumpflush;
        $finish;
    end

    initial begin
        #10000000;

        if (tx_done_count == 0) begin
            $display("IP3 FAIL: simulation timeout");
            fail_count = fail_count + 1;
        end

        #1;
        $dumpflush;
        $finish;
    end

endmodule
