`timescale 1ns/1ps
module qr_frame_pingpong_tb;
    reg clk=0; always #8 clk=!clk;
    reg rst=0;
    reg [5:0] aw=0, ar=0; reg av=0,wv=0,rv=0,br=1,rr=1;
    reg [31:0] wd=0; reg [3:0] ws=15;
    wire awr,wr,bv,arr,rdv; wire [31:0] rd;
    wire allowed,caprel,cs,cd,wb,rb,cr,consumer_sof,consumer_done;
    wire [31:0] nextid,imageid,cid;
    wire [7:0] cm; wire [5:0] cf;
    reg valid=0,user=0,last=0; reg [15:0] pixel=0;
    wire ready,fv,fu,fl; wire [15:0] fp;
    wire [31:0] gray; wire gv,gl,gu; wire [3:0] gk;
    reg gr=1; integer clocks=0;
    wire fready,wren; wire [13:0] wa; wire [31:0] data;
    wire [31:0] wbyte,rbyte; wire [3:0] lanes;
    wire overflow,geom,drop_error;
    wire [15:0] drops;
    reg result_done=0,ack=0;
    wire complete,pending,completion_error;
    wire [31:0] activeid,unusednext; wire activevalid,iderr;
    reg seed=0;
    reg negative=0;
    reg [31:0] mem[0:19199];
    integer image_words=0, overlap_writes=0;
    qr_frame_pingpong #(.INITIAL_ID(32'hfffffffe)) q(
        .aclk(clk),.aresetn(rst),.s_axi_awaddr(aw),.s_axi_awprot(3'b0),
        .s_axi_awvalid(av),.s_axi_awready(awr),.s_axi_wdata(wd),.s_axi_wstrb(ws),
        .s_axi_wvalid(wv),.s_axi_wready(wr),.s_axi_bresp(),.s_axi_bvalid(bv),.s_axi_bready(br),
        .s_axi_araddr(ar),.s_axi_arprot(3'b0),.s_axi_arvalid(rv),.s_axi_arready(arr),
        .s_axi_rdata(rd),.s_axi_rresp(),.s_axi_rvalid(rdv),.s_axi_rready(rr),
        .capture_enable(1'b1),.capture_sof(cs),.capture_image_done(cd),.capture_image_id(imageid),
        .frontend_ready(fready),.frontend_margin(8'd0),.frontend_mode(6'd4),
        .consumer_release(complete),.capture_allowed(allowed),.capture_release(caprel),
        .capture_next_id(nextid),.write_bank(wb),.read_bank(rb),
        .consumer_sof(consumer_sof),.consumer_ready(cr),.consumer_image_done(consumer_done),
        .consumer_image_id(cid),.consumer_margin(cm),.consumer_mode(cf));
    qr_rgb565_gray8_axis_tap #(.EXPECTED_WORDS(32)) tap(
        .aclk(clk),.aresetn(rst),.cfg_width(12'd32),.cfg_height(12'd4),
        .capture_enable(allowed),.frontend_frame_ready(fready),.frame_release(caprel),
        .next_frame_id(nextid),.stat_clear(1'b0),
        .s_axis_tdata(pixel),.s_axis_tvalid(valid),.s_axis_tready(ready),.s_axis_tuser(user),.s_axis_tlast(last),
        .m_fe_axis_tdata(fp),.m_fe_axis_tvalid(fv),.m_fe_axis_tready(1'b1),.m_fe_axis_tuser(fu),.m_fe_axis_tlast(fl),
        .m_img_axis_tdata(gray),.m_img_axis_tvalid(gv),.m_img_axis_tready(gr),.m_img_axis_tkeep(gk),.m_img_axis_tuser(gu),.m_img_axis_tlast(gl),
        .frame_sof_accept(cs),.image_tx_done(cd),.image_frame_id(imageid),.image_word_count(),.frame_drop_count(drops),
        .image_overflow_error(overflow),.image_frame_drop_error(drop_error),.image_geometry_error(geom));
    binary_frame_writer writer(.aclk(clk),.aresetn(rst),.cfg_width(12'd32),.cfg_height(12'd4),.cfg_fb_inv(1'b1),
        .frame_release(caprel),.stat_clear(1'b0),.s_axis_tdata({8{|fp}}),.s_axis_tvalid(fv),.s_axis_tready(),.s_axis_tuser(fu),.s_axis_tlast(fl),
        .wr_en(wren),.wr_addr(wa),.wr_data(data),.m_axis_tdata(),.m_axis_tvalid(),.m_axis_tready(1'b1),.m_axis_tlast(),
        .frame_ready(fready),.frame_num(),.frame_dropped(),.frame_drop_cnt(),.dma_overflow());
    qr_binary_pingpong_address addr(.write_word(wa),.read_word(14'd9599),.write_enable(wren),.read_write_enable(1'b0),
        .write_bank(wb),.read_bank(rb),.write_byte(wbyte),.read_byte(rbyte),.write_lanes(lanes),.read_write_lanes(),
        .reader_clk(clk),.reader_reset(!rst),.reader_enable(1'b0),.reader_din(32'b0),.reader_dout(),
        .memory_clk(),.memory_reset(),.memory_enable(),.memory_din(),.memory_dout(32'b0));
    qr_frame_completion_ctrl comp(.aclk(clk),.aresetn(rst),.frame_start(consumer_sof),
        .image_tx_done(consumer_done),.result_tx_done(result_done),.frame_ack_pulse(ack),.stat_clear(1'b0),
        .image_done_seen(),.result_done_seen(),.frame_complete_pending(pending),.frame_complete(complete),.completion_protocol_error(completion_error));
    qr_frame_id_control ids(.aclk(clk),.aresetn(rst),.seed_write(seed),.seed_value(32'hfffffffe),
        .frame_sof_accept(consumer_sof),.frame_release(complete),.feature_start_accept(consumer_done),.error_clear(1'b0),
        .next_frame_id(unusednext),.active_frame_id(activeid),.active_valid(activevalid),.frame_id_protocol_error(iderr));
    always @(negedge clk) begin clocks=clocks+1; gr=(clocks%5!=0); end
    always @(posedge clk) if(rst) begin
        if(wren) begin
            if(wbyte>=76800 || lanes!=15) $fatal(1,"BRAM byte address/lanes");
            if(q.state[wb]!=1) $fatal(1,"Write outside capturing ownership");
            if(cr && wb==rb) $fatal(1,"Overwriting consumer bank");
            if(cr) overlap_writes=overlap_writes+1;
            mem[wbyte/4]<=data;
        end
        if(gv && gr) begin
            if(gk!=15) $fatal(1,"Gray lanes");
            if(gu) image_words=0;
            image_words=image_words+1;
            if(gl && image_words!=32) $fatal(1,"Partial Gray frame");
        end
        if(completion_error || iderr || overflow || geom || (!negative && q.errors)) $fatal(1,"Protocol error");
        if(cr && activeid!=cid) $fatal(1,"Candidate/image identity mismatch");
    end
    task command(input [31:0] value, input integer order);
        begin
            // Exercise independent AW/W arrival, and delayed B response consumption.
            @(negedge clk); br=0; aw=8; wd=value;
            if(order==0) begin
                av=1; do @(posedge clk); while(!awr);
                @(negedge clk); av=0; repeat(3) @(negedge clk); wv=1;
                do @(posedge clk); while(!wr); @(negedge clk); wv=0;
            end else begin
                wv=1; do @(posedge clk); while(!wr);
                @(negedge clk); wv=0; repeat(2) @(negedge clk); av=1;
                do @(posedge clk); while(!awr); @(negedge clk); av=0;
            end
            wait(bv); repeat(3) @(negedge clk); br=1;
            repeat(2) @(negedge clk);
        end
    endtask
    task frame(input [15:0] color);
        integer p;
        begin
            for(p=0;p<128;p=p+1) begin
                @(negedge clk); valid=1; user=(p==0); last=(p%32==31); pixel=color;
                @(posedge clk); if(!ready) $fatal(1,"Camera stalled");
            end
            @(negedge clk); valid=0; user=0; last=0;
            repeat(30) @(negedge clk);
        end
    endtask
    task read_csr(input [5:0] address,input [31:0] expected);
        begin
            @(negedge clk); ar=address; rv=1; rr=0;
            do @(posedge clk); while(!arr);
            @(negedge clk); rv=0; wait(rdv);
            repeat(5) begin
                @(negedge clk); if(!rdv || rd!=expected) $fatal(1,"AXI read backpressure");
            end
            rr=1; repeat(2) @(negedge clk);
        end
    endtask
    task finish_consumer;
        begin
            wait(cr); @(negedge clk); result_done=1;
            @(negedge clk); result_done=0; wait(pending);
            repeat(50) @(negedge clk); // delayed PS ACK keeps bank owned
            ack=1; @(negedge clk); ack=0; wait(!cr);
            repeat(8) @(negedge clk);
        end
    endtask
    task reset_all;
        begin
            @(negedge clk); rst=0; valid=0; user=0; last=0;
            repeat(5) @(negedge clk); rst=1; seed=1;
            @(negedge clk); seed=0;
        end
    endtask
    initial begin
        reset_all(); read_csr(0,32'h51505031); read_csr(4,32'h00010000);
        read_csr(6'h2c,32'h01e00280);
        ws=0; command(3,0); if(allowed || q.dispatch) $fatal(1,"WSTRB ignored"); ws=15;
        command(3,0); frame(0); wait(cr);
        if(cid!=32'hfffffffe || rb!=0 || mem[0]!=32'hffffffff) $fatal(1,"First bank");
        command(1,1); frame(16'hffff);
        if(q.accepted!=2 || q.completed!=2 || mem[0]!=32'hffffffff || mem[9600]!=0 || overlap_writes!=4) $fatal(1,"Overlap banks");
        command(1,0); frame(0); // both banks owned: whole frame must drop, credit stays
        if(q.accepted!=2 || drops!=1 || !q.credit) $fatal(1,"Full/drop contract");
        finish_consumer(); command(2,1); wait(cr);
        if(cid!=32'hffffffff || rb!=1 || rbyte!=76796) $fatal(1,"Second bank/address");
        frame(0); // pending credit now captures wrapped ID 0 into released bank 0
        if(q.accepted!=3 || imageid!=0 || mem[9600]!=0) $fatal(1,"Wrap/capture isolation");
        finish_consumer(); command(2,0); wait(cr);
        if(cid!=0 || rbyte!=38396) $fatal(1,"Wrapped descriptor");
        finish_consumer();
        // Reset while an accepted frame is incomplete: both engines/DMA reset together.
        command(3,1); @(negedge clk); valid=1; user=1; pixel=0;
        @(negedge clk); valid=0; user=0; reset_all();
        if(allowed || q.accepted || q.state[0] || q.state[1]) $fatal(1,"Reset ownership");
        command(3,0); frame(0); wait(cr); finish_consumer();
        reset_all(); negative=1;
        command(1,0); command(1,1);
        if(q.errors!=1 || allowed) $fatal(1,"Duplicate credit must fail closed");
        reset_all();
        force q.consumer_release=1; repeat(2) @(negedge clk); release q.consumer_release;
        if(q.errors!=16 || allowed) $fatal(1,"Illegal release must fail closed");
        reset_all(); command(3,0);
        force q.capture_image_id=32'h12345678;
        frame(0); release q.capture_image_id;
        if(q.errors!=8 || allowed || cr) $fatal(1,"Wrong image ID must fail closed");
        $display("PASS: pingpong real tap/writer overlap, backpressure, full/drop, delayed ACK, independent AXI, ID wrap, reset");
        $display("PASS: duplicate credit, illegal release, mismatched image ID fail closed");
        $finish;
    end
    initial begin #2000000; $fatal(1,"Timeout"); end
endmodule
