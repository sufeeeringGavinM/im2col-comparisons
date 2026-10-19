`timescale 1ns / 1ps

module feed_lane #(
    parameter integer CHANNEL_INDEX = 0,
    parameter integer BIT_WIDTH     = 8,
    parameter integer BUS_WORDS     = 8,
    parameter integer ADDR_WIDTH    = 8,
    parameter integer M_INTERM      = 4,
    parameter integer FIFO_DEPTH    = 8
) (
    input  wire clk,
    input  wire clear,
    input  wire feed_active,
    input  wire stream_enable,

    // Bundle: {feed_en, valid, byte_offset, sram_raddr}
    input  wire [ADDR_WIDTH+5:0]            feed_in,
    input  wire [ADDR_WIDTH+5:0]            clear_feed,
    output wire [ADDR_WIDTH+5:0]            feed_out,

    output wire [ADDR_WIDTH-1:0]            sram_raddr,
    input  wire [(BUS_WORDS*BIT_WIDTH)-1:0] sram_rdata_bus,
    output wire [BIT_WIDTH-1:0]             activation_out,
    output wire                             lane_ready
);

    // 1. Skew chain: row 0 has zero delay; row c adds c registers
    generate
        if (CHANNEL_INDEX == 0) begin : g_first
            assign feed_out = feed_in;
        end else begin : g_skew
            reg [ADDR_WIDTH+5:0] stage;
            always @(posedge clk) begin
                stage <= clear ? clear_feed : feed_in;
            end
            assign feed_out = stage;
        end
    endgenerate

    // 2. Drive synchronous SRAM read address
    assign sram_raddr = feed_out[ADDR_WIDTH-1:0];

    // 3. Register signals to align with synchronous SRAM read data
    reg [3:0] byte_offset_q;
    reg       rd_valid_q;

    always @(posedge clk) begin
        rd_valid_q    <= feed_out[ADDR_WIDTH+4];
        byte_offset_q <= feed_out[ADDR_WIDTH+3 : ADDR_WIDTH];
    end

    // 4. Unpack wide bus
    wire [BIT_WIDTH-1:0] bus_words [BUS_WORDS-1:0];
    genvar w;
    generate
        for (w = 0; w < BUS_WORDS; w = w + 1) begin : g_unpack
            assign bus_words[w] = sram_rdata_bus[w*BIT_WIDTH +: BIT_WIDTH];
        end
    endgenerate

    // 5. Intermediate Receptive-Field Window Registers (Zhou et al.)
    wire [BIT_WIDTH-1:0] interm_window [0:M_INTERM-1];
    genvar m;
    generate
        for (m = 0; m < M_INTERM; m = m + 1) begin : g_interm
            assign interm_window[m] = bus_words[(byte_offset_q + m) % BUS_WORDS];
        end
    endgenerate

    wire [BIT_WIDTH-1:0] selected_word = interm_window[0];

    // 6. Decoupling Synchronous FIFO
    wire [BIT_WIDTH-1:0] fifo_dout;
    wire                 fifo_full;
    wire                 fifo_empty;

    wire push_valid = feed_active && stream_enable && feed_out[ADDR_WIDTH+5];
    wire [BIT_WIDTH-1:0] fifo_input = rd_valid_q ? selected_word : {BIT_WIDTH{1'b0}};
    wire fifo_wr_en = push_valid && !fifo_full;
    wire fifo_rd_en = feed_active && stream_enable && !fifo_empty;

    sync_fifo #(
        .DATA_WIDTH(BIT_WIDTH),
        .DEPTH(FIFO_DEPTH),
        .ADDR_WIDTH(3)
    ) u_lowered_fifo (
        .clk   (clk),
        .rst   (clear),
        .wr_en (fifo_wr_en),
        .din   (fifo_input),
        .rd_en (fifo_rd_en),
        .dout  (fifo_dout),
        .full  (fifo_full),
        .empty (fifo_empty),
        .count ()
    );

    assign lane_ready = !fifo_full;

    // 7. Exact baseline gating: uses un-delayed feed_out[ADDR_WIDTH+5]
    assign activation_out = (feed_active && stream_enable && !fifo_empty)
                            ? fifo_dout : {BIT_WIDTH{1'b0}};

endmodule
