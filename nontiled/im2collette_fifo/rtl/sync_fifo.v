`timescale 1ns / 1ps

module sync_fifo #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH      = 8,
    parameter integer ADDR_WIDTH = 3  // 2^3 = 8 
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  full,
    output wire                  empty,
    output wire [ADDR_WIDTH:0]   count
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   status_cnt;

    assign full  = (status_cnt == DEPTH);
    assign empty = (status_cnt == 0);
    assign count = status_cnt;

    assign dout = mem[rd_ptr];

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr     <= {ADDR_WIDTH{1'b0}};
            rd_ptr     <= {ADDR_WIDTH{1'b0}};
            status_cnt <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: begin
                    mem[wr_ptr] <= din;
                    wr_ptr      <= wr_ptr + 1'b1;
                    status_cnt  <= status_cnt + 1'b1;
                end
                2'b01: begin
                    rd_ptr      <= rd_ptr + 1'b1;
                    status_cnt  <= status_cnt - 1'b1;
                end
                2'b11: begin
                    mem[wr_ptr] <= din;
                    wr_ptr      <= wr_ptr + 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule