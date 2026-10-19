// One-layer demonstration: backing tensors -> hardware tiles -> completed output.
`timescale 1ns/1ps
module tb_conv_accelerator;
  // Configuration, tensor geometry and external-memory interface.
  parameter ARRAY_SIZE = 10;
  parameter BIT_WIDTH = 8;
  parameter ACC_WIDTH = 32;
  parameter INPUT_ADDR_WIDTH = 8;
  parameter OUTPUT_ADDR_WIDTH = 8;
  parameter KERNEL_ADDR_WIDTH = 8;
  parameter MEM_ADDR_WIDTH = 16;
  localparam MEM_DEPTH = 1 << MEM_ADDR_WIDTH;
  localparam MEM_DATA_WIDTH = ACC_WIDTH > BIT_WIDTH ? ACC_WIDTH : BIT_WIDTH;
  integer N = 1, C = 4, H = 6, W = 6, K = 2, R = 3, S = 3, P, Q;
  integer pad_i = 0, pad_j = 0, stride_i = 1, stride_j = 1, dilation_i = 1, dilation_j = 1;
  integer input_base, kernel_base, output_base, input_words, kernel_words, output_words;
  reg clk = 0, nrst = 0, start = 0;
  always #5 clk = ~clk;
  wire busy, done, mem_re, mem_we;
  wire [MEM_ADDR_WIDTH - 1:0] mem_raddr, mem_waddr;
  wire [MEM_DATA_WIDTH - 1:0] mem_wdata;
  reg [MEM_DATA_WIDTH - 1:0] mem_rdata;

  // The backing memory model is deliberately in the testbench, not RTL.
  // One enabled synchronous read and one edge-triggered write, like local SRAM.
  reg [MEM_DATA_WIDTH - 1:0] memory[0:MEM_DEPTH - 1];
  reg signed [BIT_WIDTH - 1:0] input_tensor[0:MEM_DEPTH - 1];
  reg signed [BIT_WIDTH - 1:0] kernel_tensor[0:MEM_DEPTH - 1];
  reg signed [ACC_WIDTH - 1:0] expected[0:MEM_DEPTH - 1];
  string input_file, kernel_file, output_file, layout_file, wave_file;
  integer a, n, c, k, p, q, r, s, h, w, fd;
  reg signed [ACC_WIDTH - 1:0] total;
  reg [63:0] clock_cycles = 0, start_cycle = 0;
  integer reads = 0, writes = 0;

  // The layer configuration stays constant for this demonstration.
  conv_accelerator #(
    .ARRAY_SIZE(ARRAY_SIZE),
    .BIT_WIDTH(BIT_WIDTH),
    .ACC_WIDTH(ACC_WIDTH),
    .INPUT_ADDR_WIDTH(INPUT_ADDR_WIDTH),
    .OUTPUT_ADDR_WIDTH(OUTPUT_ADDR_WIDTH),
    .KERNEL_ADDR_WIDTH(KERNEL_ADDR_WIDTH),
    .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH)
  ) DUT (
    .clk(clk),
    .nrst(nrst),
    .start(start),
    .busy(busy),
    .done(done),
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
    .cfg_input_base(MEM_ADDR_WIDTH'(input_base)),
    .cfg_kernel_base(MEM_ADDR_WIDTH'(kernel_base)),
    .cfg_output_base(MEM_ADDR_WIDTH'(output_base)),
    .mem_re(mem_re),
    .mem_we(mem_we),
    .mem_raddr(mem_raddr),
    .mem_rdata(mem_rdata),
    .mem_waddr(mem_waddr),
    .mem_wdata(mem_wdata)
  );
  `include "tensor_reader.vh"

  // SRAM-like backing memory: a read requested at this edge supplies registered
  // data after the edge. The accelerator consumes it on the following edge.
  always @(posedge clk) begin
    clock_cycles <= clock_cycles + 1;
    if (nrst) begin
      if (start && !busy) start_cycle <= clock_cycles + 1;

      if (mem_re) begin
        if ($isunknown(mem_raddr) || mem_raddr >= MEM_DEPTH)
          $fatal(1, "Backing read address out of range");
        mem_rdata <= memory[mem_raddr];
        reads <= reads + 1;
      end

      if (mem_we) begin
        if ($isunknown(mem_waddr) || mem_waddr >= MEM_DEPTH)
          $fatal(1, "Backing write address out of range");
        memory[mem_waddr] <= mem_wdata;
        writes <= writes + 1;
      end
    end
  end

  // Full-layer reference: tensor coordinates and signed arithmetic, independent
  // of the hardware tile schedule.
  task build_reference;
    begin
      for (n = 0; n < N; n = n + 1)
        for (k = 0; k < K; k = k + 1)
          for (p = 0; p < P; p = p + 1)
            for (q = 0; q < Q; q = q + 1) begin
              total = 0;
              for (c = 0; c < C; c = c + 1)
                for (r = 0; r < R; r = r + 1)
                  for (s = 0; s < S; s = s + 1) begin
                    h = p * stride_i + r * dilation_i - pad_i;
                    w = q * stride_j + s * dilation_j - pad_j;
                    if (h >= 0 && h < H && w >= 0 && w < W)
                      total = total + input_tensor[((n * C + c) * H + h) * W + w] * kernel_tensor[((k * C + c) * R + r) * S + s];
                  end
              expected[((n * K + k) * P + p) * Q + q] = total;
            end
    end
  endtask

  // Check the completed layer and export the actual backing-memory outputs.
  task check_outputs;
    begin
      fd = $fopen(output_file, "w");
      if (!fd) $fatal(1, "Cannot open output tensor");
      $fdisplay(fd, "// shape=(%0d,%0d,%0d,%0d), last coordinate varies fastest, hex", N, K, P, Q);
      for (a = 0; a < output_words; a = a + 1) begin
        if ($isunknown(expected[a]) || $isunknown(memory[output_base + a]) ||
            memory[output_base + a] !== MEM_DATA_WIDTH'($unsigned(expected[a])))
          $fatal(1, "Layer output %0d mismatch: want=%h got=%h", a, expected[a], memory[output_base + a]);
        $fdisplay(fd, "%h", memory[output_base + a][ACC_WIDTH - 1:0]);
      end
      $fclose(fd);

      fd = $fopen(layout_file, "w");
      if (!fd) $fatal(1, "Cannot open memory report");
      $fdisplay(fd, "Backing memory: input_base=%0d kernel_base=%0d output_base=%0d", input_base, kernel_base, output_base);
      for (a = 0; a < output_words; a = a + 1)
        $fdisplay(fd, "addr=%0d value=%h", output_base + a, memory[output_base + a]);
      $fclose(fd);

      $display("[METRIC] Layer cycles (start accepted to final store done): %0d", clock_cycles - start_cycle);
      $display("[METRIC] Backing reads: %0d; writes: %0d", reads, writes);
      $display("PASS: %0d outputs matched for one completed layer", output_words);
    end
  endtask

  // Load one layer and initialise the backing input/kernel tensors.
  initial begin
    input_file = "sim/input_tensor.txt";
    kernel_file = "sim/kernel_tensor.txt";
    output_file = "sim/output_tensor_accelerator.txt";
    layout_file = "sim/sram_layout.txt";
    wave_file = "";
    if ($value$plusargs("INPUT_FILE=%s", input_file)) begin end
    if ($value$plusargs("KERNEL_FILE=%s", kernel_file)) begin end
    if ($value$plusargs("OUTPUT_FILE=%s", output_file)) begin end
    if ($value$plusargs("SRAM_LAYOUT_FILE=%s", layout_file)) begin end
    if ($value$plusargs("WAVE_FILE=%s", wave_file)) begin end
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
    if (N < 1 || C < 1 || K < 1 || H < 1 || W < 1 || R < 1 || S < 1 ||
        stride_i < 1 || stride_j < 1 || dilation_i < 1 || dilation_j < 1 ||
        pad_i < 0 || pad_j < 0)
      $fatal(1, "Invalid layer configuration");
    if (longint'(dilation_i) * (R - 1) + 1 > longint'(H) + 2 * pad_i ||
        longint'(dilation_j) * (S - 1) + 1 > longint'(W) + 2 * pad_j)
      $fatal(1, "Kernel does not fit padded input");
    P = (longint'(H) + 2 * pad_i - longint'(dilation_i) * (R - 1) - 1) / stride_i + 1;
    Q = (longint'(W) + 2 * pad_j - longint'(dilation_j) * (S - 1) - 1) / stride_j + 1;
    if (P < 1 || Q < 1 || longint'(N) * C * H * W + longint'(K) * C * R * S + longint'(N) * K * P * Q + 32 > MEM_DEPTH)
      $fatal(1, "Layer exceeds testbench backing memory");

    // Lay out the three tensors in separate regions of backing memory.
    input_words = N * C * H * W;
    kernel_words = K * C * R * S;
    output_words = N * K * P * Q;
    input_base = 8;
    kernel_base = input_base + input_words + 8;
    output_base = kernel_base + kernel_words + 8;
    read_tensor(input_file, 0, N, C, H, W);
    read_tensor(kernel_file, 1, K, C, R, S);
    build_reference;
    for (a = 0; a < input_words; a = a + 1)
      memory[input_base + a] = MEM_DATA_WIDTH'($unsigned(input_tensor[a]));
    for (a = 0; a < kernel_words; a = a + 1)
      memory[kernel_base + a] = MEM_DATA_WIDTH'($unsigned(kernel_tensor[a]));
    if (wave_file != "") begin
      $dumpfile(wave_file);
      $dumpvars(0, tb_conv_accelerator);
    end
    repeat (2) @(negedge clk);
    nrst = 1;

    // Launch once. The accelerator performs every tile load, compute and store.
    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;

    wait (done);
    #1;  // Observe final memory writes after nonblocking assignments commit.
    check_outputs;
    $finish;
  end

  // Bound a stalled demonstration without driving any additional stimulus.
  initial begin
    wait (nrst);
    repeat (1000 + 100 * longint'(N) * K * P * Q * C * R * S + 20 * longint'(N) * C * H * W)
      @(posedge clk);
    $fatal(1, "Accelerator watchdog: layer did not finish");
  end
endmodule
