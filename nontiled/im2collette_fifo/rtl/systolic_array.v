`timescale 1ns / 1ps

// Parameterized 10x10 systolic array grid with stationary weight buffers and registered outputs
module systolic_array #(
    parameter integer ARRAY_SIZE = 10,
    parameter integer BIT_WIDTH  = 8,
    parameter integer ACC_WIDTH  = 32,
    parameter integer CFG_WIDTH  = 32
) (
    input  wire                                           clk,
    input  wire                                           nrst,
    input  wire                                           clear_pass,
    input  wire                                           load_weights,
    input  wire                                           weight_write_buffer,
    input  wire                                           weight_read_buffer,
    input  wire [CFG_WIDTH-1:0]                           cfg_C,
    input  wire [CFG_WIDTH-1:0]                           cfg_K,
    input  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0]          activation_rows,
    input  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0]          weight_row_in,
    output reg  [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]          acc_col_out
);

    wire [BIT_WIDTH-1:0] mac_data_in  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [BIT_WIDTH-1:0] mac_data_out [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [BIT_WIDTH-1:0] mac_wt_in    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [BIT_WIDTH-1:0] mac_wt_out   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [ACC_WIDTH-1:0] mac_acc_in   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire [ACC_WIDTH-1:0] mac_acc_out  [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    genvar c, k;
    generate
        for (c = 0; c < ARRAY_SIZE; c = c + 1) begin : g_c
            for (k = 0; k < ARRAY_SIZE; k = k + 1) begin : g_k

                // Horizontal data routing
                if (k == 0) begin : g_first_col
                    assign mac_data_in[c][k] = activation_rows[c];
                end else begin : g_next_col
                    assign mac_data_in[c][k] = mac_data_out[c][k-1];
                end

                // Vertical weight loading & sum accumulation
                if (c == 0) begin : g_first_row
                    assign mac_acc_in[c][k] = {ACC_WIDTH{1'b0}};
                    assign mac_wt_in[c][k]  = (load_weights && (k < cfg_K)) ? weight_row_in[k] : {BIT_WIDTH{1'b0}};
                end else begin : g_next_row
                    assign mac_acc_in[c][k] = mac_acc_out[c-1][k];
                    assign mac_wt_in[c][k]  = (load_weights && (c < cfg_C) && (k < cfg_K)) ? mac_wt_out[c-1][k] : {BIT_WIDTH{1'b0}};
                end

                pe #(
                    .BIT_WIDTH(BIT_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) u_pe (
                    .clk(clk),
                    .nrst(nrst),
                    .clear_acc(clear_pass),
                    .load_weights(load_weights),
                    .weight_write_buffer(weight_write_buffer),
                    .weight_read_buffer(weight_read_buffer),
                    .data_in(mac_data_in[c][k]),
                    .weight_in(mac_wt_in[c][k]),
                    .acc_in(mac_acc_in[c][k]),
                    .data_out(mac_data_out[c][k]),
                    .weight_out(mac_wt_out[c][k]),
                    .acc_out(mac_acc_out[c][k])
                );

            end
        end
    endgenerate

    generate
        for (k = 0; k < ARRAY_SIZE; k = k + 1) begin : g_output
            always @(posedge clk) begin
                if (!nrst) begin
                    acc_col_out[k] <= {ACC_WIDTH{1'b0}};
                end else begin
                    acc_col_out[k] <= mac_acc_out[ARRAY_SIZE-1][k];
                end
            end
        end
    endgenerate

endmodule