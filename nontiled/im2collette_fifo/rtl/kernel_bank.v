`timescale 1ns / 1ps

// One output channel's kernel memory with synchronous reads (256 bytes per bank)
module kernel_bank #(
    parameter integer BIT_WIDTH  = 8,
    parameter integer ADDR_WIDTH = 8
) (
    input  wire                  clk,
    input  wire                  we,
    input  wire                  read_enable,
    input  wire                  read_active,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [ADDR_WIDTH-1:0] raddr,
    input  wire [BIT_WIDTH-1:0]  wdata,
    output reg  [BIT_WIDTH-1:0]  rdata
);

    localparam integer DEPTH = 1 << ADDR_WIDTH;
    reg [BIT_WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            mem[waddr] <= wdata;
        end
        if (read_enable) begin
            rdata <= read_active ? mem[raddr] : {BIT_WIDTH{1'b0}};
        end
    end

endmodule