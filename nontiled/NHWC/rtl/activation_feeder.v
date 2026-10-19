// Input SRAM ownership, row skew, read alignment, and activation delivery.
`timescale 1ns / 1ps
module activation_feeder #(
    parameter ROW_INDEX = 0, BIT_WIDTH = 8, ADDR_WIDTH = 8
) (
    input clk, clear, feed_active, stream_enable,
    input [ADDR_WIDTH+1:0] feed_in, clear_feed,
    output [ADDR_WIDTH+1:0] feed_out,
    input sram_we_ext,
    input [ADDR_WIDTH-1:0] sram_waddr_ext,
    input [BIT_WIDTH-1:0] sram_wdata_ext,
    output [BIT_WIDTH-1:0] activation_out
);
  // Bundle: {feed_en, padding_valid, address}. Row zero has no delay.
  generate
    if (ROW_INDEX == 0) begin : g_first
      assign feed_out = feed_in;
    end else begin : g_skew
      reg [ADDR_WIDTH+1:0] stage;
      always @(posedge clk) stage <= clear ? clear_feed : feed_in;
      assign feed_out = stage;
    end
  endgenerate

  wire [ADDR_WIDTH-1:0] sram_raddr = feed_out[ADDR_WIDTH-1:0];
  wire [BIT_WIDTH-1:0] sram_rdata;
  sram #(.DATA_WIDTH(BIT_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_sram (
      .clk(clk), .we(sram_we_ext), .waddr(sram_waddr_ext), .wdata(sram_wdata_ext),
      .raddr(sram_raddr), .rdata(sram_rdata)
  );
  reg rd_valid_q;
  always @(posedge clk) rd_valid_q <= feed_out[ADDR_WIDTH];
  assign activation_out = (feed_active && stream_enable && feed_out[ADDR_WIDTH+1] && rd_valid_q)
                          ? sram_rdata : {BIT_WIDTH{1'b0}};
endmodule
