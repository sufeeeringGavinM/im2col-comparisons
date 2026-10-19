`timescale 1ns/1ps
module im2col_addr_gen #(parameter ARRAY_SIZE=10, CFG_WIDTH=32, ADDR_WIDTH=8,
    BANK_WIDTH=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1)) (

    input [CFG_WIDTH-1:0] N, C, H, W, R, S, Q,
    input [CFG_WIDTH-1:0] pad_i, pad_j, stride_i, stride_j, dilation_i, dilation_j,
    input [CFG_WIDTH-1:0] position, group_base,

    output [ARRAY_SIZE-1:0] valid,
    output [ARRAY_SIZE-1:0][BANK_WIDTH-1:0] bank,
    output [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] addr
);
  genvar lane;
  generate for (lane=0; lane<ARRAY_SIZE; lane=lane+1) begin : g_row
    row_addr_gen #(.ARRAY_SIZE(ARRAY_SIZE), .ROW_INDEX(lane), .CFG_WIDTH(CFG_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_row (
      .N(N),.C(C),.H(H),.W(W),.R(R),.S(S),.Q(Q),
      .pad_i(pad_i),.pad_j(pad_j),.stride_i(stride_i),.stride_j(stride_j),
      .dilation_i(dilation_i),.dilation_j(dilation_j),.position(position),.group_base(group_base),
      .lane_valid(valid[lane]),.lane_bank(bank[lane]),.lane_addr(addr[lane]));
  end endgenerate
endmodule
module row_addr_gen #(parameter ARRAY_SIZE=10, ROW_INDEX=0, CFG_WIDTH=32, ADDR_WIDTH=8,
    BANK_WIDTH=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1)) (

    input [CFG_WIDTH-1:0] N, C, H, W, R, S, Q,
    input [CFG_WIDTH-1:0] pad_i, pad_j, stride_i, stride_j, dilation_i, dilation_j,
    input [CFG_WIDTH-1:0] position, group_base,
    output lane_valid,
    output [BANK_WIDTH-1:0] lane_bank,
    output [ADDR_WIDTH-1:0] lane_addr
);

  wire [CFG_WIDTH-1:0] n = position % N;
  wire [CFG_WIDTH-1:0] pix = position / N;
  wire [CFG_WIDTH-1:0] p = pix / Q;
  wire [CFG_WIDTH-1:0] q = pix % Q;
  localparam COORD_WIDTH = 2*CFG_WIDTH+2;
  wire signed [COORD_WIDTH-1:0] origin_h = $signed({1'b0,p}) * $signed({1'b0,stride_i}) - $signed({1'b0,pad_i});
  wire signed [COORD_WIDTH-1:0] origin_w = $signed({1'b0,q}) * $signed({1'b0,stride_j}) - $signed({1'b0,pad_j});
  wire [CFG_WIDTH-1:0] tile_rows = (H + R - 1) / R;
  wire [CFG_WIDTH-1:0] tile_cols = (W + S - 1) / S;

      wire [CFG_WIDTH-1:0] term = group_base + ROW_INDEX;
      wire [CFG_WIDTH-1:0] c = term / (R*S);
      wire [CFG_WIDTH-1:0] r = (term / S) % R;
      wire [CFG_WIDTH-1:0] s = term % S;
      wire signed [COORD_WIDTH-1:0] h = origin_h + $signed({1'b0,r}) * $signed({1'b0,dilation_i});
      wire signed [COORD_WIDTH-1:0] w = origin_w + $signed({1'b0,s}) * $signed({1'b0,dilation_j});
      wire in_bounds = term < C*R*S && h >= 0 && h < H && w >= 0 && w < W;
      wire [CFG_WIDTH-1:0] hu = CFG_WIDTH'(h), wu = CFG_WIDTH'(w);
      wire [CFG_WIDTH-1:0] slot = c*R*S + (hu % R)*S + wu % S;
      assign lane_valid = in_bounds;
      assign lane_bank = in_bounds ? BANK_WIDTH'(slot % ARRAY_SIZE) : 0;
      assign lane_addr = in_bounds ? ADDR_WIDTH'(((slot / ARRAY_SIZE)*tile_rows*tile_cols + (hu/R)*tile_cols + wu/S)*N+n) : 0;
endmodule
