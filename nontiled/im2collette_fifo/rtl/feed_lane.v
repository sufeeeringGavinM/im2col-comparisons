`timescale 1ns/1ps
// One channel: retain a synchronous SRAM word, collect a packet, then serialize.
module feed_lane #(parameter BIT_WIDTH=8,BUS_WORDS=8,PACKET_WORDS=8,FIFO_DEPTH=8,
    OFFSET_WIDTH=(BUS_WORDS>1?$clog2(BUS_WORDS):1),
    COUNT_WIDTH=$clog2(PACKET_WORDS+1)) (
    input clk,clear,capture_word,push_packet,pop_packet,
    input [BUS_WORDS*BIT_WIDTH-1:0] sram_rdata_bus,
    input [PACKET_WORDS-1:0] collect_mask,padding_valid,
    input [PACKET_WORDS-1:0][OFFSET_WIDTH-1:0] word_offset,
    input [COUNT_WIDTH-1:0] packet_count,consume_index,
    output packet_ready,packet_space,
    output [COUNT_WIDTH-1:0] head_count,
    output [BIT_WIDTH-1:0] activation_out
);
  localparam DATA_BITS=PACKET_WORDS*BIT_WIDTH;
  reg [BUS_WORDS*BIT_WIDTH-1:0] retained_word;
  reg [PACKET_WORDS-1:0][BIT_WIDTH-1:0] packet_values;
  wire [DATA_BITS+COUNT_WIDTH-1:0] fifo_dout;
  wire fifo_full,fifo_empty;
  integer j;
  always @(posedge clk) begin
    if(clear) begin retained_word<=0;packet_values<=0;end
    else begin
      if(capture_word) retained_word<=sram_rdata_bus;
      for(j=0;j<PACKET_WORDS;j=j+1)
        if(collect_mask[j]) packet_values[j]<=padding_valid[j]
          ? retained_word[word_offset[j]*BIT_WIDTH+:BIT_WIDTH] : 0;
    end
  end
  sync_fifo #(.DATA_WIDTH(DATA_BITS+COUNT_WIDTH),.DEPTH(FIFO_DEPTH),
      .ADDR_WIDTH((FIFO_DEPTH>1?$clog2(FIFO_DEPTH):1))) u_lowered_fifo (
    .clk(clk),.rst(clear),.wr_en(push_packet),.din({packet_count,packet_values}),
    .rd_en(pop_packet),.dout(fifo_dout),.full(fifo_full),.empty(fifo_empty),.count());
  assign packet_ready=!fifo_empty;
  assign packet_space=!fifo_full;
  assign head_count=fifo_dout[DATA_BITS+:COUNT_WIDTH];
  assign activation_out=packet_ready ? fifo_dout[consume_index*BIT_WIDTH+:BIT_WIDTH] : 0;
endmodule
