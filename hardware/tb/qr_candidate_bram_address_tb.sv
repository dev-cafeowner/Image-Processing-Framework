`timescale 1ns/1ps
// Replay the actual Stage4 generated BMG, not an ideal word-indexed RAM.
// Only the external word-to-byte address conversion changes between cases.
module qr_candidate_bram_address_tb;
    reg clk=0; always #8 clk=~clk;
    reg resetn=0, start=0, correct_address=0;
    reg write_en=0;
    reg [13:0] write_word=0;
    reg [31:0] write_data=0;
    wire [13:0] read_word;
    wire read_en, read_rst, read_clk, read_we;
    wire [31:0] read_data, unused_din;
    wire [31:0] corrected_write, corrected_read;
`ifdef QR_TEST_PINGPONG
    reg write_bank=0, read_bank=0;
    qr_binary_pingpong_address adapter (
        .write_bank(write_bank), .read_bank(read_bank),
`else
    qr_binary_bram_address_adapter adapter (
`endif
        .write_word(write_word), .read_word(read_word),
        .write_enable(write_en), .read_write_enable(read_we),
        .write_byte(corrected_write), .read_byte(corrected_read),
        .write_lanes(), .read_write_lanes());
    wire [31:0] write_address=correct_address ? corrected_write : {18'd0,write_word};
    wire [31:0] read_address=correct_address ? corrected_read : {18'd0,read_word};
    qr_ip1_bd_blk_mem_gen_0_0 memory (
        .clka(clk),.rsta(!resetn),.ena(write_en),.wea({4{write_en}}),
        .addra(write_address),.dina(write_data),.douta(),
        .clkb(read_clk),.rstb(read_rst),.enb(read_en),.web({4{read_we}}),
        .addrb(read_address),.dinb(unused_din),.doutb(read_data),.rsta_busy(),.rstb_busy());
    wire [31:0] events;
    wire [3:0] keep;
    wire valid, ready, last, ip2_done, feature_ready;
    wire scan_err, overrun_err, drop_err, coord_err, arb_err, row_overrun;
    wire stability_err, order_err, protocol_err, feature_err;
    wire [15:0] hits, rows, all_events;
    wire run_valid;
    integer raw_cycles=0;
    always @(posedge clk) if(!resetn) raw_cycles<=0; else if(run_valid) raw_cycles<=raw_cycles+1;
    qr_vcc_frontend_ip_top feature (
        .aclk(clk),.aresetn(resetn),.start(start),.start_ready(feature_ready),.error_clear(1'b0),
        .processing_done(ip2_done),.bram_clk(read_clk),.bram_rst(read_rst),.bram_en(read_en),
        .bram_we(read_we),.bram_addr(read_word),.bram_din(unused_din),.bram_dout(read_data),
        .m_axis_event_tdata(events),.m_axis_event_tkeep(keep),.m_axis_event_tvalid(valid),
        .m_axis_event_tready(ready),.m_axis_event_tlast(last),.run_pattern_valid(run_valid),
        .hit_event_count(hits),.row_event_count(rows),.total_event_count(all_events),
        .candidate_overrun_error(overrun_err),.candidate_drop_error(drop_err),
        .coordinate_error(coord_err),.arbiter_protocol_error(arb_err),.row_done_overrun_error(row_overrun),
        .scan_vcc_error(scan_err),.event_stability_error(stability_err),.event_row_order_error(order_err),
        .event_protocol_error(protocol_err),.combined_error(feature_err));
    wire result_ready, post_start_ready;
    wire [7:0] candidates;
    wire [15:0] words;
    wire [31:0] errors, packet_errors;
    wire [8:0] stored;
    wire [5:0] labels, qualified;
    wire [18:0] accumulated;
    reg stream_start=0;
    wire [31:0] packet_data;
    wire packet_valid, packet_last;
    reg [31:0] packet [0:84];
    integer packet_size=0;
    always @(posedge clk) begin
        if(!resetn) packet_size<=0;
        else if(packet_valid) begin
            if(packet_size>=85) $fatal(1,"oversized packet");
            packet[packet_size]<=packet_data;
            if(packet_last != (packet_size==words-1)) $fatal(1,"incorrect packet TLAST");
            packet_size<=packet_size+1;
        end
    end
    qr_postprocess_axis_qrp1_core post (
        .aclk(clk),.aresetn(resetn),.start(start),.start_ready(post_start_ready),
`ifdef QR_TEST_PINGPONG
        .frame_id(read_bank ? 32'd43 : 32'd42),.image_format(8'd1),
`else
        .frame_id(32'd1),.image_format(8'd1),
`endif
        .s_axis_event_tdata(events),.s_axis_event_tkeep(keep),.s_axis_event_tvalid(valid),
        .s_axis_event_tready(ready),.s_axis_event_tlast(last),.ip2_processing_done(ip2_done),
        .ip2_scan_vcc_error(scan_err),.ip2_candidate_overrun_error(overrun_err),
        .ip2_candidate_drop_error(drop_err),.ip2_coordinate_error(coord_err),
        .ip2_arbiter_protocol_error(arb_err),.ip2_row_done_overrun_error(row_overrun),
        .ip2_event_stability_error(stability_err),.ip2_event_row_order_error(order_err),
        .ip2_event_protocol_error(protocol_err),.external_fatal_frame_error(1'b0),.error_clear(1'b0),
        .result_ready(result_ready),.candidate_count(candidates),.result_word_length(words),
        .packet_error_flags(packet_errors),.stream_start(stream_start),.m_axis_result_tready(1'b1),
        .m_axis_result_tdata(packet_data),.m_axis_result_tvalid(packet_valid),.m_axis_result_tlast(packet_last),
        .stored_hit_count(stored),.allocated_label_count(labels),.accumulated_hit_count(accumulated),
        .qualified_property_count(qualified),.error_flags(errors));
    function automatic bit finder(input integer x,y,ox,oy);
        integer mx,my;
        begin
            finder=0;
            if(x>=ox && x<ox+56 && y>=oy && y<oy+56) begin
                mx=(x-ox)/8; my=(y-oy)/8;
                finder=(mx==0 || mx==6 || my==0 || my==6 || (mx>=2 && mx<=4 && my>=2 && my<=4));
            end
        end
    endfunction
    function automatic [31:0] image_word(input integer addr);
        integer x,y,b; reg [31:0] value;
        begin
            y=addr/20; x=(addr%20)*32; value=0;
            for(b=0;b<32;b=b+1) value[31-b]=finder(x+b,y,80,64)||finder(x+b,y,392,64)||finder(x+b,y,80,304);
            image_word=value;
        end
    endfunction
    task automatic run_case(input bit fixed_address);
        integer i, cycles, n, cx, cy, expected_x, expected_y;
        begin
            @(negedge clk); resetn=0; start=0; write_en=0; correct_address=fixed_address;
`ifdef QR_TEST_PINGPONG
            correct_address=1; write_bank=fixed_address; read_bank=fixed_address;
`endif
            repeat(12) @(negedge clk);
            resetn=1; repeat(12) @(negedge clk);
            for(i=0;i<9600;i=i+1) begin
                write_en=1; write_word=i; write_data=image_word(i); @(negedge clk);
            end
            write_en=0; repeat(4) @(negedge clk);
            if(!feature_ready || !post_start_ready) $fatal(1,"start not ready");
            start=1; @(negedge clk); start=0;
`ifdef QR_TEST_PINGPONG
            // Real generated 19200-word BMG: overwrite EVERY word of the other
            // bank while the unchanged feature/QRP1 engine scans this bank.
            write_bank=!read_bank;
            for(i=0;i<9600;i=i+1) begin
                write_en=1; write_word=i; write_data=0; @(negedge clk);
            end
            write_en=0;
`endif
            cycles=0;
            while(!result_ready && cycles<3000000) begin @(negedge clk); cycles=cycles+1; end
            if(!result_ready) $fatal(1,"candidate pipeline timeout");
            $display("CASE address_fixed=%0d raw_pattern_cycles=%0d hits=%0d rows=%0d stored=%0d labels=%0d accumulated=%0d qualified=%0d candidates=%0d words=%0d errors=%08x packet_errors=%08x cycles=%0d",
                fixed_address,raw_cycles,hits,rows,stored,labels,accumulated,qualified,candidates,words,errors,packet_errors,cycles);
            if(errors || packet_errors || feature_err) $fatal(1,"pipeline protocol errors");
`ifdef QR_TEST_PINGPONG
            if(candidates!=3) $fatal(1,"bank isolation/candidate count");
`else
            if(!fixed_address && candidates!=0) $fatal(1,"old address case unexpectedly found candidates");
            if(fixed_address && candidates!=3) $fatal(1,"corrected address did not recover three finder groups");
`endif
            stream_start=1; @(negedge clk); stream_start=0;
            cycles=0;
            while(packet_size<words && cycles<200) begin @(negedge clk); cycles=cycles+1; end
            if(packet_size!=words || packet[0]!=32'h51525031 || packet[1]!=32'h01050500 ||
`ifdef QR_TEST_PINGPONG
               packet[2]!=(read_bank ? 43 : 42) || packet[3]!={words,candidates,8'd1} || packet[4]!=0)
`else
               packet[2]!=1 || packet[3]!={words,candidates,8'd1} || packet[4]!=0)
`endif
                $fatal(1,"QRP1 header/length/frame mismatch");
            for(i=0;i<candidates;i=i+1) begin
                n=packet[5+5*i]>>13;
                if(n!=24) $fatal(1,"unexpected finder HIT count");
                cx=packet[8+5*i]/n; cy=packet[9+5*i]/n;
                expected_x=(i==1)?420:108; expected_y=(i==2)?331:91;
                if(cx<expected_x-1 || cx>expected_x+1 || cy<expected_y-1 || cy>expected_y+1)
                    $fatal(1,"finder centroid does not match fixture");
                $display("QRP1 candidate=%0d hits=%0d cx=%0d cy=%0d",i,n,cx,cy);
            end
        end
    endtask
    initial begin
        run_case(0); run_case(1);
`ifdef QR_TEST_PINGPONG
        $display("PASS: actual 19200-word BMG, both banks, simultaneous opposite-bank write, feature/QRP1 frame and centroids");
`else
        $display("PASS: actual BMG byte-address mismatch reproduced; corrected addresses recover finder candidates");
`endif
        $finish;
    end
endmodule
