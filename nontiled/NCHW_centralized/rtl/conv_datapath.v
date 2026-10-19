`timescale 1ns/1ps
module conv_datapath #(parameter ARRAY_SIZE=4, BIT_WIDTH=8, ACC_WIDTH=32,
    INPUT_ADDR_WIDTH=8, OUTPUT_ADDR_WIDTH=8, CFG_WIDTH=32) (
    input clk, nrst, clear_pass, load_weights, weight_write_buffer, weight_read_buffer, accumulate,
    input [CFG_WIDTH-1:0] cfg_N, cfg_C, cfg_K, cfg_H, cfg_W, cfg_R, cfg_S, cfg_P, cfg_Q,
    input [CFG_WIDTH-1:0] cfg_pad_i, cfg_pad_j, cfg_stride_i, cfg_stride_j, cfg_dilation_i, cfg_dilation_j,
    input [CFG_WIDTH-1:0] group_base,
    input [ARRAY_SIZE-1:0] sram_we_ext,
    input [ARRAY_SIZE-1:0][INPUT_ADDR_WIDTH-1:0] sram_waddr_ext,
    input [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] sram_wdata_ext, weight_row_in,
    output [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] observed_words,
    output [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] acc_col_out,
    output advance, conflict_retry, pass_done
);
  localparam BANK_WIDTH=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1);
  wire clear = !nrst || clear_pass;
  wire [CFG_WIDTH-1:0] output_pixels = cfg_N*cfg_P*cfg_Q;
  wire [CFG_WIDTH-1:0] remaining_terms = cfg_C*cfg_R*cfg_S-group_base;
  wire [CFG_WIDTH-1:0] active_rows = remaining_terms < ARRAY_SIZE ? remaining_terms : ARRAY_SIZE;
  wire [CFG_WIDTH-1:0] issue_position;
  wire [ARRAY_SIZE-1:0] lane_valid;
  wire [ARRAY_SIZE-1:0][BANK_WIDTH-1:0] lane_bank;
  wire [ARRAY_SIZE-1:0][INPUT_ADDR_WIDTH-1:0] lane_addr;
  im2col_addr_gen #(.ARRAY_SIZE(ARRAY_SIZE),.CFG_WIDTH(CFG_WIDTH),.ADDR_WIDTH(INPUT_ADDR_WIDTH)) u_agen (
    .N(cfg_N),.C(cfg_C),.H(cfg_H),.W(cfg_W),.R(cfg_R),.S(cfg_S),.Q(cfg_Q),
    .pad_i(cfg_pad_i),.pad_j(cfg_pad_j),.stride_i(cfg_stride_i),.stride_j(cfg_stride_j),
    .dilation_i(cfg_dilation_i),.dilation_j(cfg_dilation_j),
    .position(issue_position),.group_base(group_base),.valid(lane_valid),.bank(lane_bank),.addr(lane_addr));
  wire vector_ready;
  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] vector_data;
  reg [CFG_WIDTH:0] step_count;
  wire [CFG_WIDTH:0] pass_steps = (CFG_WIDTH+1)'(output_pixels)+2*ARRAY_SIZE;
  assign advance = !clear && step_count < pass_steps && (step_count>=output_pixels || vector_ready);
  wire consume = advance && step_count<output_pixels;
  assign pass_done = advance && step_count==pass_steps-1;
  wire [ARRAY_SIZE-1:0] bank_read_enable;
  banked_input #(.ARRAY_SIZE(ARRAY_SIZE),.BIT_WIDTH(BIT_WIDTH),.ADDR_WIDTH(INPUT_ADDR_WIDTH),.CFG_WIDTH(CFG_WIDTH)) u_input (
    .clk(clk),.clear(clear),.running(!clear),.output_pixels(output_pixels),.issue_position(issue_position),
    .lane_valid(lane_valid),.lane_bank(lane_bank),.lane_addr(lane_addr),.consume(consume),
    .vector_ready(vector_ready),.vector_data(vector_data),.we_ext(sram_we_ext),
    .waddr_ext(sram_waddr_ext),.wdata_ext(sram_wdata_ext),
    .conflict_retry(conflict_retry),.bank_read_enable(bank_read_enable));
  always @(posedge clk) begin
    if(clear) step_count<=0;
    else if(advance) step_count<=step_count+1'b1;
  end
  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] activation_rows;
  genvar row, col;
  generate for(row=0; row<ARRAY_SIZE; row=row+1) begin : g_skew
    if(row==0) assign activation_rows[row] = consume ? vector_data[row] : 0;
    else begin : g_delay
      reg [BIT_WIDTH-1:0] delay_data [0:row-1];
      integer d;
      always @(posedge clk) begin
        if(clear) for(d=0; d<row; d=d+1) delay_data[d]<=0;
        else if(advance) begin
          delay_data[0] <= consume ? vector_data[row] : 0;
          for(d=1; d<row; d=d+1) delay_data[d]<=delay_data[d-1];
        end
      end
      assign activation_rows[row]=delay_data[row-1];
    end
  end endgenerate
  generate for(col=0; col<ARRAY_SIZE; col=col+1) begin : g_output
    output_accumulator #(.COL_INDEX(col),.ACC_WIDTH(ACC_WIDTH),.ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
      .WB_CNT_WIDTH(CFG_WIDTH+1),.OUT_LATENCY(ARRAY_SIZE+1),.CFG_WIDTH(CFG_WIDTH)) u_accumulator (
      .clk(clk),.clear(clear),.writeback_active(col<cfg_K),.stream_enable(!clear_pass),
      .accumulate(accumulate),.advance(advance),.output_pixels(output_pixels),.result_in(acc_col_out[col]), .observed_word(observed_words[col]));
  end endgenerate
  systolic_array #(.ARRAY_SIZE(ARRAY_SIZE),.BIT_WIDTH(BIT_WIDTH),.ACC_WIDTH(ACC_WIDTH),.CFG_WIDTH(CFG_WIDTH)) u_array (
    .clk(clk),.nrst(nrst),.clear_pass(clear_pass),.load_weights(load_weights),.advance(advance),
    .weight_write_buffer(weight_write_buffer),.weight_read_buffer(weight_read_buffer),
    .cfg_C(active_rows),.cfg_K(cfg_K),.activation_rows(activation_rows),.weight_row_in(weight_row_in),.acc_col_out(acc_col_out));
endmodule
