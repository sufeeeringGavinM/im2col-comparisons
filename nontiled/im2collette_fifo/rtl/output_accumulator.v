`timescale 1ns / 1ps

// Address and data generation for per-tap output writeback and read-modify-write accumulation
module output_accumulator #(
    parameter integer CHANNEL_INDEX = 0,
    parameter integer ACC_WIDTH     = 32,
    parameter integer ADDR_WIDTH    = 8,
    parameter integer WB_CNT_WIDTH  = 33,
    parameter integer OUT_LATENCY   = 11,
    parameter integer CFG_WIDTH     = 32
) (
    input  wire                     clk,
    input  wire                     clear,
    input  wire                     writeback_active,
    input  wire                     stream_enable,
    input  wire                     accumulate,
    input  wire [CFG_WIDTH-1:0]     output_pixels,
    input  wire [ACC_WIDTH-1:0]     old_out,
    input  wire [ACC_WIDTH-1:0]     result_in,
    output wire                     wb_valid,
    output reg  [ADDR_WIDTH-1:0]    wb_ptr,
    output wire [ADDR_WIDTH-1:0]    wb_ptr_next,
    output wire [ACC_WIDTH-1:0]     wb_data
);

    localparam integer WB_START_CYCLE = CHANNEL_INDEX + OUT_LATENCY;

    reg [WB_CNT_WIDTH-1:0] writeback_cnt;
    always @(posedge clk) begin
        if (clear) writeback_cnt <= {WB_CNT_WIDTH{1'b0}};
        else       writeback_cnt <= writeback_cnt + 1'b1;
    end

    assign wb_valid = writeback_active && stream_enable &&
                      (writeback_cnt >= WB_START_CYCLE) &&
                      (writeback_cnt - WB_START_CYCLE < output_pixels);

    always @(posedge clk) begin
        if (clear) wb_ptr <= {ADDR_WIDTH{1'b0}};
        else if (wb_valid) wb_ptr <= wb_ptr + 1'b1;
    end

    assign wb_ptr_next = clear ? {ADDR_WIDTH{1'b0}} : (wb_valid ? wb_ptr + 1'b1 : wb_ptr);
    assign wb_data = accumulate ? (old_out + result_in) : result_in;

endmodule