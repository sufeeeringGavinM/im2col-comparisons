`timescale 1ns/1ps
// Synchronous kernel reads and descending row shifts; weight loading never stalls with activations.
module weight_loader #(parameter ARRAY_SIZE=4, BIT_WIDTH=8, ADDR_WIDTH=8, CFG_WIDTH=32) (
    input clk, nrst, restart, prime, initial_load, preload_next, running, active_weight_buffer,
    input [CFG_WIDTH-1:0] group_base, next_group_base,
    input [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] kernel_rdata,
    output load_weights, weight_write_buffer, initial_done, kernel_read_enable, next_ready,
    output [ADDR_WIDTH-1:0] kernel_raddr,
    output [CFG_WIDTH-1:0] kernel_term,
    output [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] weight_row_in
);
  localparam ROW_WIDTH=(ARRAY_SIZE>1?$clog2(ARRAY_SIZE):1);
  localparam PREFETCH=0, SHIFT=1, READY=2;
  reg [1:0] phase;
  reg [ROW_WIDTH-1:0] load_row;
  assign load_weights = initial_load || (preload_next && phase==SHIFT);
  assign weight_write_buffer = running ? !active_weight_buffer : active_weight_buffer;
  assign initial_done = load_row==0;
  assign next_ready = phase==READY;
  wire [ROW_WIDTH-1:0] read_row = (load_weights && load_row!=0) ? load_row-1'b1 : load_row;
  assign kernel_term = (running ? next_group_base : group_base)+read_row;
  assign kernel_raddr = ADDR_WIDTH'(kernel_term);
  assign kernel_read_enable = prime || initial_load || (preload_next && phase!=READY);
  assign weight_row_in = load_weights ? kernel_rdata : 0;
  always @(posedge clk) begin
    if(!nrst || restart) begin load_row<=ROW_WIDTH'(ARRAY_SIZE-1); phase<=PREFETCH; end
    else if(initial_load) begin
      if(initial_done) begin load_row<=ROW_WIDTH'(ARRAY_SIZE-1); phase<=PREFETCH; end
      else load_row<=load_row-1'b1;
    end else if(preload_next) begin
      case(phase)
        PREFETCH: phase<=SHIFT;
        SHIFT: if(load_row==0) phase<=READY; else load_row<=load_row-1'b1;
        READY: begin end
      endcase
    end
  end
endmodule
