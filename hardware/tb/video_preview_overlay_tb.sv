`timescale 1ns/1ps
module video_preview_overlay_tb;
    parameter W=64, H=8, HH=2;
    localparam WORDS=W*HH/32, TIMEOUT=(W==64 ? 10000 : 10000000);
    reg clk=0; always #8 clk=~clk;
    reg resetn=0;
    reg [23:0] sd=0; reg sv=0,su=0,sl=0; wire sr;
    wire [23:0] md; wire mv,mu,ml; reg mr=0;
    reg [14:0] awa=0,ara=0;
    reg awv=0,wv=0,br=0,arv=0,rr=0;
    wire awr,wr,bv,arr,rv; wire [1:0] bp,rp;
    reg [31:0] wd=0; reg [3:0] ws=15; wire [31:0] rd;
    reg cv=0,cr=0,cs=0;
    video_preview_overlay #(.WIDTH(W),.HEIGHT(H),.HUD_HEIGHT(HH),.HUD_TIMEOUT_CYCLES(TIMEOUT)) dut(
        .aclk(clk),.aresetn(resetn),.s_axis_tdata(sd),.s_axis_tvalid(sv),
        .s_axis_tready(sr),.s_axis_tuser(su),.s_axis_tlast(sl),
        .m_axis_tdata(md),.m_axis_tvalid(mv),.m_axis_tready(mr),.m_axis_tuser(mu),.m_axis_tlast(ml),
        .s_axi_awaddr(awa),.s_axi_awprot(3'b0),.s_axi_awvalid(awv),.s_axi_awready(awr),
        .s_axi_wdata(wd),.s_axi_wstrb(ws),.s_axi_wvalid(wv),.s_axi_wready(wr),
        .s_axi_bresp(bp),.s_axi_bvalid(bv),.s_axi_bready(br),
        .s_axi_araddr(ara),.s_axi_arprot(3'b0),.s_axi_arvalid(arv),.s_axi_arready(arr),
        .s_axi_rdata(rd),.s_axi_rresp(rp),.s_axi_rvalid(rv),.s_axi_rready(rr),
        .camera_valid(cv),.camera_ready(cr),.camera_sof(cs));
    reg [23:0] expected[0:W*H*10-1];
    reg expected_user[0:W*H*10-1], expected_last[0:W*H*10-1];
    integer sent=0,received=0,random_state=32'h12345678;
    reg stalled=0; reg [25:0] held;
    reg random_ready=1;
    always @(negedge clk) if(random_ready) mr=($random(random_state)&7)!=0;
    always @(posedge clk) if(resetn) begin
        if(stalled && {mv,mu,ml,md} !== {1'b1,held}) $fatal(1,"AXIS changed during stall");
        stalled=mv&&!mr; held={mu,ml,md};
        if(mv&&mr) begin
            if(received>=sent || md!==expected[received] || mu!==expected_user[received] || ml!==expected_last[received])
                $fatal(1,"pixel %0d data=%h expected=%h user=%b last=%b",received,md,expected[received],mu,ml);
            received=received+1;
        end
    end
    task write_axi(input [14:0] a,input [31:0] d,input [3:0] strobes,input integer order,input [1:0] response);
        begin
            fork
                begin
                    repeat(order==1 ? 5 : 1) @(negedge clk);
                    awa=a; awv=1;
                    do @(posedge clk); while(!awr);
                    @(negedge clk); awv=0;
                end
                begin
                    repeat(order==0 ? 5 : 1) @(negedge clk);
                    wd=d; ws=strobes; wv=1;
                    do @(posedge clk); while(!wr);
                    @(negedge clk); wv=0;
                end
            join
            wait(bv);
            repeat(3) begin @(posedge clk); if(!bv||bp!==response) $fatal(1,"AXI B %h got %b expected %b",a,bp,response); end
            @(negedge clk); br=1; @(posedge clk); @(negedge clk); br=0;
        end
    endtask
    task read_axi(input [14:0] a,input [31:0] want,input [1:0] response);
        begin
            @(negedge clk); ara=a; arv=1;
            do @(posedge clk); while(!arr);
            @(negedge clk); arv=0;
            wait(rv);
            repeat(3) begin @(posedge clk); if(!rv||rp!==response||rd!==want) $fatal(1,"AXI R %h got %h expected %h",a,rd,want); end
            @(negedge clk); rr=1; @(posedge clk); @(negedge clk); rr=0;
        end
    endtask
    task send_frame(input integer mode,input integer seed);
        integer p,r,g,b,lum; reg [23:0] value;
        begin
            for(p=0;p<W*H;p=p+1) begin
                @(negedge clk);
                r=(p*19+seed*7)&255; g=(p*13+seed*17)&255; b=(p*29+seed*37)&255;
                if(p%101==0) begin r=255;g=255;b=255;end
                sd={8'(r),8'(g),8'(b)}; sv=1; su=p==0; sl=p%W==W-1;
                lum=(77*r+150*g+29*b)>>8;
                value=(mode&2) ? {8'(lum),8'(lum),8'(lum)} : sd;
                // Bank0 alternating bits (even=white), bank1 complement.
                if((mode&1) && p<W*HH) value=((p&1)==((mode>>2)&1)) ? 24'hffffff : 0;
                expected[sent]=value; expected_user[sent]=su; expected_last[sent]=sl; sent=sent+1;
                do @(posedge clk); while(!sr);
            end
            @(negedge clk); sv=0;su=0;sl=0;
            wait(received==sent);
        end
    endtask
    integer i, frame_base;
    initial begin
        #200; @(negedge clk);resetn=1;
        read_axi(0,32'h50525631,0);
        read_axi(4,2,0);
        read_axi(1,0,2); read_axi('h2000,0,2);
        send_frame(2,1); // default grayscale, no initialized RAM visible
        for(i=0;i<WORDS;i=i+1) write_axi('h2000+i*4,32'h55555555,15,i%2,0);
        // Byte enable writes and split AW/W ordering.
        write_axi('h2000,32'h12345655,1,0,0);
        write_axi(8,3,15,1,0);
        write_axi(8,7,15,0,2); // reject another commit while pending
        write_axi('h2000,0,15,0,2); // pending bank is immutable
        send_frame(3,2);
        read_axi(4,3,0);read_axi('hc,1,0);
        write_axi('h2000,0,15,0,2); // active bank immutable
        for(i=0;i<WORDS;i=i+1) write_axi('h4000+i*4,32'haaaaaaaa,15,i%2,0);
        write_axi('h4001,0,15,0,2);
        write_axi(8,7,7,0,2); // partial CSR writes disallowed
        frame_base=received;
        fork
            send_frame(3,6);
            begin
                wait(received>frame_base+W*HH+10);
                write_axi(8,7,15,0,0); // commit midway; current frame stays bank0
            end
        join
        send_frame(7,3); // new bank visible starting at very first SOF pixel
        read_axi(4,7,0);read_axi('hc,2,0);
        if(W==64) begin
            repeat(TIMEOUT+10) @(negedge clk);
            send_frame(2,7); // stale HUD hides; video continues without CPU updates
        end
        write_axi(8,0,15,0,0);send_frame(0,4); // full bypass exact RGB
        read_axi('h2c,0,0);read_axi('h14,(W==64?6:5),0);read_axi('h28,5,0);
        @(negedge clk);cv=1;cs=1;cr=0;
        repeat(7) @(negedge clk);
        cr=1;@(negedge clk);cv=0;cs=0;
        read_axi('h10,1,0); // monitor counts handshakes, not held SOF cycles
        // Reset discards pending config and counters without resetting RAM.
        write_axi(8,3,15,0,0);
        random_ready=0; @(negedge clk);mr=0;resetn=0;
        repeat(3) @(negedge clk);resetn=1;stalled=0;random_ready=1;
        read_axi(4,2,0);read_axi('hc,0,0);read_axi('h14,0,0);
        send_frame(2,5);
        $display("PASS: overlay %0dx%0d pixels=%0d AXI split/stall/errors/atomic/bypass/reset/monitor",W,H,received);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"timeout"); end
endmodule
module video_preview_overlay_vga_tb;
    video_preview_overlay_tb #(.W(640),.H(480),.HH(64)) test();
endmodule
