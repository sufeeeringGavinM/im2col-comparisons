// Square systolic array for one convolution tap, with skewed input reads and SRAM writeback.

`timescale 1ns / 1ps

module conv_datapath #(
    parameter ARRAY_SIZE = 10,
    parameter BIT_WIDTH  = 8,
    parameter ACC_WIDTH  = 32,
    parameter INPUT_ADDR_WIDTH = 8,
    parameter OUTPUT_ADDR_WIDTH = 8,
    parameter CFG_WIDTH = 32
) (
    input [CFG_WIDTH-1:0] cfg_N,
    input [CFG_WIDTH-1:0] cfg_C,
    input [CFG_WIDTH-1:0] cfg_K,
    input [CFG_WIDTH-1:0] cfg_H,
    input [CFG_WIDTH-1:0] cfg_W,
    input [CFG_WIDTH-1:0] cfg_P,
    input [CFG_WIDTH-1:0] cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i,
    input [CFG_WIDTH-1:0] cfg_pad_j,
    input [CFG_WIDTH-1:0] cfg_stride_i,
    input [CFG_WIDTH-1:0] cfg_stride_j,
    input [CFG_WIDTH-1:0] cfg_dilation_i,
    input [CFG_WIDTH-1:0] cfg_dilation_j,
    input clk,
    input nrst,
    input clear_pass,
    input load_weights,
    input weight_write_buffer,
    input weight_read_buffer,

    input accumulate,
    input output_read_enable,
    input [OUTPUT_ADDR_WIDTH-1:0] output_read_addr,
    output [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] output_read_data,

    // Kernel offset of the current pass. Hold stable for the whole pass (including its initial loading phase).
    input [CFG_WIDTH-1:0] r,
    input [CFG_WIDTH-1:0] s,

    input [ARRAY_SIZE-1:0]                 sram_we_ext,
    input [ARRAY_SIZE-1:0][INPUT_ADDR_WIDTH-1:0] sram_waddr_ext,
    input [ARRAY_SIZE-1:0][ BIT_WIDTH-1:0] sram_wdata_ext,

    input [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] weight_row_in,

    output wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] acc_col_out
);

  localparam OUT_LATENCY = ARRAY_SIZE + 1;
  localparam WB_CNT_WIDTH = CFG_WIDTH + 1;

  wire [CFG_WIDTH-1:0] output_pixels = cfg_N * cfg_P * cfg_Q;

  wire clear = !nrst || clear_pass;  // Clear pixel, skew, and writeback state between tap passes.

  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] activation_rows;

  // Positions advance through images n at each spatial output coordinate (p,q).
  // The address presented to SRAM leads activation feeding by one cycle.
  reg  [CFG_WIDTH-1:0] position_cnt;
  wire [CFG_WIDTH-1:0] position_next = position_cnt + 1'b1;

  always @(posedge clk) begin
    if (clear) position_cnt <= 0;
    else position_cnt <= position_next;
  end

  wire [CFG_WIDTH-1:0] read_position = clear ? {CFG_WIDTH{1'b0}} : position_next;
  wire [INPUT_ADDR_WIDTH-1:0] agen_addr;
  wire                  agen_valid;

  im2col_addr_gen #(
      .CFG_WIDTH(CFG_WIDTH), .POSITION_WIDTH(CFG_WIDTH), .ADDR_WIDTH(INPUT_ADDR_WIDTH)
  ) u_agen (
      .cfg_N(cfg_N),
      .cfg_H(cfg_H),
      .cfg_W(cfg_W),
      .cfg_Q(cfg_Q),
      .cfg_pad_i(cfg_pad_i),
      .cfg_pad_j(cfg_pad_j),
      .cfg_stride_i(cfg_stride_i),
      .cfg_stride_j(cfg_stride_j),
      .cfg_dilation_i(cfg_dilation_i),
      .cfg_dilation_j(cfg_dilation_j),
      .position(read_position),
      .r(r), .s(s), .addr(agen_addr), .valid(agen_valid)
  );

  // Feeders form a shared skew chain for {feed_en, valid, addr}.
  localparam FW = INPUT_ADDR_WIDTH + 2;
  wire [FW-1:0] feed_in = {!clear && position_cnt < output_pixels, agen_valid, agen_addr};
  wire [ARRAY_SIZE:0][FW-1:0] feed_bus;
  assign feed_bus[0] = feed_in;

  genvar c, k;
  generate
    for (c = 0; c < ARRAY_SIZE; c = c + 1) begin : g_input
      activation_feeder #(
          .ROW_INDEX(c), .BIT_WIDTH(BIT_WIDTH), .ADDR_WIDTH(INPUT_ADDR_WIDTH)
      ) u_feeder (
          .clk(clk), .clear(clear), .feed_active(c < cfg_C), .stream_enable(!clear_pass),
          .feed_in(feed_bus[c]), .clear_feed(feed_in), .feed_out(feed_bus[c+1]),
          .sram_we_ext(sram_we_ext[c]), .sram_waddr_ext(sram_waddr_ext[c]),
          .sram_wdata_ext(sram_wdata_ext[c]), .activation_out(activation_rows[c])
      );
    end
    for (k = 0; k < ARRAY_SIZE; k = k + 1) begin : g_output
      output_accumulator #(
          .COL_INDEX(k), .ACC_WIDTH(ACC_WIDTH), .ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
          .WB_CNT_WIDTH(WB_CNT_WIDTH), .OUT_LATENCY(OUT_LATENCY), .CFG_WIDTH(CFG_WIDTH)
      ) u_accumulator (
          .clk(clk), .clear(clear), .writeback_active(k < cfg_K),
          .stream_enable(!clear_pass), .accumulate(accumulate),
          .output_pixels(output_pixels), .result_in(acc_col_out[k]),
          .read_enable_ext(output_read_enable && clear),
          .read_addr_ext(output_read_addr), .read_data_ext(output_read_data[k])
      );
    end
  endgenerate

  systolic_array #(
      .ARRAY_SIZE(ARRAY_SIZE), .BIT_WIDTH(BIT_WIDTH),
      .ACC_WIDTH(ACC_WIDTH), .CFG_WIDTH(CFG_WIDTH)
  ) u_array (
      .clk(clk), .nrst(nrst), .clear_pass(clear_pass),
      .load_weights(load_weights), .weight_write_buffer(weight_write_buffer),
      .weight_read_buffer(weight_read_buffer), .cfg_C(cfg_C), .cfg_K(cfg_K),
      .activation_rows(activation_rows), .weight_row_in(weight_row_in),
      .acc_col_out(acc_col_out)
  );
endmodule
