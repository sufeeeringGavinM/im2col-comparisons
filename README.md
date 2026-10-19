# Convolution implementations

This collection contains three hardware-tiled designs and five local-memory-only designs. The systolic arrays use 8-bit signed inputs/weights and 32-bit accumulation.

```text
tiled/
  NHWC/
  NCHW_centralized/
  NCHW_per_row/
nontiled/
  NHWC/
  NCHW_centralized/
  NCHW_per_row/
  explicit/
  im2collette_fifo/
tools/
  NHWC.html
  NCHW.html
  explicit_simulator.html
  im2collette_simulator.html
```

## Use an implementation

Each implementation folder is standalone and contains its own README, RTL, testbench, sample tensors and Python runner. Install Python 3 and Icarus Verilog (`iverilog` and `vvp` on PATH), then run from that folder:

```text
python run_case.py --input-file sim/input_tensor.txt --kernel-file sim/kernel_tensor.txt --out-dir runs/example
```

See the implementation README for tensor formatting, dimensions, convolution settings and memory limits.

## Explore interactively

Open an HTML file in `tools/` directly in a browser. These visualizations are independent of the Python/RTL runners.

## Terminology

Channel-first unrolling maps input channels to array rows (the NHWC implicit design). Channel-last unrolling maps consecutive CRS reduction terms to rows (the NCHW implicit designs). All supplied tensor files nevertheless use NCHW inputs, KCRS kernels and NKPQ outputs.
