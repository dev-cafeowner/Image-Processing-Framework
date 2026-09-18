`timescale 1ns/1ps
module ov7670_camera_interface_tb;
    reg aclk=0; always #8 aclk=~aclk;
    reg refclk=0; always #5 refclk=~refclk;
    reg pclk=0; always #20.833333 pclk=~pclk;
    reg resetn=0;
    reg [5:0] aw=0,ar=0;
    reg [31:0] wd=0;
    reg [3:0] ws=0;
    reg av=0,wv=0,br=0,arv=0,rr=0;
    wire awr,wr,bv,arr,rv,xc;
    wire [1:0] bp,rp;
    wire [31:0] rd;
    ov7670_camera_interface dut (.aclk(aclk),.aresetn(resetn),.refclk100(refclk),
        .cam_pclk(pclk),.cam_href(1'b0),.cam_vsync(1'b0),.cam_data(8'd0),.cam_xclk(xc),
        .s_axi_awaddr(aw),.s_axi_awprot(3'd0),.s_axi_awvalid(av),.s_axi_awready(awr),
        .s_axi_wdata(wd),.s_axi_wstrb(ws),.s_axi_wvalid(wv),.s_axi_wready(wr),
        .s_axi_bresp(bp),.s_axi_bvalid(bv),.s_axi_bready(br),
        .s_axi_araddr(ar),.s_axi_arprot(3'd0),.s_axi_arvalid(arv),.s_axi_arready(arr),
        .s_axi_rdata(rd),.s_axi_rresp(rp),.s_axi_rvalid(rv),.s_axi_rready(rr),.m_axis_tready(1'b1));
    task write_reg(input [5:0] addr,input [31:0] data,input [3:0] strobe,input integer order,input [1:0] response);
        fork
            begin
                repeat(order==1 ? 5 : 0) @(negedge aclk);
                aw=addr; av=1;
                do @(posedge aclk); while(!awr);
                @(negedge aclk); av=0;
            end
            begin
                repeat(order==2 ? 5 : 0) @(negedge aclk);
                wd=data; ws=strobe; wv=1;
                do @(posedge aclk); while(!wr);
                @(negedge aclk); wv=0;
            end
        join
        wait(bv); repeat(5) begin @(negedge aclk); if(!bv || bp!=response) $fatal(1,"B response stall/order"); end
        br=1; @(negedge aclk); br=0;
    endtask
    task read_reg(input [5:0] addr,input [31:0] expected,input [1:0] response);
        reg [31:0] value;
        @(negedge aclk); ar=addr; arv=1;
        do @(posedge aclk); while(!arr);
        @(negedge aclk); arv=0;
        wait(rv); value=rd;
        if(value!==expected || rp!==response) $fatal(1,"Read address=%h actual=%h expected=%h",addr,value,expected);
        repeat(6) begin @(negedge aclk); if(!rv || rd!==value || rp!==response) $fatal(1,"R response changed under stall"); end
        rr=1; @(negedge aclk); rr=0;
    endtask
    real last_edge,delta;
    initial begin
        #2000; @(negedge aclk); resetn=1;
        #20000;
        read_reg('h10,32'h43414d33,0); read_reg('hc,32'h00030000,0);
        read_reg('h30,1,0);
        read_reg('h34,0,0); write_reg('h34,1,1,0,0); #50000;
        read_reg('h34,3,0); read_reg('h38,0,0);
        @(posedge xc); last_edge=$realtime;
        repeat(20) begin
            @(posedge xc); delta=$realtime-last_edge; last_edge=$realtime;
            if(delta<41.64 || delta>41.69) $fatal(1,"XCLK period %f",delta);
        end
        write_reg(0,1,1,1,0); read_reg(0,1,0); // W before AW
        write_reg(0,0,1,2,0); read_reg(0,0,0); // AW before W
        write_reg(0,1,0,0,0); read_reg(0,0,0); // No byte0 strobe
        write_reg(1,1,15,0,2); read_reg(1,0,2);
        write_reg('h10,1,15,0,2); read_reg('h10,32'h43414d33,0);
        write_reg(0,3,1,0,0); #2000; read_reg('h30,1,0); read_reg(0,1,0);
        write_reg('h34,0,1,0,2); read_reg('h34,3,0); // Reject clock stop during capture.
        write_reg(0,0,1,0,0); write_reg('h34,0,1,0,0); #2000;
        read_reg('h34,4,0); read_reg('h38,1,0); // Lock loss survives receiver reset.
        write_reg('h34,1,1,0,0); #50000;
        read_reg('h34,7,0); read_reg('h38,1,0);
        $display("PASS: CAM3 AXI independent channels, response stalls, WSTRB, address checks, clear handshake, 24MHz XCLK");
        $finish;
    end
    initial begin #500000; $fatal(1,"Timeout"); end
endmodule
