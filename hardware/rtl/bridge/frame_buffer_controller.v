`timescale 1ns/1ps
// Common frame ownership layer. The feature engine remains a single consumer.
// Two 9600-word binary banks, one one-shot PS Gray8 DMA credit per accepted SOF.
// Neither bank is reused until that frame's result/image ACK releases it.
module frame_buffer_controller #(
    parameter [31:0] INITIAL_ID = 0
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn" *) input wire aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *) input wire aresetn,
    input wire [5:0] s_axi_awaddr, input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid, output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output wire [1:0] s_axi_bresp, output reg s_axi_bvalid, input wire s_axi_bready,
    input wire [5:0] s_axi_araddr, input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid, output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output wire [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready,
    input wire capture_enable,
    input wire capture_sof, input wire capture_image_done,
    input wire [31:0] capture_image_id,
    input wire frontend_ready, input wire [7:0] frontend_margin,
    input wire [5:0] frontend_mode,
    input wire consumer_release,
    output wire capture_allowed, output reg capture_release,
    output reg [31:0] capture_next_id,
    output reg write_bank, output reg read_bank,
    output reg consumer_sof, output reg consumer_ready,
    output reg consumer_image_done,
    output reg [31:0] consumer_image_id,
    output reg [7:0] consumer_margin, output reg [5:0] consumer_mode
);
    localparam FREE=0, CAPTURING=1, READY=2, CONSUMING=3;
    reg [1:0] state [0:1];
    reg [31:0] id [0:1];
    reg [7:0] margin [0:1];
    reg [5:0] mode [0:1];
    reg tail, head, capturing, image_seen, fe_seen;
    reg credit, dispatch, consumer_active;
    reg [31:0] completed_id, accepted, completed, released, errors;
    reg aw_hold, w_hold;
    reg [5:0] aw_addr;
    reg [31:0] w_data;
    reg [3:0] w_strb;
    wire write_fire = aw_hold && w_hold && !s_axi_bvalid;
    wire command = write_fire && aw_addr == 6'h08 && w_strb[0];
    assign s_axi_awready = !aw_hold && !s_axi_bvalid;
    assign s_axi_wready = !w_hold && !s_axi_bvalid;
    assign s_axi_bresp = 2'b00;
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp = 2'b00;
    assign capture_allowed = capture_enable && credit && !capturing &&
                             !frontend_ready && state[tail] == FREE && errors == 0;
    integer i;
    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_hold<=0; w_hold<=0; aw_addr<=0; w_data<=0; w_strb<=0;
            s_axi_bvalid<=0; s_axi_rvalid<=0; s_axi_rdata<=0;
            tail<=0; head<=0; capturing<=0; image_seen<=0; fe_seen<=0;
            credit<=0; dispatch<=0; consumer_active<=0;
            write_bank<=0; read_bank<=0; capture_release<=0;
            capture_next_id<=INITIAL_ID; consumer_image_id<=INITIAL_ID;
            consumer_margin<=0; consumer_mode<=0;
            consumer_sof<=0; consumer_ready<=0; consumer_image_done<=0;
            completed_id<=INITIAL_ID; accepted<=0; completed<=0; released<=0; errors<=0;
            for(i=0;i<2;i=i+1) begin state[i]<=FREE; id[i]<=0; margin[i]<=0; mode[i]<=0; end
        end else begin
            capture_release<=0; consumer_sof<=0; consumer_image_done<=0;
            if(s_axi_awvalid && s_axi_awready) begin aw_hold<=1; aw_addr<=s_axi_awaddr; end
            if(s_axi_wvalid && s_axi_wready) begin w_hold<=1; w_data<=s_axi_wdata; w_strb<=s_axi_wstrb; end
            if(s_axi_bvalid && s_axi_bready) s_axi_bvalid<=0;
            if(write_fire) begin aw_hold<=0; w_hold<=0; s_axi_bvalid<=1; end
            if(s_axi_rvalid && s_axi_rready) s_axi_rvalid<=0;
            if(s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid<=1;
                case(s_axi_araddr)
                    6'h00: s_axi_rdata<=32'h51505031; // QPP1
                    6'h04: s_axi_rdata<=32'h00010000;
                    6'h08: s_axi_rdata<=0; // W1 commands: credit, dispatch
                    6'h0c: s_axi_rdata<={24'b0,state[1],state[0],consumer_active,capturing,dispatch,credit};
                    6'h10: s_axi_rdata<=capture_next_id;
                    6'h14: s_axi_rdata<=completed_id;
                    6'h18: s_axi_rdata<=accepted;
                    6'h1c: s_axi_rdata<=completed;
                    6'h20: s_axi_rdata<=released;
                    6'h24: s_axi_rdata<=errors;
                    6'h28: s_axi_rdata<=consumer_image_id;
                    6'h2c: s_axi_rdata<=32'h01e00280; // height=480,width=640
                    default: s_axi_rdata<=0;
                endcase
            end
            // No soft reset/clear command can discard ownership. Recovery requires
            // quiescing DMA/camera and resetting the whole hardware design.
            if(command && w_data[0]) begin
                if(credit) errors[0]<=1; else credit<=1;
            end
            if(command && w_data[1]) begin
                if(dispatch || consumer_active) errors[1]<=1; else dispatch<=1;
            end
            if(capture_sof) begin
                if(!capture_allowed) errors[2]<=1;
                else begin
                    credit<=0; capturing<=1; image_seen<=0; fe_seen<=0;
                    write_bank<=tail; state[tail]<=CAPTURING;
                    id[tail]<=capture_next_id; mode[tail]<=frontend_mode;
                    margin[tail]<=frontend_margin;
                    tail<=!tail; capture_next_id<=capture_next_id+1;
                    accepted<=accepted+1;
                end
            end
            if(capture_image_done) begin
                if(!capturing || image_seen || capture_image_id != id[write_bank]) errors[3]<=1;
                else begin
                    image_seen<=1; completed_id<=capture_image_id; completed<=completed+1;
                end
            end
            if(capturing && frontend_ready) fe_seen<=1;
            // Wait an extra cycle after both commits. The last registered BRAM
            // write has retired before READY and before changing the write bank.
            if(capturing && image_seen && fe_seen) begin
                state[write_bank]<=READY; capturing<=0; capture_release<=1;
            end
            if(dispatch && !consumer_active && state[head]==READY && errors==0) begin
                dispatch<=0; consumer_active<=1; state[head]<=CONSUMING;
                read_bank<=head; consumer_image_id<=id[head];
                consumer_margin<=margin[head]; consumer_mode<=mode[head];
                consumer_sof<=1;
            end
            // Completion starts on virtual SOF in the preserved runtime wrapper.
            // Replay the already finished image strictly AFTER that SOF.
            if(consumer_sof) begin consumer_ready<=1; consumer_image_done<=1; end
            if(consumer_release) begin
                if(!consumer_active || !consumer_ready || state[head]!=CONSUMING) errors[4]<=1;
                else begin
                    state[head]<=FREE; head<=!head; consumer_active<=0;
                    consumer_ready<=0; released<=released+1;
                end
            end
        end
    end
endmodule
