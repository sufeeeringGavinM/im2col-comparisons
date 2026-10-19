`timescale 1ns / 1ps

// Combinational address generator for wide-word multi-banked SRAM and pattern shifts
module im2col_addr_gen #(
    parameter integer CFG_WIDTH      = 32,
    parameter integer POSITION_WIDTH = 32,
    parameter integer ADDR_WIDTH     = 8,
    parameter integer BUS_WORDS      = 8
) (
    input  wire [CFG_WIDTH-1:0]      cfg_N,
    input  wire [CFG_WIDTH-1:0]      cfg_H,
    input  wire [CFG_WIDTH-1:0]      cfg_W,
    input  wire [CFG_WIDTH-1:0]      cfg_Q,
    input  wire [CFG_WIDTH-1:0]      cfg_pad_i,
    input  wire [CFG_WIDTH-1:0]      cfg_pad_j,
    input  wire [CFG_WIDTH-1:0]      cfg_stride_i,
    input  wire [CFG_WIDTH-1:0]      cfg_stride_j,
    input  wire [CFG_WIDTH-1:0]      cfg_dilation_i,
    input  wire [CFG_WIDTH-1:0]      cfg_dilation_j,
    input  wire [POSITION_WIDTH-1:0] position,
    input  wire [CFG_WIDTH-1:0]      r,
    input  wire [CFG_WIDTH-1:0]      s,
    output wire [ADDR_WIDTH-1:0]     sram_word_addr,
    output wire [3:0]                global_word_offset,
    output wire [BUS_WORDS-1:0]      cfg_kernel_pattern,
    output wire                      valid
);

    wire [POSITION_WIDTH-1:0] n   = position % cfg_N;
    wire [POSITION_WIDTH-1:0] pix = position / cfg_N;
    wire [POSITION_WIDTH-1:0] p   = pix / cfg_Q;
    wire [POSITION_WIDTH-1:0] q   = pix % cfg_Q;

    wire signed [63:0] p_signed = $signed({1'b0, p});
    wire signed [63:0] q_signed = $signed({1'b0, q});
    wire signed [63:0] r_signed = $signed({1'b0, r});
    wire signed [63:0] s_signed = $signed({1'b0, s});

    wire signed [63:0] h = p_signed * cfg_stride_i + r_signed * cfg_dilation_i - cfg_pad_i;
    wire signed [63:0] w = q_signed * cfg_stride_j + s_signed * cfg_dilation_j - cfg_pad_j;

    assign valid = (h >= 0) && (h < cfg_H) && (w >= 0) && (w < cfg_W);
    wire signed [63:0] linear_byte = valid ? (h * cfg_W + w) * cfg_N + n : 64'sd0;

    assign sram_word_addr     = linear_byte[ADDR_WIDTH+$clog2(BUS_WORDS)-1 : $clog2(BUS_WORDS)];
    assign global_word_offset = linear_byte[$clog2(BUS_WORDS)-1:0];
    assign cfg_kernel_pattern = 8'b00000001;

endmodule