`timescale 1ns/1ps
module qr_rgb565_gray8_axis_tap_tb;
    reg clk=0; always #5 clk=~clk;
    reg resetn=0, enable=0, fe_ready_status=0, release_frame=0, clear=0;
    reg [15:0] data=0;
    reg valid=0, sof=0, eol=0, fe_ready=1, img_ready=1;
    wire ready, fe_valid, fe_sof, fe_eol, img_valid, img_sof, img_last;
    wire [15:0] fe_data, drops;
    wire [31:0] img_data, image_id;
    wire [3:0] keep;
    wire [16:0] words;
    wire accepted, done, overflow, dropped, geometry;
    reg [31:0] next_id=100;
    qr_rgb565_gray8_axis_tap #(.FIFO_DEPTH(8),.FIFO_AW(3),.EXPECTED_WORDS(16)) dut (
        .aclk(clk),.aresetn(resetn),.cfg_width(12'd16),.cfg_height(12'd4),
        .capture_enable(enable),.frontend_frame_ready(fe_ready_status),
        .frame_release(release_frame),.next_frame_id(next_id),.stat_clear(clear),
        .s_axis_tdata(data),.s_axis_tvalid(valid),.s_axis_tready(ready),
        .s_axis_tuser(sof),.s_axis_tlast(eol),
        .m_fe_axis_tdata(fe_data),.m_fe_axis_tvalid(fe_valid),.m_fe_axis_tready(fe_ready),
        .m_fe_axis_tuser(fe_sof),.m_fe_axis_tlast(fe_eol),
        .m_img_axis_tdata(img_data),.m_img_axis_tvalid(img_valid),.m_img_axis_tready(img_ready),
        .m_img_axis_tkeep(keep),.m_img_axis_tuser(img_sof),.m_img_axis_tlast(img_last),
        .frame_sof_accept(accepted),.image_tx_done(done),.image_frame_id(image_id),
        .image_word_count(words),.frame_drop_count(drops),
        .image_overflow_error(overflow),.image_frame_drop_error(dropped),.image_geometry_error(geometry));
    reg [31:0] expected[0:255];
    reg [31:0] pack=0;
    integer fe_pixels=0, pushed=0, popped=0, accepts=0, completions=0;
    reg check_data=1, random_stalls=0;
    reg [31:0] rng=32'h13579;
    reg stalled=0;
    reg [37:0] stalled_word;
    function [7:0] gray(input [15:0] rgb);
        integer r,g,b;
        begin
            r={rgb[15:11],rgb[15:13]}; g={rgb[10:5],rgb[10:9]}; b={rgb[4:0],rgb[4:2]};
            gray=(77*r+150*g+29*b)>>8;
        end
    endfunction
    always @(negedge clk) if (random_stalls) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        img_ready=rng[0]|rng[1]; fe_ready=rng[2]|rng[3];
    end
    always @(posedge clk) if (resetn) begin
        if (accepted) begin accepts=accepts+1; next_id<=next_id+1; end
        if (done) completions=completions+1;
        if (check_data) begin
            if (accepted !== (fe_valid && fe_ready && fe_sof)) $fatal(1,"FE/Gray SOF mismatch");
            if (fe_valid && fe_ready) begin
                if (fe_sof !== (fe_pixels%64==0)) $fatal(1,"FE SOF position");
                if (fe_eol !== (fe_pixels%16==15)) $fatal(1,"FE EOL position");
                pack[(fe_pixels%4)*8 +: 8]=gray(fe_data);
                if (fe_pixels%4==3) begin expected[pushed]=pack; pushed=pushed+1; end
                fe_pixels=fe_pixels+1;
            end
            if (stalled && {img_data,keep,img_sof,img_last} !== stalled_word)
                $fatal(1,"AXIS changed while stalled");
            stalled=img_valid && !img_ready;
            stalled_word={img_data,keep,img_sof,img_last};
            if (img_valid && img_ready) begin
                if (popped>=pushed || img_data!==expected[popped]) $fatal(1,"Frame data mismatch %d",popped);
                if (keep!==4'hf || img_sof!==(popped%16==0) || img_last!==(popped%16==15))
                    $fatal(1,"DMA framing mismatch");
                popped=popped+1;
            end
        end
    end
    task pixel(input integer frame, input integer p);
        begin
            @(negedge clk); data=16'(frame*1000+p); valid=1; sof=(p==0); eol=(p%16==15);
            @(posedge clk); while (!ready) @(posedge clk);
            @(negedge clk); valid=0; sof=0; eol=0;
        end
    endtask
    task frame(input integer f, input integer disable_at);
        integer p;
        begin for (p=0;p<64;p=p+1) begin
            if (p==disable_at) enable=0;
            pixel(f,p);
        end end
    endtask
    task ack;
        begin @(negedge clk); release_frame=1; fe_ready_status=0;
            @(negedge clk); release_frame=0; end
    endtask
    initial begin
        #100000; $fatal(1,"Test timeout");
    end
    initial begin
        repeat(5) @(negedge clk); resetn=1;
        // Disabled frames drain even with a blocked FE.
        fe_ready=0; frame(1,-1);
        if (accepts!=0 || fe_pixels!=0) $fatal(1,"Disabled accepted");
        fe_ready=1; enable=1; random_stalls=1;
        frame(2,5); repeat(60) @(negedge clk);
        if (completions!=1 || words!=16 || image_id!=100) $fatal(1,"Mid-frame disable truncated");
        enable=1; frame(3,-1); // busy BEFORE frame_ready rises
        fe_ready_status=1; frame(4,-1);
        if (accepts!=1) $fatal(1,"Slot reused before ACK");
        ack(); frame(5,-1); repeat(60) @(negedge clk);
        if (accepts!=2 || completions!=2 || popped!=32 || image_id!=101) $fatal(1,"Release recovery");
        if (overflow || dropped || geometry) $fatal(1,"Unexpected diagnostic");
        if (drops!=3) $fatal(1,"Skip count");
        // Release midway through a rejected frame: do not capture its tail.
        for (integer p=0;p<64;p=p+1) begin if(p==20) ack(); pixel(6,p); end
        frame(7,-1); repeat(60) @(negedge clk);
        if (accepts!=3 || completions!=3 || popped!=48) $fatal(1,"Mid-frame release");
        // Deliberate FIFO exhaustion is visible, never camera backpressure.
        random_stalls=0; fe_ready=1; check_data=0; ack(); img_ready=0;
        frame(8,-1); repeat(20) @(negedge clk);
        if (!overflow) $fatal(1,"Missing overflow diagnostic");
        resetn=0; repeat(5) @(negedge clk); resetn=1; img_ready=1;
        for(integer p=0;p<20;p=p+1) pixel(9,p);
        frame(10,-1); repeat(20) @(negedge clk);
        if (!geometry || !dropped) $fatal(1,"Missing truncated-frame diagnostic");
        $display("PASS: same-frame data, SOF/EOF, stalls, enable, busy slot, release, skip, overflow, malformed input");
        $finish;
    end
endmodule
