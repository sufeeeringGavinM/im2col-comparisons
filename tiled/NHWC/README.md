# NHWC implicit convolution with hardware tiling

Input channels map to array rows and output channels to columns. A shared address generator streams one kernel tap at a time; tap results accumulate in output SRAM. No expanded im2col matrix is stored.

This design computes signed 2-D cross-correlation: kernels are not reversed. It supports batching, independent height/width padding, stride and dilation. There is no bias or activation function. The simulation runner selects a 10×10 array, 8-bit inputs/weights, 32-bit accumulated results and 32-bit configuration fields. Each PE has two stationary weight registers.

## Hardware tiling

`conv_accelerator` schedules local convolution jobs, transfers input/kernel tiles, preserves partial sums across reduction tiles, and stores completed outputs. Its backing-memory model is in `sim/tb_conv_accelerator.v`; it is not an external-memory controller or AXI interface. The supplied testbench has 65,536 backing-memory words, including input/kernel/output regions and separators. Local SRAM is 15 KiB: 2.5 KiB activations, 2.5 KiB kernels and 10 KiB partial sums.

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

`conv_accelerator` is the hardware top; its local engine is `conv_core`. `conv_core`, `conv_controller`, `conv_datapath`, `im2col_addr_gen`, `activation_feeder`, `systolic_array`, `PE`, `weight_loader`, and SRAM/output-accumulation modules. The `rtl/` directory contains hardware; `sim/` contains the testbench and sample tensors. `gen_matrices.py` generates fixtures; `conv_golden.py` contains the reference convolution. Functional simulation does not establish FPGA timing closure or measured power.

## Credits

Original systolic-array foundation: https://github.com/kaggar11/systolic_4x4arr . Algorithmic reference: Zhou et al., *Characterizing and Demystifying the Implicit Convolution Algorithm on Commercial Matrix-Multiplication Accelerators*, https://doi.org/10.48550/arXiv.2110.03901 . The course material and reference-model attribution are retained in `conv_golden.py`.

AI assistance: Codex and GPT-6.1 Sol contributed to the project and Python tooling.
