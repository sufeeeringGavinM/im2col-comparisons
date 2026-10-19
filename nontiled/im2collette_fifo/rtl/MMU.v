`timescale 1ns / 1ps

module MMU #(
    parameter integer ARRAY_SIZE = 10,
    parameter integer BIT_WIDTH  = 8,
    parameter integer BUS_WORDS  = 8,
    parameter integer ACC_WIDTH  = 32,
    parameter integer ADDR_WIDTH = 8,
    parameter integer CFG_WIDTH  = 32
) (
    input  wire                                             clk,
    input  wire                                             nrst,
    input  wire                                             clear_pass,
    input  wire                                             load_weights,
    input  wire                                             weight_write_buffer,
    input  wire                                             weight_read_buffer,
    input  wire                                             accumulate,

    input  wire [CFG_WIDTH-1:0]                             cfg_N, cfg_C, cfg_K,
    input  wire [CFG_WIDTH-1:0]                             cfg_H, cfg_W, cfg_P, cfg_Q,
    input  wire [CFG_WIDTH-1:0]                             cfg_pad_i, cfg_pad_j,
    input  wire [CFG_WIDTH-1:0]                             cfg_stride_i, cfg_stride_j,
    input  wire [CFG_WIDTH-1:0]                             cfg_dilation_i, cfg_dilation_j,

    input  wire [CFG_WIDTH-1:0]                             r, s,

    input  wire [ARRAY_SIZE-1:0]                            sram_we_ext,
    input  wire [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0]            sram_waddr_ext,
    input  wire [ARRAY_SIZE-1:0][(BUS_WORDS*BIT_WIDTH)-1:0] sram_wdata_ext,
    input  wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0]             weight_row_in,

    output wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] observed_words,
    output wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0]             acc_col_out
);

    localparam integer OUT_LATENCY = ARRAY_SIZE + 2; // 11
    wire [CFG_WIDTH-1:0] output_pixels = cfg_N * cfg_P * cfg_Q;
    wire clear = !nrst || clear_pass;

    reg [CFG_WIDTH-1:0] position_cnt;
    wire [CFG_WIDTH-1:0] position_next = position_cnt + 1'b1;

    always @(posedge clk) begin
        if (clear) position_cnt <= {CFG_WIDTH{1'b0}};
        else       position_cnt <= position_next;
    end

    wire [CFG_WIDTH-1:0] read_pos = clear ? {CFG_WIDTH{1'b0}} : position_next;
    wire [ADDR_WIDTH-1:0] agen_addr;
    wire [3:0]            agen_offset;
    wire [BUS_WORDS-1:0]  agen_pattern;
    wire                  agen_valid;

    im2col_addr_gen #(
        .CFG_WIDTH(CFG_WIDTH),
        .POSITION_WIDTH(CFG_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BUS_WORDS(BUS_WORDS)
    ) u_agen (
        .cfg_N(cfg_N), .cfg_H(cfg_H), .cfg_W(cfg_W), .cfg_Q(cfg_Q),
        .cfg_pad_i(cfg_pad_i), .cfg_pad_j(cfg_pad_j),
        .cfg_stride_i(cfg_stride_i), .cfg_stride_j(cfg_stride_j),
        .cfg_dilation_i(cfg_dilation_i), .cfg_dilation_j(cfg_dilation_j),
        .position(read_pos), .r(r), .s(s),
        .sram_word_addr(agen_addr),
        .global_word_offset(agen_offset),
        .cfg_kernel_pattern(agen_pattern),
        .valid(agen_valid)
    );

    // Bundle width: feed_en (1) + valid (1) + byte_offset (4) + sram_addr (ADDR_WIDTH) = ADDR_WIDTH + 6
    localparam FW = ADDR_WIDTH + 6;
    wire [FW-1:0] feed_in = {!clear && (position_cnt < output_pixels), agen_valid, agen_offset, agen_addr};
    wire [ARRAY_SIZE:0][FW-1:0] feed_bus;
    assign feed_bus[0] = feed_in;

    wire [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] activation_rows;
    genvar c;
    generate
        for (c = 0; c < ARRAY_SIZE; c = c + 1) begin : g_c_lanes
            channel_bank #(
                .CHANNEL_INDEX(c),
                .BIT_WIDTH(BIT_WIDTH),
                .BUS_WORDS(BUS_WORDS),
                .ACC_WIDTH(ACC_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .CFG_WIDTH(CFG_WIDTH),
                .OUT_LATENCY(OUT_LATENCY)
            ) u_bank (
                .clk(clk),
                .clear(clear),
                .feed_active(c < cfg_C),
                .writeback_active(c < cfg_K),
                .stream_enable(!clear_pass),
                .accumulate(accumulate),
                .output_pixels(output_pixels),
                .feed_in(feed_bus[c]),
                .clear_feed(feed_in),
                .feed_out(feed_bus[c+1]),
                .sram_we_ext(sram_we_ext[c]),
                .sram_waddr_ext(sram_waddr_ext[c]),
                .sram_wdata_ext(sram_wdata_ext[c]),
                .result_in(acc_col_out[c]), .observed_word(observed_words[c]),
                .activation_out(activation_rows[c])
            );
        end
    endgenerate

    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .BIT_WIDTH(BIT_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .CFG_WIDTH(CFG_WIDTH)
    ) u_array (
        .clk(clk),
        .nrst(nrst),
        .clear_pass(clear_pass),
        .load_weights(load_weights),
        .weight_write_buffer(weight_write_buffer),
        .weight_read_buffer(weight_read_buffer),
        .cfg_C(cfg_C),
        .cfg_K(cfg_K),
        .activation_rows(activation_rows),
        .weight_row_in(weight_row_in),
        .acc_col_out(acc_col_out)
    );

endmodule
