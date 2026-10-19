`timescale 1ns/1ps
// Sequence contiguous CRS reduction groups; switch only after output drain.
module conv_controller #(parameter ARRAY_SIZE=4, CFG_WIDTH=32) (
    input clk, nrst, start, initial_done, pass_done, next_ready,
    input [CFG_WIDTH-1:0] C, R, S,
    output busy, clear_pass, prime, initial_load, running, preload_next, restart_weights, accumulate,
    output reg done, active_weight_buffer,
    output reg [CFG_WIDTH-1:0] group_base,
    output [CFG_WIDTH-1:0] next_group_base
);
  localparam IDLE=0, PRIME=1, LOAD=2, RUN=3, SWITCH=4;
  reg [2:0] state;
  wire has_next = group_base+ARRAY_SIZE < C*R*S;
  assign next_group_base = group_base+ARRAY_SIZE;
  assign busy = state!=IDLE;
  assign clear_pass = !nrst || state!=RUN;
  assign prime = state==PRIME;
  assign initial_load = state==LOAD;
  assign running = state==RUN;
  assign preload_next = running && has_next;
  assign restart_weights = (state==IDLE && start) || (running && pass_done && has_next && next_ready);
  assign accumulate = group_base!=0;
  always @(posedge clk) begin
    if (!nrst) begin
      state<=IDLE; done<=0; group_base<=0; active_weight_buffer<=0;
    end else begin
      done<=0;
      case (state)
        IDLE: if(start) begin state<=PRIME; group_base<=0; active_weight_buffer<=0; end
        PRIME: state<=LOAD;
        LOAD: if(initial_done) state<=RUN;
        SWITCH: state<=RUN;
        RUN: if(pass_done) begin
          if(!has_next) begin state<=IDLE; done<=1; end
          else if(next_ready) begin
            group_base<=next_group_base;
            active_weight_buffer<=!active_weight_buffer;
            state<=SWITCH;
          end
        end
        default: state<=IDLE;
      endcase
    end
  end
endmodule
