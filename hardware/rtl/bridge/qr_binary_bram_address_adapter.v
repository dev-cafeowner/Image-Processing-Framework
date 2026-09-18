`timescale 1ns/1ps
// Binary image producers/consumers count 32-bit words (0..9599).
// The configured BMG BRAM_Controller ports use 32-bit BYTE addresses.
// Keep this conversion at the memory boundary, not inside the QR algorithm.
module qr_binary_bram_address_adapter (
    input wire [13:0] write_word,
    input wire [13:0] read_word,
    input wire write_enable,
    input wire read_write_enable,
    output wire [31:0] write_byte,
    output wire [31:0] read_byte,
    output wire [3:0] write_lanes,
    output wire [3:0] read_write_lanes
);
    assign write_byte = {16'b0, write_word, 2'b00};
    assign read_byte = {16'b0, read_word, 2'b00};
    assign write_lanes = {4{write_enable}};
    assign read_write_lanes = {4{read_write_enable}};
endmodule
