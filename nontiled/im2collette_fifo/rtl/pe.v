`timescale 1ns / 1ps

module pe #(
    parameter BIT_WIDTH = 8,
    parameter ACC_WIDTH = 32
) (
    input  wire                         clk,
    input wire advance,
    input  wire                         nrst,
    input  wire                         clear_acc,
    input  wire                         load_weights,
    input  wire                         weight_write_buffer,
    input  wire                         weight_read_buffer,
    input  wire signed [ACC_WIDTH-1:0]  acc_in,
    input  wire signed [BIT_WIDTH-1:0]  data_in,
    input  wire signed [BIT_WIDTH-1:0]  weight_in,
    output reg  signed [ACC_WIDTH-1:0]  acc_out,
    output reg  signed [BIT_WIDTH-1:0]  data_out,
    output reg  signed [BIT_WIDTH-1:0]  weight_out
);

    reg signed [BIT_WIDTH-1:0] stored_weight [0:1];
    wire signed [ACC_WIDTH-1:0] product =
        $signed(data_in) * $signed(stored_weight[weight_read_buffer]);

    always @(posedge clk) begin
        if (!nrst) begin
            acc_out          <= {ACC_WIDTH{1'b0}};
            data_out         <= {BIT_WIDTH{1'b0}};
            weight_out       <= {BIT_WIDTH{1'b0}};
            stored_weight[0] <= {BIT_WIDTH{1'b0}};
            stored_weight[1] <= {BIT_WIDTH{1'b0}};
        end else begin
            // Shift weight downward through column
            if (load_weights) begin
                stored_weight[weight_write_buffer] <= weight_in;
                weight_out <= weight_in;
            end

            // Accumulate and pass activation horizontally
            if (clear_acc) begin
                acc_out  <= {ACC_WIDTH{1'b0}};
                data_out <= {BIT_WIDTH{1'b0}};
            end else if (advance) begin
                data_out <= data_in;
                acc_out  <= acc_in + product;
            end
        end
    end

endmodule