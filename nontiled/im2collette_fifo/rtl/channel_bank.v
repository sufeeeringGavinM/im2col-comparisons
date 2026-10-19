`timescale 1ns / 1ps

module channel_bank #(
    parameter integer CHANNEL_INDEX = 0,
    parameter integer BIT_WIDTH     = 8,
    parameter integer BUS_WORDS     = 8,
    parameter integer ACC_WIDTH     = 32,
    parameter integer ADDR_WIDTH    = 8,
    parameter integer CFG_WIDTH     = 32,
    parameter integer OUT_LATENCY   = 11
) (
    input  wire                             clk,
    input  wire                             clear,
    input  wire                             feed_active,
    input  wire                             writeback_active,
    input  wire                             stream_enable,
    input  wire                             accumulate,
    input  wire [CFG_WIDTH-1:0]             output_pixels,

    // Skew chain ports
    input  wire [ADDR_WIDTH+5:0]            feed_in,
    input  wire [ADDR_WIDTH+5:0]            clear_feed,
    output wire [ADDR_WIDTH+5:0]            feed_out,

    // External preload ports
    input  wire                             sram_we_ext,
    input  wire [ADDR_WIDTH-1:0]            sram_waddr_ext,
    input  wire [(BUS_WORDS*BIT_WIDTH)-1:0] sram_wdata_ext,

    // Systolic results and outputs
    input  wire [ACC_WIDTH-1:0]             result_in,
    output wire [ACC_WIDTH-1:0] observed_word,
    output wire [BIT_WIDTH-1:0]             activation_out
);

    wire [(BUS_WORDS*BIT_WIDTH)-1:0] sram_rdata_bus;
    wire [ADDR_WIDTH-1:0] sram_raddr;
    wire [ACC_WIDTH-1:0]  old_out, wb_data;
    assign observed_word = old_out;
    wire [ADDR_WIDTH-1:0] wb_ptr, wb_ptr_next;
    wire wb_valid;

    feed_lane #(
        .CHANNEL_INDEX(CHANNEL_INDEX),
        .BIT_WIDTH(BIT_WIDTH),
        .BUS_WORDS(BUS_WORDS),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_feed_lane (
        .clk(clk),
        .clear(clear),
        .feed_active(feed_active),
        .stream_enable(stream_enable),
        .feed_in(feed_in),
        .clear_feed(clear_feed),
        .feed_out(feed_out),
        .sram_raddr(sram_raddr),
        .sram_rdata_bus(sram_rdata_bus),
        .activation_out(activation_out)
    );

    output_accumulator #(
        .CHANNEL_INDEX(CHANNEL_INDEX),
        .ACC_WIDTH(ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .WB_CNT_WIDTH(CFG_WIDTH+1),
        .OUT_LATENCY(OUT_LATENCY),
        .CFG_WIDTH(CFG_WIDTH)
    ) u_output (
        .clk(clk),
        .clear(clear),
        .writeback_active(writeback_active),
        .stream_enable(stream_enable),
        .accumulate(accumulate),
        .output_pixels(output_pixels),
        .old_out(old_out),
        .result_in(result_in),
        .wb_valid(wb_valid),
        .wb_ptr(wb_ptr),
        .wb_ptr_next(wb_ptr_next),
        .wb_data(wb_data)
    );

    row_sram #(
        .DATA_WIDTH(BUS_WORDS * BIT_WIDTH),
        .DEPTH(32),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_input_sram (
        .clk(clk),
        .we(sram_we_ext),
        .waddr(sram_waddr_ext),
        .wdata(sram_wdata_ext),
        .raddr(sram_raddr),
        .rdata(sram_rdata_bus)
    );

    row_sram #(
        .DATA_WIDTH(ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_output_sram (
        .clk(clk),
        .we(wb_valid),
        .waddr(wb_ptr),
        .wdata(wb_data),
        .raddr(wb_ptr_next),
        .rdata(old_out)
    );

endmodule
