`timescale 1ns/1ps
// Shared producer metadata; per-channel retained words and packet queues.
module MMU #(parameter ARRAY_SIZE=10,BIT_WIDTH=8,BUS_WORDS=8,ACC_WIDTH=32,
    ADDR_WIDTH=8,CFG_WIDTH=32,PACKET_WORDS=8,
    COUNT_WIDTH=$clog2(PACKET_WORDS+1),OFFSET_WIDTH=(BUS_WORDS>1?$clog2(BUS_WORDS):1)) (
    input clk,nrst,clear_pass,producer_enable,running,load_weights,
    input weight_write_buffer,weight_read_buffer,accumulate,
    input [CFG_WIDTH-1:0] cfg_N,cfg_C,cfg_K,cfg_H,cfg_W,cfg_P,cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,cfg_dilation_i,cfg_dilation_j,r,s,
    input [ARRAY_SIZE-1:0] sram_we_ext,
    input [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] sram_waddr_ext,
    input [ARRAY_SIZE-1:0][BUS_WORDS*BIT_WIDTH-1:0] sram_wdata_ext,
    input [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] weight_row_in,
    output [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] observed_words,acc_col_out,
    output advance
);
  wire clear=!nrst || clear_pass;
  wire producer_clear=!nrst || !producer_enable;
  wire [CFG_WIDTH-1:0] output_pixels=cfg_N*cfg_P*cfg_Q;
  reg [CFG_WIDTH-1:0] producer_position;
  reg [PACKET_WORDS-1:0] filled;
  reg cache_valid,waiting;
  reg [ADDR_WIDTH-1:0] cache_addr,pending_addr;
  wire [COUNT_WIDTH-1:0] packet_count=COUNT_WIDTH'(
    output_pixels-producer_position<PACKET_WORDS ? output_pixels-producer_position : PACKET_WORDS);
  wire [PACKET_WORDS-1:0] padding_valid;
  wire [PACKET_WORDS-1:0][ADDR_WIDTH-1:0] word_addr;
  wire [PACKET_WORDS-1:0][OFFSET_WIDTH-1:0] word_offset;
  im2col_addr_gen #(.CFG_WIDTH(CFG_WIDTH),.ADDR_WIDTH(ADDR_WIDTH),.BUS_WORDS(BUS_WORDS),
    .PACKET_WORDS(PACKET_WORDS)) u_agen (
    .cfg_N(cfg_N),.cfg_H(cfg_H),.cfg_W(cfg_W),.cfg_Q(cfg_Q),
    .cfg_pad_i(cfg_pad_i),.cfg_pad_j(cfg_pad_j),.cfg_stride_i(cfg_stride_i),.cfg_stride_j(cfg_stride_j),
    .cfg_dilation_i(cfg_dilation_i),.cfg_dilation_j(cfg_dilation_j),.r(r),.s(s),.position(producer_position),
    .valid(padding_valid),.word_addr(word_addr),.word_offset(word_offset));
  wire [ARRAY_SIZE-1:0] packet_ready,packet_space;
  wire [ARRAY_SIZE-1:0][COUNT_WIDTH-1:0] head_count;
  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] scalar_values,activation_rows;
  reg all_ready,all_space,complete,have_request;
  reg [PACKET_WORDS-1:0] collect_mask;
  reg [ADDR_WIDTH-1:0] request_addr;
  integer j,lane;
  always @* begin
    all_ready=1;all_space=1;
    for(lane=0;lane<ARRAY_SIZE;lane=lane+1)
      if(lane<cfg_C) begin all_ready=all_ready && packet_ready[lane];all_space=all_space && packet_space[lane];end
    complete=1;have_request=0;collect_mask=0;request_addr=0;
    for(j=0;j<PACKET_WORDS;j=j+1)
      if(j<packet_count && !filled[j]) begin
        complete=0;
        if(!padding_valid[j] || (cache_valid && word_addr[j]==cache_addr)) collect_mask[j]=1;
        else if(!have_request) begin have_request=1;request_addr=word_addr[j];end
      end
    if(producer_clear || producer_position>=output_pixels || waiting) collect_mask=0;
  end
  wire fetch_word=!producer_clear && producer_position<output_pixels && !waiting
    && !complete && collect_mask==0 && have_request;
  wire capture_word=!producer_clear && waiting;
  wire push_packet=!producer_clear && producer_position<output_pixels && complete && all_space;
  always @(posedge clk) begin
    if(producer_clear) begin producer_position<=0;filled<=0;cache_valid<=0;waiting<=0;cache_addr<=0;pending_addr<=0;end
    else begin
      if(fetch_word) begin waiting<=1;pending_addr<=request_addr;end
      if(waiting) begin waiting<=0;cache_valid<=1;cache_addr<=pending_addr;end
      filled<=filled|collect_mask;
      if(push_packet) begin producer_position<=producer_position+packet_count;filled<=0;end
    end
  end
  reg [CFG_WIDTH:0] step_count;
  reg [COUNT_WIDTH-1:0] consume_index;
  wire [CFG_WIDTH:0] pass_steps=(CFG_WIDTH+1)'(output_pixels)+2*ARRAY_SIZE;
  assign advance=running && step_count<pass_steps && (step_count>=output_pixels || all_ready);
  wire consume=advance && step_count<output_pixels;
  wire pop_packet=consume && consume_index==head_count[0]-1'b1;
  always @(posedge clk) begin
    if(clear) begin step_count<=0;consume_index<=0;end
    else if(advance) begin
      step_count<=step_count+1'b1;
      if(consume) begin
        if(pop_packet) consume_index<=0;
        else consume_index<=consume_index+1'b1;
      end
    end
  end
  genvar c;
  generate for(c=0;c<ARRAY_SIZE;c=c+1) begin : g_c_lanes
    channel_bank #(.CHANNEL_INDEX(c),.BIT_WIDTH(BIT_WIDTH),.BUS_WORDS(BUS_WORDS),
      .ACC_WIDTH(ACC_WIDTH),.ADDR_WIDTH(ADDR_WIDTH),.CFG_WIDTH(CFG_WIDTH),
      .OUT_LATENCY(ARRAY_SIZE+1),.PACKET_WORDS(PACKET_WORDS)) u_bank (
      .clk(clk),.clear(clear),.producer_clear(producer_clear),.feed_active(c<cfg_C),
      .writeback_active(c<cfg_K),.stream_enable(running),.accumulate(accumulate),.advance(advance),
      .fetch_word(fetch_word),.capture_word(capture_word),.push_packet(push_packet),.pop_packet(pop_packet),
      .producer_addr(request_addr),.collect_mask(collect_mask),.padding_valid(padding_valid),
      .word_offset(word_offset),.packet_count(packet_count),.consume_index(consume_index),
      .output_pixels(output_pixels),.sram_we_ext(sram_we_ext[c]),.sram_waddr_ext(sram_waddr_ext[c]),
      .sram_wdata_ext(sram_wdata_ext[c]),.result_in(acc_col_out[c]),.observed_word(observed_words[c]),
      .activation_out(scalar_values[c]),.packet_ready(packet_ready[c]),.packet_space(packet_space[c]),.head_count(head_count[c]));
    if(c==0) assign activation_rows[c]=consume && c<cfg_C ? scalar_values[c] : 0;
    else begin : g_skew
      reg [BIT_WIDTH-1:0] delay_data [0:c-1];
      integer d;
      always @(posedge clk) begin
        if(clear) for(d=0;d<c;d=d+1) delay_data[d]<=0;
        else if(advance) begin
          delay_data[0]<=consume && c<cfg_C ? scalar_values[c] : 0;
          for(d=1;d<c;d=d+1) delay_data[d]<=delay_data[d-1];
        end
      end
      assign activation_rows[c]=delay_data[c-1];
    end
  end endgenerate
  systolic_array #(.ARRAY_SIZE(ARRAY_SIZE),.BIT_WIDTH(BIT_WIDTH),.ACC_WIDTH(ACC_WIDTH),.CFG_WIDTH(CFG_WIDTH)) u_array (
    .clk(clk),.nrst(nrst),.clear_pass(clear_pass),.load_weights(load_weights),.advance(advance),
    .weight_write_buffer(weight_write_buffer),.weight_read_buffer(weight_read_buffer),.cfg_C(cfg_C),.cfg_K(cfg_K),
    .activation_rows(activation_rows),.weight_row_in(weight_row_in),.acc_col_out(acc_col_out));
endmodule
