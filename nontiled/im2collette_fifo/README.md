# On-the-fly convolution — im2collette

The address generator selects one byte from each 64-bit activation SRAM word. A small FIFO in each feed lane supplies the corresponding PE row. BUS_WORDS=8; the FIFO is connected and its additional pipeline latency is included.

This design computes signed 2-D cross-correlation: kernels are not reversed. It supports batching, independent height/width padding, stride and dilation. There is no bias or activation function. The simulation runner selects a 10×10 array, 8-bit inputs/weights, 32-bit accumulated results and 32-bit configuration fields. Each PE has two stationary weight registers.

## Local memory and layer limits

There is no tile scheduler. Inputs, weights and outputs must fit local memory. Base SRAM is 15 KiB: ten 256-byte activation banks, ten 256-byte kernel banks, and ten 256-word 32-bit output banks. The runner enforces `C,K <= 10`, `C*R*S <= 256`, and `N*P*Q <= 256`. Input storage additionally requires `N*H*W <= 256` values per input channel. Each activation bank is 32×64 bits. Each of the ten FIFOs holds eight 8-bit activations; its role in the fixed schedule is mainly pipeline alignment, not full upstream backpressure. 

## Requirements

- Python 3, standard library only.
- Icarus Verilog: both `iverilog` and `vvp` must be installed and available on PATH.

The implementation folder can be copied and run independently. No browser files or parent-folder tools are required for RTL simulation. Advanced tool locations can be set with `IVERILOG_BIN`, `VVP_BIN`, and, for an extracted Linux installation, `IVERILOG_BACKEND`.

## Run supplied tensors

Open a terminal in this folder:

```text
python run_case.py --input-file sim/input_tensor.txt --kernel-file sim/kernel_tensor.txt --expected-file sim/output_tensor.txt --out-dir runs/example
```

Use `python3` instead of `python` where appropriate. Replace the input/kernel paths with your own files. `--expected-file` is optional: a Python golden result is always calculated and checked. The Verilog testbench also computes and checks its own reference result. Supplied tensors are not regenerated or overwritten.

### Tensor format

Input shape is `(N,C,H,W)`, kernel shape `(K,C,R,S)`, and output shape `(N,K,P,Q)`, with the rightmost index varying fastest. This file order does not change with the internal SRAM layout. Inputs/weights are whitespace-separated hexadecimal 8-bit bit patterns: `7f`=127, `80`=-128, `ff`=-1. Comments begin with `//`. Output words are 32-bit hexadecimal values.

A shape header is optional:

```text
// shape=(1,4,6,6)
45 57 94 04 78 4f
```

With headers, tensor dimensions are detected automatically. Without them, supply `--N`, `--C`, `--H`, `--W`, `--K`, `--R`, and `--S`. Set geometry with `--pad_i`, `--pad_j`, `--stride_i`, `--stride_j`, `--dilation_i`, and `--dilation_j`; defaults are zero padding, unit stride and unit dilation.

### Output files

The output directory contains `output_tensor.txt`, `expected_python.txt`, `input_used.txt`, `kernel_used.txt`, `result.json`, simulator logs and an SRAM-layout dump. Use `--wave-file trace.vcd` to save waveforms. Omit input/kernel options to generate a repeatable random example using `--seed`. Run `python run_case.py --help` for all options.

## RTL and simulation

`conv_core` is the hardware top. `conv_core`, `conv_controller`, `MMU`, `im2col_addr_gen`, `channel_bank`, `feed_lane`, `sync_fifo`, `systolic_array`, `pe`, and weight/output-storage modules. The `rtl/` directory contains hardware; `sim/` contains the testbench and sample tensors. `gen_matrices.py` generates fixtures; `conv_golden.py` contains the reference convolution. Functional simulation does not establish FPGA timing closure or measured power.

## Credits

im2collette source: https://github.com/ckmalangen/im2collette .
