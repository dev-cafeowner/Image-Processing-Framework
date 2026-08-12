`timescale 1ns / 1ps

module qr_event_fifo #(
    parameter DATA_WIDTH = 21,
    parameter DEPTH      = 32,
    parameter ADDR_WIDTH = 5
) (
    input  wire                  aclk,
    input  wire                  aresetn,

    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire [DATA_WIDTH-1:0] s_data,

    output wire                  m_valid,
    input  wire                  m_ready,
    output wire [DATA_WIDTH-1:0] m_data,

    output wire                  full,
    output wire                  empty
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;

    wire push;
    wire pop;

    assign full    = (count == DEPTH);
    assign empty   = (count == 0);
    assign m_valid = !empty;
    assign m_data  = mem[rd_ptr];

    // The interface definition requires ready=0 whenever the FIFO is full.
    // Even if a pop occurs in this clock, a new push is accepted from the
    // following clock after count has decreased.
    assign s_ready = !full;
    assign push    = s_valid && s_ready;
    assign pop     = m_valid && m_ready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
            rd_ptr <= {ADDR_WIDTH{1'b0}};
            count  <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            if (push) begin
                mem[wr_ptr] <= s_data;
                if (wr_ptr == DEPTH-1)
                    wr_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            if (pop) begin
                if (rd_ptr == DEPTH-1)
                    rd_ptr <= {ADDR_WIDTH{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
