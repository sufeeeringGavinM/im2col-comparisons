`timescale 1ns / 1ps

// Tap sequencing, pass duration, and active PE weight-buffer selection
module conv_controller #(
    parameter integer ARRAY_SIZE = 10,
    parameter integer CFG_WIDTH  = 32
) (
    input  wire                 clk,
    input  wire                 nrst,
    input  wire                 start,
    input  wire                 initial_done,
    input wire advance,
    input  wire [CFG_WIDTH-1:0] N, P, Q, R, S,
    output wire                 busy,
    output reg                  done,
    output wire                 clear_pass,
    output wire                 prime,
    output wire                 initial_load,
    output wire                 running,
    output wire                 preload_next,
    output wire                 restart_weights,
    output wire                 accumulate,
    output reg                  active_weight_buffer,
    output reg  [CFG_WIDTH-1:0] r, s,
    output wire [CFG_WIDTH-1:0] next_r, next_s
);

    localparam [2:0] IDLE         = 3'd0,
                     PRIME        = 3'd1,
                     LOAD_WEIGHTS = 3'd2,
                     RUN          = 3'd3,
                     SWITCH_TAP   = 3'd4;

    reg [2:0] state;
    reg [CFG_WIDTH:0] run_count;
    wire [CFG_WIDTH:0] run_cycles = (CFG_WIDTH+1)'(N) * P * Q + 2*ARRAY_SIZE;

    assign busy = (state != IDLE);
    assign clear_pass = !nrst || (state != RUN);
    wire has_next_tap = (r != R - 1) || (s != S - 1);
    assign next_r = (s == S - 1) ? r + 1'b1 : r;
    assign next_s = (s == S - 1) ? {CFG_WIDTH{1'b0}} : s + 1'b1;

    assign preload_next = (state == RUN) && has_next_tap;
    assign prime = (state == PRIME);
    assign initial_load = (state == LOAD_WEIGHTS);
    assign running = (state == RUN);
    assign accumulate = (r != 0) || (s != 0);
    assign restart_weights = (state == IDLE && start) ||
                             (state == RUN && advance && run_count == run_cycles - 1 && has_next_tap);

    always @(posedge clk) begin
        if (!nrst) begin
            state                <= IDLE;
            done                 <= 1'b0;
            active_weight_buffer <= 1'b0;
            r                    <= {CFG_WIDTH{1'b0}};
            s                    <= {CFG_WIDTH{1'b0}};
            run_count            <= {(CFG_WIDTH+1){1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        active_weight_buffer <= 1'b0;
                        r                    <= {CFG_WIDTH{1'b0}};
                        s                    <= {CFG_WIDTH{1'b0}};
                        run_count            <= {(CFG_WIDTH+1){1'b0}};
                        state                <= PRIME;
                    end
                end

                PRIME: begin
                    state <= LOAD_WEIGHTS;
                end

                LOAD_WEIGHTS: begin
                    if (initial_done) begin
                        run_count <= {(CFG_WIDTH+1){1'b0}};
                        state     <= RUN;
                    end
                end

                SWITCH_TAP: begin
                    run_count <= {(CFG_WIDTH+1){1'b0}};
                    state     <= RUN;
                end

                RUN: if (advance) begin
                    if (run_count == run_cycles - 1) begin
                        run_count <= {(CFG_WIDTH+1){1'b0}};
                        if ((s == S - 1) && (r == R - 1)) begin
                            state <= IDLE;
                            done  <= 1'b1;
                        end else begin
                            r                    <= next_r;
                            s                    <= next_s;
                            active_weight_buffer <= !active_weight_buffer;
                            state                <= SWITCH_TAP;
                        end
                    end else begin
                        run_count <= run_count + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
