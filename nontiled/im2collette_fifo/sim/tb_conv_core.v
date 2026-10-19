// Tensor-file convolution test: preload memories, start the core, and check SRAM outputs.
`timescale 1ns / 1ps

module tb_conv_core;
  parameter integer ARRAY_SIZE = 10;
  parameter integer BUS_WORDS  = 8;   // 8 bytes per wide SRAM word line
  integer N = 1;
  integer C = 4;
  integer K = 2;
  integer H = 6;
  integer W = 6;
  integer R = 3;
  integer S = 3;
  integer pad_i = 0;
  integer pad_j = 0;
  integer stride_i = 1;
  integer stride_j = 1;
  integer dilation_i = 1;
  integer dilation_j = 1;

  // Operands are BIT_WIDTH bits; SRAM outputs retain ACC_WIDTH bits.
  parameter integer BIT_WIDTH = 8;
  parameter integer ACC_WIDTH = 32;
  parameter integer ADDR_WIDTH = 8;
  parameter integer KERNEL_ADDR_WIDTH = 8;

  integer P;
  integer Q;
  localparam integer SRAM_DEPTH = 1 << ADDR_WIDTH;

  reg clk = 0;
  reg nrst = 0;
  reg start = 0;
  wire busy, done;

  // CHANGED: sram_wdata_ext is now 64 bits (BUS_WORDS * BIT_WIDTH) per channel
  reg [ARRAY_SIZE-1:0] sram_we_ext = 0;
  reg [ARRAY_SIZE-1:0][ADDR_WIDTH-1:0] sram_waddr_ext = 0;
  reg [ARRAY_SIZE-1:0][(BUS_WORDS*BIT_WIDTH)-1:0] sram_wdata_ext = 0;

  reg [ARRAY_SIZE-1:0] kernel_we_ext = 0;
  reg [ARRAY_SIZE-1:0][KERNEL_ADDR_WIDTH-1:0] kernel_waddr_ext = 0;
  reg [ARRAY_SIZE-1:0][BIT_WIDTH-1:0] kernel_wdata_ext = 0;
  wire [ARRAY_SIZE-1:0][ACC_WIDTH-1:0] acc_col_out;

  reg signed [BIT_WIDTH-1:0] input_tensor [0:ARRAY_SIZE*SRAM_DEPTH*BUS_WORDS-1];
  reg signed [BIT_WIDTH-1:0] kernel_tensor [0:ARRAY_SIZE*(1<<KERNEL_ADDR_WIDTH)-1];
  reg signed [ACC_WIDTH-1:0] expected [0:ARRAY_SIZE*SRAM_DEPTH-1];
  reg signed [ACC_WIDTH-1:0] total;
  reg signed [ACC_WIDTH-1:0] expected_word;
  integer n, c, k, p, q, h, w, r_index, s_index;
  integer a, fd, errors;
  string input_file, kernel_file, output_file, wave_file, layout_file;

  conv_core #(
      .ARRAY_SIZE(ARRAY_SIZE),
      .BIT_WIDTH(BIT_WIDTH),
      .BUS_WORDS(BUS_WORDS),
      .ACC_WIDTH(ACC_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH),
      .KERNEL_ADDR_WIDTH(KERNEL_ADDR_WIDTH)
  ) UUT (
      .cfg_N(N),
      .cfg_C(C),
      .cfg_H(H),
      .cfg_W(W),
      .cfg_K(K),
      .cfg_R(R),
      .cfg_S(S),
      .cfg_P(P),
      .cfg_Q(Q),
      .cfg_pad_i(pad_i),
      .cfg_pad_j(pad_j),
      .cfg_stride_i(stride_i),
      .cfg_stride_j(stride_j),
      .cfg_dilation_i(dilation_i),
      .cfg_dilation_j(dilation_j),
      .clk(clk), .nrst(nrst), .start(start), .busy(busy), .done(done),
      .kernel_we_ext(kernel_we_ext), .kernel_waddr_ext(kernel_waddr_ext),
      .kernel_wdata_ext(kernel_wdata_ext),
      .sram_we_ext(sram_we_ext), .sram_waddr_ext(sram_waddr_ext),
      .sram_wdata_ext(sram_wdata_ext), .acc_col_out(acc_col_out)
  );

  // CHANGED: input_dump widened to 64 bits to reflect multi-word SRAM words
  wire [(BUS_WORDS*BIT_WIDTH)-1:0] input_dump [0:ARRAY_SIZE-1][0:31];
  wire [ACC_WIDTH-1:0] output_dump [0:ARRAY_SIZE-1][0:SRAM_DEPTH-1];
  wire [BIT_WIDTH-1:0] kernel_dump [0:ARRAY_SIZE-1][0:(1<<KERNEL_ADDR_WIDTH)-1];
  genvar bank, address;
  generate
    for (bank = 0; bank < ARRAY_SIZE; bank = bank + 1) begin : g_dump
      for (address = 0; address < SRAM_DEPTH; address = address + 1) begin : g_sram
        // CHANGED: Hierarchical path updated to g_c_lanes
        if (address < 32) assign input_dump[bank][address] = UUT.u_mmu.g_c_lanes[bank].u_bank.u_input_sram.mem[address];
        assign output_dump[bank][address] = UUT.u_mmu.g_c_lanes[bank].u_bank.u_output_sram.mem[address];
      end
      for (address = 0; address < (1<<KERNEL_ADDR_WIDTH); address = address + 1) begin : g_kernel
        assign kernel_dump[bank][address] = UUT.g_kernel_banks[bank].u_kbank.mem[address];
      end
    end
  endgenerate

  always #5 clk = !clk;

  reg [63:0] clock_cycles = 0;
  reg [63:0] run_start_cycle = 0;
  always @(posedge clk) begin
    clock_cycles <= clock_cycles + 1;
    if (nrst && start && !busy) run_start_cycle <= clock_cycles + 1;
  end

  // CHANGED: Packs consecutive elements into 8-byte multi-word lines
  task load_input_tensor;
    integer total_bytes, word_idx, byte_offset, linear_idx;
    reg [(BUS_WORDS*BIT_WIDTH)-1:0] packed_line;
    begin
      total_bytes = H * W * N;
      for (word_idx = 0; word_idx < (total_bytes + BUS_WORDS - 1)/BUS_WORDS; word_idx = word_idx + 1) begin
        @(negedge clk);
        sram_we_ext = 0;
        for (c = 0; c < C; c = c + 1) begin
          packed_line = 0;
          for (byte_offset = 0; byte_offset < BUS_WORDS; byte_offset = byte_offset + 1) begin
            linear_idx = word_idx * BUS_WORDS + byte_offset;
            if (linear_idx < total_bytes) begin
              // Mapping: flat_addr = (a)*N + n -> input_tensor[(n*C + c)*H*W + a]
              a = linear_idx / N;
              n = linear_idx % N;
              packed_line[byte_offset*BIT_WIDTH +: BIT_WIDTH] = input_tensor[(n*C + c)*H*W + a];
            end
          end
          sram_waddr_ext[c] = word_idx;
          sram_wdata_ext[c] = packed_line;
          sram_we_ext[c]    = 1;
        end
        @(posedge clk);
      end
      @(negedge clk);
      sram_we_ext = 0;
    end
  endtask

  task load_kernel_tensor;
    begin
      for (a = 0; a < C*R*S; a = a + 1) begin
        @(negedge clk);
        for (k = 0; k < K; k = k + 1) begin
          kernel_waddr_ext[k] = a;
          kernel_wdata_ext[k] = kernel_tensor[k*C*R*S + a];
        end
        kernel_we_ext = (1 << K) - 1;
        @(posedge clk);
      end
      @(negedge clk);
      kernel_we_ext = 0;
    end
  endtask

  task build_reference;
    begin
      for (n = 0; n < N; n = n + 1)
        for (k = 0; k < K; k = k + 1)
          for (p = 0; p < P; p = p + 1)
            for (q = 0; q < Q; q = q + 1) begin
              total = 0;
              for (c = 0; c < C; c = c + 1)
                for (r_index = 0; r_index < R; r_index = r_index + 1)
                  for (s_index = 0; s_index < S; s_index = s_index + 1) begin
                    h = p*stride_i + r_index*dilation_i - pad_i;
                    w = q*stride_j + s_index*dilation_j - pad_j;
                    if (h >= 0 && h < H && w >= 0 && w < W)
                      total = total + input_tensor[((n*C+c)*H+h)*W+w] *
                                      kernel_tensor[((k*C+c)*R+r_index)*S+s_index];
                  end
              expected[((n*K+k)*P+p)*Q+q] = total;
            end
    end
  endtask

  task dump_sram_layout;
    integer b, address, byte_pos;
    begin
      fd = $fopen(layout_file, "w");
      $fdisplay(fd, "SRAM layout after done: actual simulated contents");
      $fdisplay(fd, "ARRAY_SIZE=%0d N=%0d C=%0d K=%0d H=%0d W=%0d R=%0d S=%0d P=%0d Q=%0d",
                ARRAY_SIZE, N, C, K, H, W, R, S, P, Q);
      $fdisplay(fd, "Addresses are decimal; values are two's-complement hex with signed decimal.");
      $fdisplay(fd, "Input SRAM: %0d arrays, %0d words per array, %0d bits per word line",
                ARRAY_SIZE, 32, BUS_WORDS*BIT_WIDTH);
      for (b = 0; b < ARRAY_SIZE; b = b + 1) begin
        $fdisplay(fd, "\nInput SRAM array %0d:", b);
        for (address = 0; address < (N*H*W + BUS_WORDS - 1)/BUS_WORDS; address = address + 1) begin
          $fdisplay(fd, "  line_addr %0d = %h", address, input_dump[b][address]);
        end
      end

      $fdisplay(fd, "\nOutput SRAM: %0d arrays, %0d words per array, %0d bits per word",
                ARRAY_SIZE, SRAM_DEPTH, ACC_WIDTH);
      for (b = 0; b < ARRAY_SIZE; b = b + 1) begin
        $fdisplay(fd, "\nOutput SRAM array %0d:", b);
        for (address = 0; address < SRAM_DEPTH; address = address + 1)
          if (b < K && address < N*P*Q)
            $fdisplay(fd, "  addr %0d = %h (%0d)  output[n=%0d,k=%0d,p=%0d,q=%0d]",
                      address, output_dump[b][address], $signed(output_dump[b][address]),
                      address%N, b, address/(N*Q), (address/N)%Q);
      end

      $fdisplay(fd, "\nKernel SRAM: %0d arrays, %0d words per array, %0d bits per word",
                ARRAY_SIZE, 1<<KERNEL_ADDR_WIDTH, BIT_WIDTH);
      for (b = 0; b < ARRAY_SIZE; b = b + 1) begin
        $fdisplay(fd, "\nKernel SRAM array %0d:", b);
        for (address = 0; address < (1<<KERNEL_ADDR_WIDTH); address = address + 1)
          if (b < K && address < C*R*S)
            $fdisplay(fd, "  addr %0d = %h (%0d)  kernel[k=%0d,c=%0d,r=%0d,s=%0d]",
                      address, kernel_dump[b][address], $signed(kernel_dump[b][address]),
                      b, address/(R*S), (address/S)%R, address%S);
      end
      $fclose(fd);
      $display("SRAM layout written to %s", layout_file);
    end
  endtask

  task check_and_dump_output;
    integer linear_byte, word_addr, byte_offset;
    reg [BIT_WIDTH-1:0] actual_byte;
    begin
      fd = $fopen(output_file, "w");
      $fdisplay(fd, "// shape=(%0d,%0d,%0d,%0d), last coordinate varies fastest, hex", N, K, P, Q);
      errors = 0;
      for (n = 0; n < N; n = n + 1)
        for (k = 0; k < K; k = k + 1)
          for (p = 0; p < P; p = p + 1) begin
            for (q = 0; q < Q; q = q + 1) begin
              expected_word = expected[((n*K+k)*P+p)*Q+q];
              if (output_dump[k][(p*Q+q)*N+n] !== expected_word) begin
                $display("FAIL (n,k,p,q)=(%0d,%0d,%0d,%0d): expected=%h actual=%h",
                         n, k, p, q, expected_word, output_dump[k][(p*Q+q)*N+n]);
                errors = errors + 1;
              end
              $fwrite(fd, "%h ", output_dump[k][(p*Q+q)*N+n]);
            end
            $fwrite(fd, "\n");
          end
      $fclose(fd);

      // CHANGED: Unpack the multi-word memory lines when checking input retention
      for (c = 0; c < C; c = c + 1)
        for (a = 0; a < H*W; a = a + 1)
          for (n = 0; n < N; n = n + 1) begin
            linear_byte = a*N + n;
            word_addr   = linear_byte / BUS_WORDS;
            byte_offset = linear_byte % BUS_WORDS;
            actual_byte = input_dump[c][word_addr][byte_offset*BIT_WIDTH +: BIT_WIDTH];
            if (actual_byte !== input_tensor[(n*C+c)*H*W+a])
              $fatal(1, "Input SRAM changed during convolution at c=%0d addr=%0d", c, linear_byte);
          end

      if (errors) $fatal(1, "%0d convolution outputs failed", errors);
      $display("PASS: %0d convolution outputs matched; written to %s", N*K*P*Q, output_file);
    end
  endtask

  initial begin
    input_file = "sim/input_tensor.txt";
    kernel_file = "sim/kernel_tensor.txt";
    output_file = "sim/output_tensor_core.txt";
    wave_file = "";
    layout_file = "sim/sram_layout.txt";
    if ($value$plusargs("INPUT_FILE=%s", input_file)) begin end
    if ($value$plusargs("KERNEL_FILE=%s", kernel_file)) begin end
    if ($value$plusargs("OUTPUT_FILE=%s", output_file)) begin end
    if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin end
    if ($value$plusargs("SRAM_LAYOUT_FILE=%s", layout_file)) begin end
    if ($value$plusargs("N=%d", N)) begin end
    if ($value$plusargs("C=%d", C)) begin end
    if ($value$plusargs("H=%d", H)) begin end
    if ($value$plusargs("W=%d", W)) begin end
    if ($value$plusargs("K=%d", K)) begin end
    if ($value$plusargs("R=%d", R)) begin end
    if ($value$plusargs("S=%d", S)) begin end
    if ($value$plusargs("pad_i=%d", pad_i)) begin end
    if ($value$plusargs("pad_j=%d", pad_j)) begin end
    if ($value$plusargs("stride_i=%d", stride_i)) begin end
    if ($value$plusargs("stride_j=%d", stride_j)) begin end
    if ($value$plusargs("dilation_i=%d", dilation_i)) begin end
    if ($value$plusargs("dilation_j=%d", dilation_j)) begin end

    P = (H + 2*pad_i - dilation_i*(R-1) - 1) / stride_i + 1;
    Q = (W + 2*pad_j - dilation_j*(S-1) - 1) / stride_j + 1;

    if (N*H*W > 32*BUS_WORDS || N*P*Q > SRAM_DEPTH || C*R*S > (1 << KERNEL_ADDR_WIDTH))
      $fatal(1, "Matched memory capacity exceeded");

    $readmemh(input_file, input_tensor, 0, N*C*H*W-1);
    $readmemh(kernel_file, kernel_tensor, 0, K*C*R*S-1);
    build_reference;

    if (wave_file != "") begin
      $dumpfile(wave_file);
      $dumpvars(0, tb_conv_core);
    end

    repeat (2) @(posedge clk);
    @(negedge clk);
    nrst = 1;
    load_input_tensor;
    load_kernel_tensor;

    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
    wait (done);
    #1;

    $display("[METRIC] Run cycles (start accepted to done): %0d", clock_cycles - run_start_cycle);
    $display("[METRIC] Useful MAC utilization (channels only): %0.2f%% (%0d/%0d PEs; C=%0d K=%0d)",
             100.0 * C * K / (ARRAY_SIZE * ARRAY_SIZE), C*K, ARRAY_SIZE*ARRAY_SIZE, C, K);
    dump_sram_layout;
    check_and_dump_output;
    $finish;
  end

endmodule
