`timescale 1ns/1ps
// Requested output positions for one packet, in the inherited (p,q,n) order.
module im2col_addr_gen #(parameter CFG_WIDTH=32, ADDR_WIDTH=8, BUS_WORDS=8,
    PACKET_WORDS=8, OFFSET_WIDTH=(BUS_WORDS>1?$clog2(BUS_WORDS):1)) (
    input [CFG_WIDTH-1:0] cfg_N,cfg_H,cfg_W,cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i,cfg_pad_j,cfg_stride_i,cfg_stride_j,
    input [CFG_WIDTH-1:0] cfg_dilation_i,cfg_dilation_j,r,s,position,
    output [PACKET_WORDS-1:0] valid,
    output [PACKET_WORDS-1:0][ADDR_WIDTH-1:0] word_addr,
    output [PACKET_WORDS-1:0][OFFSET_WIDTH-1:0] word_offset
);
  genvar j;
  generate for(j=0;j<PACKET_WORDS;j=j+1) begin : g_position
    wire [CFG_WIDTH-1:0] pos=position+j;
    wire [CFG_WIDTH-1:0] n=cfg_N!=0 ? pos%cfg_N : 0;
    wire [CFG_WIDTH-1:0] pix=cfg_N!=0 ? pos/cfg_N : 0;
    wire [CFG_WIDTH-1:0] p=cfg_Q!=0 ? pix/cfg_Q : 0;
    wire [CFG_WIDTH-1:0] q=cfg_Q!=0 ? pix%cfg_Q : 0;
    wire signed [63:0] h=$signed({1'b0,p})*$signed({1'b0,cfg_stride_i})
      +$signed({1'b0,r})*$signed({1'b0,cfg_dilation_i})-$signed({1'b0,cfg_pad_i});
    wire signed [63:0] x=$signed({1'b0,q})*$signed({1'b0,cfg_stride_j})
      +$signed({1'b0,s})*$signed({1'b0,cfg_dilation_j})-$signed({1'b0,cfg_pad_j});
    assign valid[j]=h>=0 && h<cfg_H && x>=0 && x<cfg_W;
    wire [63:0] linear_byte=valid[j] ? (h*cfg_W+x)*cfg_N+n : 0;
    assign word_addr[j]=ADDR_WIDTH'(linear_byte/BUS_WORDS);
    assign word_offset[j]=OFFSET_WIDTH'(linear_byte%BUS_WORDS);
  end endgenerate
endmodule
