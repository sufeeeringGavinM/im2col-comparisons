`timescale 1ns/1ps
// One enabled synchronous read and one preload write per bank per clock.
module input_bank #(parameter BIT_WIDTH=8, ADDR_WIDTH=8) (
    input clk, read_enable, we,
    input [ADDR_WIDTH-1:0] raddr, waddr,
    input [BIT_WIDTH-1:0] wdata,
    output reg [BIT_WIDTH-1:0] rdata
);
  reg [BIT_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];
  always @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    if (read_enable) rdata <= mem[raddr];
  end
endmodule
