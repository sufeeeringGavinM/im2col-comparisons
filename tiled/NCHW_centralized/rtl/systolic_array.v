// PE grid, stationary weight buffers, and registered column outputs.
`timescale 1ns / 1ps
module systolic_array #(
    parameter ARRAY_SIZE = 10, BIT_WIDTH = 8, ACC_WIDTH = 32, CFG_WIDTH = 32
) (
    input clk, nrst, clear_pass, load_weights, advance,
    input weight_write_buffer, weight_read_buffer,
    input [CFG_WIDTH-1:0] cfg_C, cfg_K,
    input [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] activation_rows, weight_row_in,
    output reg [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] acc_col_out
);
  // Each PE connection is a separate word-sized net.
  wire [BIT_WIDTH-1:0] pe_data_in [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1], pe_data_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];     // Buses between columns
  wire [BIT_WIDTH-1:0] pe_weight_in [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1], pe_weight_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1]; // Buses between rows
  wire [ACC_WIDTH-1:0] pe_acc_in [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1], pe_acc_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];       // Buses between rows

  genvar c, k;
  generate
    for (c = 0; c < ARRAY_SIZE; c = c + 1) begin : g_c
      for (k = 0; k < ARRAY_SIZE; k = k + 1) begin : g_k

        // Column k=0 receives the SRAM activation; later columns receive it from the left PE.
        if (k == 0) begin
          assign pe_data_in[c][k] = activation_rows[c];
        end else begin
          assign pe_data_in[c][k] = pe_data_out[c][k-1];
        end

        // Reduction row c=0 starts the sum; later rows add the preceding PE result.
        if (c == 0) begin
          assign pe_acc_in[c][k]    = 0;
          assign pe_weight_in[c][k] = (load_weights && k < cfg_K) ? weight_row_in[k] : 0;
        end else begin
          assign pe_acc_in[c][k]    = pe_acc_out[c-1][k];
          assign pe_weight_in[c][k] = (load_weights && c < cfg_C && k < cfg_K) ? pe_weight_out[c-1][k] : 0;
        end

        PE #(
            .BIT_WIDTH(BIT_WIDTH),
            .ACC_WIDTH(ACC_WIDTH)
        ) u_pe (
            .nrst        (nrst),
            .clk         (clk),
            .clear_acc(clear_pass),
            .advance(advance),
            .load_weights(load_weights),
            .weight_write_buffer(weight_write_buffer),
            .weight_read_buffer(weight_read_buffer),
            .data_in     (pe_data_in[c][k]),
            .weight_in   (pe_weight_in[c][k]),
            .acc_in      (pe_acc_in[c][k]),
            .data_out    (pe_data_out[c][k]),
            .weight_out  (pe_weight_out[c][k]),
            .acc_out     (pe_acc_out[c][k])
        );

      end
    end
  endgenerate

  generate
    for (k = 0; k < ARRAY_SIZE; k = k + 1) begin : g_output
      always @(posedge clk) begin
        if (!nrst) acc_col_out[k] <= 0;
        else if (advance) acc_col_out[k] <= pe_acc_out[ARRAY_SIZE-1][k];
      end
    end
  endgenerate

endmodule
