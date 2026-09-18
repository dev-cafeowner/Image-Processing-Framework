`timescale 1ns/1ps
module qr_binary_pingpong_address (
    input wire [13:0] write_word, input wire [13:0] read_word,
    input wire write_enable, input wire read_write_enable,
    input wire write_bank, input wire read_bank,
    output wire [31:0] write_byte,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read ADDR" *) output wire [31:0] read_byte,
    output wire [3:0] write_lanes,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read WE" *) output wire [3:0] read_write_lanes,
    input wire reader_clk, input wire reader_reset, input wire reader_enable,
    input wire [31:0] reader_din, output wire [31:0] reader_dout,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read CLK" *)
    (* X_INTERFACE_MODE = "master" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME bram_read, MEM_SIZE 76800, MEM_WIDTH 32, MEM_ADDRESS_MODE BYTE_ADDRESS, MEM_ECC NONE, MASTER_TYPE BRAM_CTRL, READ_WRITE_MODE READ_WRITE, READ_LATENCY 1" *)
    output wire memory_clk,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read RST" *) output wire memory_reset,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read EN" *) output wire memory_enable,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read DIN" *) output wire [31:0] memory_din,
    (* X_INTERFACE_INFO = "xilinx.com:interface:bram:1.0 bram_read DOUT" *) input wire [31:0] memory_dout
);
    wire [14:0] w = {1'b0,write_word} + (write_bank ? 15'd9600 : 15'd0);
    wire [14:0] r = {1'b0,read_word} + (read_bank ? 15'd9600 : 15'd0);
    assign write_byte={15'b0,w,2'b00};
    assign read_byte={15'b0,r,2'b00};
    assign write_lanes={4{write_enable}};
    assign read_write_lanes={4{read_write_enable}};
    assign memory_clk=reader_clk;
    assign memory_reset=reader_reset;
    assign memory_enable=reader_enable;
    assign memory_din=reader_din;
    assign reader_dout=memory_dout;
endmodule
