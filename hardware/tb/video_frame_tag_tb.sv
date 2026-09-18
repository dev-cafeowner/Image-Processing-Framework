`timescale 1ns/1ps
module video_frame_tag_tb;
    reg clk=0;always #8 clk=~clk;
    reg resetn=0,iv=0,iu=0,il=0,oready=0;
    reg [23:0] idata=0;
    wire ir,mv,mr,mu,ml,ov,ou,ol;
    wire [23:0] md,od;
    video_frame_tag camera(.aclk(clk),.aresetn(resetn),.s_axis_tdata(idata),.s_axis_tvalid(iv),.s_axis_tready(ir),.s_axis_tuser(iu),.s_axis_tlast(il),.m_axis_tdata(md),.m_axis_tvalid(mv),.m_axis_tready(mr),.m_axis_tuser(mu),.m_axis_tlast(ml));
    video_frame_tag #(.SCAN_TAG(1)) scan(.aclk(clk),.aresetn(resetn),.s_axis_tdata(md),.s_axis_tvalid(mv),.s_axis_tready(mr),.s_axis_tuser(mu),.s_axis_tlast(ml),.m_axis_tdata(od),.m_axis_tvalid(ov),.m_axis_tready(oready),.m_axis_tuser(ou),.m_axis_tlast(ol));
    integer sent=0,received=0,f,p,x,y;
    reg held=0;reg [25:0] last;
    reg [15:0] expected_id;reg [47:0] code;reg [7:0] pre;
    reg [23:0] expected;
    always @(negedge clk) oready <= $urandom_range(0,3)!=0;
    always @(posedge clk) if(resetn) begin
        if(held && (!ov || {od,ou,ol}!==last)) $fatal(1,"Changed under backpressure");
        held=ov && !oready;last={od,ou,ol};
        if(ov && oready) begin
            p=received%(640*480);x=p%640;y=p/640;
            expected_id=16'hffff+received/(640*480);
            pre=(y>=464 && y<476) ? 8'ha6:8'hd3;
            code={pre,expected_id,~expected_id,(expected_id[15:8]^expected_id[7:0]^pre^8'h5a)};
            expected=24'h2468ac;
            if(x>=128 && x<512 && ((y>=64&&y<76)||(y>=448&&y<460)||(y>=464&&y<476)))
                expected={24{code[47-(x-128)/8]}};
            if(od!==expected || ou!==(p==0) || ol!==(x==639))
                $fatal(1,"Tag/passthrough mismatch pixel %0d got %h expected %h",received,od,expected);
            received=received+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk);resetn=1;
        camera.frame_id=16'hfffe;scan.frame_id=16'hfffe;
        for(sent=0;sent<3*640*480;sent=sent+1) begin
            @(negedge clk);
            if($urandom_range(0,7)==0) begin iv=0;@(negedge clk);end
            iv=1;idata=24'h2468ac;iu=(sent%(640*480)==0);il=(sent%640==639);
            @(posedge clk);while(!ir) @(posedge clk);
        end
        @(negedge clk);iv=0;
        wait(received==3*640*480);
        @(negedge clk);resetn=0;repeat(3) @(negedge clk);
        if(camera.frame_id!==0 || scan.frame_id!==0 || ov!==0) $fatal(1,"Reset failed");
        $display("PASS: camera/scan identity bands, passthrough, sidebands, random backpressure, ID wrap and reset");
        $finish;
    end
    initial begin #100000000;$fatal(1,"Timeout");end
endmodule
