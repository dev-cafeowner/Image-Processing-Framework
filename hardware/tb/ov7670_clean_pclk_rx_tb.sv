`timescale 1ns/1ps
module ov7670_clean_pclk_rx_tb;
    parameter W=64, H=8, DEPTH=512;
    reg clk=0; always #8 clk=~clk;
    real halfp=20.833333;
    reg pclk=0; always #(halfp) pclk=~pclk;
    reg resetn=0, href=0, vsync=0, en=0, clear=0;
    wire clean_pclk, clean_locked;
    ov7670_pclk_clean_clock conditioner (.pclk_in(pclk),.enable(resetn),.pclk_out(clean_pclk),.locked(clean_locked));
    reg [7:0] data=0;
    reg ready=1, force_stall=0, score=1;
    reg [31:0] random_bits=32'hb1234abc;
    wire [15:0] pixel;
    wire valid,sof,eol,busy;
    wire [31:0] status,fifo_status,pc,fc,px,lost,bad,period,maxperiod;
    ov7670_pclk_rx #(.FIFO_DEPTH(DEPTH),.EXPECTED_WIDTH(W)) dut (
        .aclk(clk),.aresetn(resetn && clean_locked),.pclk(clean_pclk),.cam_href(href),.cam_vsync(vsync),.cam_data(data),
        .capture_en(en),.stat_clear(clear),.clear_busy(busy),
        .m_axis_tdata(pixel),.m_axis_tvalid(valid),.m_axis_tready(ready),.m_axis_tuser(sof),.m_axis_tlast(eol),
        .cam_status(status),.fifo_status(fifo_status),.pclk_count(pc),.lost_tokens(lost),
        .frame_count(fc),.pixel_count(px),.bad_lines(bad),.frame_period(period),.frame_period_max(maxperiod));
    reg [17:0] expected[0:1000000];
    integer queued=0,seen=0,total_seen=0;
    reg held=0;
    reg [17:0] held_word;
    always @(negedge clk) begin
        random_bits <= {random_bits[30:0],random_bits[31]^random_bits[21]^random_bits[1]^random_bits[0]};
        ready <= !force_stall && random_bits[2:0]!=0;
    end
    always @(posedge clk) begin
        if (resetn && en && held && {sof,eol,pixel}!==held_word) $fatal(1,"AXIS changed while stalled");
        held<=resetn && en && valid && !ready;
        held_word<={sof,eol,pixel};
        if (resetn && valid && ready && score) begin
            if (seen>=queued || {sof,eol,pixel}!==expected[seen])
                $fatal(1,"pixel %d actual=%h expected=%h",seen,{sof,eol,pixel},expected[seen]);
            seen=seen+1; total_seen=total_seen+1;
        end
    end
    task token(input bit v,input bit h,input [7:0] d);
        @(negedge pclk); #5; vsync=v; href=h; data=d;
    endtask
    task sync_frame;
        repeat(8) token(1,0,0);
        repeat(16) token(0,0,0);
    endtask
    task frame(input integer seed,input bit expect_it);
        reg [15:0] word;
        sync_frame();
        for (integer y=0;y<H;y++) begin
            for (integer x=0;x<W;x++) begin
                word=16'((seed*613+y*W+x)*1907);
                if (expect_it) begin expected[queued]={x==0 && y==0,x==W-1,word}; queued++; end
                token(0,1,word[15:8]); token(0,1,word[7:0]);
            end
            repeat(288) token(0,0,0);
        end
        if (W==640 && H==480) repeat(30*1568-24) token(0,0,0);
    endtask
    task reset_dut;
        @(negedge clk); resetn=0; en=0; force_stall=0; href=0; vsync=0;
        repeat(40) @(negedge pclk);
        queued=0; seen=0;
        resetn=1; wait(clean_locked); #10000;
        repeat(80) token(0,0,0);
    endtask
    task check_done;
        repeat(100) token(0,0,0);
        if (seen!=queued || status[24] || lost!=0 || bad!=0)
            $fatal(1,"count/overflow/geometry seen=%d queued=%d status=%h lost=%d bad=%d",seen,queued,status,lost,bad);
    endtask
    initial begin
        if (W==640) begin
            reset_dut(); en=1;
            frame(1,1); frame(2,1); sync_frame(); check_done();
            if (status[11:0]!=W || status[23:12]!=H) $fatal(1,"VGA measured dimensions");
            // 1568 PCLKs/line, 510 lines/frame at 24MHz => 33.32ms.
            if (period<2082400 || period>2082600) $fatal(1,"VGA period cycles=%d",period);
        end else begin
            for(integer phase=0;phase<6;phase++) begin
                halfp=(phase<3) ? 20.833333 : 20.0;
                #(phase*1.37);
                reset_dut();
                frame(1,0); // Measurement works while capture disabled.
                if (valid) $fatal(1,"Disabled output");
                en=1; frame(2,1); frame(3,1); sync_frame(); check_done();
                if (status[11:0]!=W || status[23:12]!=H || !status[25]) $fatal(1,"Status dimensions");
            end
            // Enabled mid-frame: wait for next frame boundary.
            reset_dut(); sync_frame(); en=1;
            repeat(20) token(0,1,8'hfa);
            repeat(20) token(0,0,0);
            if (valid || seen!=0) $fatal(1,"Mid-frame enable leaked pixels");
            // Reset removes malformed-line diagnostic before normal check.
            reset_dut(); en=1; frame(4,1); check_done();
            // Sustained downstream blockage must be visible, never silently lost.
            score=0; force_stall=1;
            frame(5,0); repeat(1000) token(0,0,0);
            if (!status[24] || lost==0) $fatal(1,"Overflow not reported");
            force_stall=0; repeat(2000) token(0,0,0);
            @(negedge clk); clear=1; @(negedge clk); clear=0;
            repeat(100) token(0,0,0);
            if (status[24] || busy) $fatal(1,"Sticky clear/handshake failed");
            reset_dut(); score=1; en=1; frame(6,1); check_done();
        end
        $display("PASS: source-synchronous receiver W=%0d H=%0d pixels=%0d",W,H,total_seen);
        $finish;
    end
    initial begin #200000000; $fatal(1,"Timeout"); end
endmodule

module ov7670_clean_pclk_rx_vga_tb;
    ov7670_clean_pclk_rx_tb #(.W(640),.H(480),.DEPTH(4096)) test();
endmodule
