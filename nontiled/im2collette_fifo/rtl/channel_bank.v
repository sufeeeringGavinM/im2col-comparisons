`timescale 1ns/1ps
module channel_bank #(parameter CHANNEL_INDEX=0,BIT_WIDTH=8,BUS_WORDS=8,
    ACC_WIDTH=32,ADDR_WIDTH=8,CFG_WIDTH=32,OUT_LATENCY=11,PACKET_WORDS=8,
    COUNT_WIDTH=$clog2(PACKET_WORDS+1),OFFSET_WIDTH=(BUS_WORDS>1?$clog2(BUS_WORDS):1)) (
    input clk,clear,producer_clear,feed_active,writeback_active,stream_enable,accumulate,advance,
    input fetch_word,capture_word,push_packet,pop_packet,
    input [ADDR_WIDTH-1:0] producer_addr,
    input [PACKET_WORDS-1:0] collect_mask,padding_valid,
    input [PACKET_WORDS-1:0][OFFSET_WIDTH-1:0] word_offset,
    input [COUNT_WIDTH-1:0] packet_count,consume_index,
    input [CFG_WIDTH-1:0] output_pixels,
    input sram_we_ext,
    input [ADDR_WIDTH-1:0] sram_waddr_ext,
    input [BUS_WORDS*BIT_WIDTH-1:0] sram_wdata_ext,
    input [ACC_WIDTH-1:0] result_in,
    output [ACC_WIDTH-1:0] observed_word,
    output [BIT_WIDTH-1:0] activation_out,
    output packet_ready,packet_space,
    output [COUNT_WIDTH-1:0] head_count
);
  wire [BUS_WORDS*BIT_WIDTH-1:0] sram_rdata_bus;
  wire [ACC_WIDTH-1:0] old_out,wb_data;
  wire [ADDR_WIDTH-1:0] wb_ptr,wb_ptr_next;
  wire wb_valid;
  assign observed_word=old_out;
  feed_lane #(.BIT_WIDTH(BIT_WIDTH),.BUS_WORDS(BUS_WORDS),.PACKET_WORDS(PACKET_WORDS)) u_feed_lane (
    .clk(clk),.clear(producer_clear),.capture_word(capture_word && feed_active),
    .push_packet(push_packet && feed_active),.pop_packet(pop_packet && feed_active),
    .sram_rdata_bus(sram_rdata_bus),.collect_mask(collect_mask),.padding_valid(padding_valid),
    .word_offset(word_offset),.packet_count(packet_count),.consume_index(consume_index),
    .packet_ready(packet_ready),.packet_space(packet_space),.head_count(head_count),
    .activation_out(activation_out));
  output_accumulator #(.CHANNEL_INDEX(CHANNEL_INDEX),.ACC_WIDTH(ACC_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),.WB_CNT_WIDTH(CFG_WIDTH+1),.OUT_LATENCY(OUT_LATENCY),
    .CFG_WIDTH(CFG_WIDTH)) u_output (
    .clk(clk),.clear(clear),.writeback_active(writeback_active),.stream_enable(stream_enable),
    .advance(advance),.accumulate(accumulate),.output_pixels(output_pixels),.old_out(old_out),
    .result_in(result_in),.wb_valid(wb_valid),.wb_ptr(wb_ptr),.wb_ptr_next(wb_ptr_next),.wb_data(wb_data));
  row_sram #(.DATA_WIDTH(BUS_WORDS*BIT_WIDTH),.DEPTH(32),.ADDR_WIDTH(ADDR_WIDTH)) u_input_sram (
    .clk(clk),.we(sram_we_ext),.waddr(sram_waddr_ext),.wdata(sram_wdata_ext),
    .read_enable(fetch_word && feed_active),.raddr(producer_addr),.rdata(sram_rdata_bus));
  row_sram #(.DATA_WIDTH(ACC_WIDTH),.ADDR_WIDTH(ADDR_WIDTH)) u_output_sram (
    .clk(clk),.we(wb_valid),.waddr(wb_ptr),.wdata(wb_data),
    .read_enable(1'b1),.raddr(wb_ptr_next),.rdata(old_out));
endmodule
