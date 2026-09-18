`timescale 1ns/1ps
// Digital phase sweep, not an analog signal-integrity/metastability proof.
module ov7670_fast_capture_tb;
    reg clk=0; always #8 clk=~clk; // 62.5 MHz
    reg resetn=0, pclk=0, href=0, vsync=0;
    reg [7:0] data=0;
    wire xclk, valid, sof, eol, overflow, vs_seen;
    wire [15:0] pixel;
    wire [11:0] width, height;
    wire [31:0] status;
    ov7670_capture #(.XCLK_DIV(2)) dut (
        .aclk(clk),.aresetn(resetn),.cam_pclk(pclk),.cam_href(href),
        .cam_vsync(vsync),.cam_data(data),.cam_xclk(xclk),
        .capture_en(1'b1),.stat_clear(1'b0),.m_axis_tdata(pixel),
        .m_axis_tvalid(valid),.m_axis_tready(1'b1),.m_axis_tuser(sof),
        .m_axis_tlast(eol),.cam_line_len(width),.cam_frame_lines(height),
        .cam_overflow(overflow),.cam_vsync_seen(vs_seen),.cam_status(status));
    reg [15:0] expected[0:127];
    integer seen=0, queued=0;
    always @(posedge clk) if (resetn && valid) begin
        if(seen>=queued || pixel!==expected[seen]) $fatal(1,"Byte alignment/data mismatch at %d",seen);
        if(sof!==(seen%64==0) || eol!==(seen%16==15)) $fatal(1,"Framing mismatch");
        seen=seen+1;
    end
    task send_byte(input [7:0] b);
        begin pclk=0; data=b; #32; pclk=1; #32; pclk=0; end
    endtask
    task frame_sync;
        begin href=0; vsync=1; #256; vsync=0; #256; end
    endtask
    initial begin
        for(integer phase=1;phase<16;phase=phase+1) begin
            @(negedge clk); resetn=0; pclk=0; href=0; vsync=0;
            repeat(5) @(negedge clk);
            seen=0; queued=0; resetn=1;
            #(phase);
            for(integer f=0;f<2;f=f+1) begin
                frame_sync();
                for(integer y=0;y<4;y=y+1) begin
                    href=1; #64;
                    for(integer x=0;x<16;x=x+1) begin
                        expected[queued]=16'(phase*2048+f*64+y*16+x);
                        queued=queued+1;
                        send_byte(expected[queued-1][15:8]);
                        send_byte(expected[queued-1][7:0]);
                    end
                    href=0; #256;
                end
            end
            frame_sync(); #256;
            if(seen!=128 || width!=16 || height!=4 || overflow || !vs_seen)
                $fatal(1,"Capture status failed phase=%d count=%d status=%h",phase,seen,status);
        end
        $display("PASS: OV7670 15.625 MHz PCLK / 62.5 MHz receiver, 15 phases, exact pixels and framing");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Timeout"); end
endmodule
