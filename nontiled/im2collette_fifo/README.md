# On-the-fly convolution — im2collette

The address generator prepares up to eight output positions for one kernel tap. Each feed lane retains a 64-bit activation SRAM word and collects all requested values from it into a packet, inserting zeros for padding. The producer collects a synchronous SRAM return while issuing the next missing word address; a bypass feeds the returned data directly into the packet selectors. Completed packets enter a FIFO and stream one activation per channel into the systolic array. BUS_WORDS=8. Packet preparation overlaps consumption and weight loading. The producer runs at most one tap ahead, keeping next-tap packets behind current-tap packets in the existing queues; full queues pause the producer, and missing data holds the array, activation skew and output writeback together.

This design computes signed 2-D cross-correlation: kernels are not reversed. It supports batching, independent height/width padding, stride and dilation. There is no bias or activation function. The simulation runner selects a 10×10 array, 8-bit inputs/weights, 32-bit accumulated results and 32-bit configuration fields. Each PE has two stationary weight registers.

## Local memory and layer limits

There is no tile scheduler. Inputs, weights and outputs must fit local memory. Base SRAM is 15 KiB: ten 256-byte activation banks, ten 256-byte kernel banks, and ten 256-word 32-bit output banks. The runner enforces `C,K <= 10`, `C*R*S <= 256`, and `N*P*Q <= 256`. Input storage additionally requires `N*H*W <= 256` values per input channel. Each activation bank is 32×64 bits. Each of the ten FIFOs holds two packets of up to eight 8-bit activations: 16 activation slots per channel, with a valid-count field per packet. Packet payload queues use 160 bytes in total (170 bytes including valid-count fields); assembly and retained-word registers add 80 bytes each, plus control/count bits and activation-skew registers. These buffers are additional to the 15 KiB SRAM. Packet boundaries do not drain or restart the array. Packet queues survive kernel-tap switches; only the compute pass and activation skew reset. Two shared 32-bit producer tap coordinates add eight bytes of control registers; no packet or SRAM capacity is added.

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

The output directory contains `output_tensor.txt`, `expected_python.txt`, `input_used.txt`, `kernel_used.txt`, `result.json`, simulator logs and an SRAM-layout dump. `result.json` also retains `[CYCLES]` phase counts and `[PACKETS]` read, activation, queue and overlap counts, plus `[PIPELINE]` request/return overlap and returned-word collection counts and `[PREFETCH]` next-tap read/packet and ready-start counts. Use `--wave-file trace.vcd` to save waveforms. Omit input/kernel options to generate a repeatable random example using `--seed`. Run `python run_case.py --help` for all options.

## RTL and simulation

`conv_core` is the hardware top. `conv_core`, `conv_controller`, `MMU`, `im2col_addr_gen`, `channel_bank`, `feed_lane`, `sync_fifo`, `systolic_array`, `pe`, and weight/output-storage modules. The `rtl/` directory contains hardware; `sim/` contains the testbench and sample tensors. `gen_matrices.py` generates fixtures; `conv_golden.py` contains the reference convolution. The pipelined packet feeder with next-tap prefetch was validated on 37 directed/random/regression cases, checking 16,785 output words and every consumed activation. This includes all 34 earlier cases plus one-output taps, an array hold with prefetch active, and reset during an in-flight next-tap read. The supplied-tensor runner also passes its 32-output integration case. Across the same 17 presentation layers, prefetch reduces total cycles from 9,393 to 8,829 (6.00%) and execution stalls from 564 to zero, matching NHWC's cycles on every presentation layer. All 128 later-tap starts have data ready. The two-packet configuration matches the eight-packet cycle counts across all 39 depth-sweep workloads, including two additional eight-word-read pressure cases. It reduces FIFO payload from 640 to 160 bytes across ten channels; assembly and retained-word storage are unchanged. This is a tested minimum for that suite, not a guarantee for every supported geometry. Per-case bank read counts are unchanged: 45,313 valid values from 9,762 enabled reads across the 37-case prefetch suite. The capacity baseline remains at 287 cycles and eight values/read. See `reports/depth_validation.json` for the two-packet sweep results and scope, and `reports/prefetch_validation.json` for the earlier eight-packet prefetch validation; `reports/pipeline_validation.json` and `reports/packet_validation.json` retain the earlier versions' results. The packaged two-packet default also passes three integration checks (supplied tensors, a 3×3 multi-tap layer, and eight-word-read pressure), checking 2,312 output values. These synthetic local-core results do not guarantee stall-free operation on every geometry.

The inherited `.rpt` files in `reports/` describe the earlier scalar-FIFO implementation; they were not regenerated for this change. Functional simulation does not establish FPGA timing closure or measured power.

## Credits

im2collette source: https://github.com/ckmalangen/im2collette .

Packet-feeder changes were developed with Codex assistance. The design keeps the existing weight-stationary channel mapping; it is inspired by, rather than a reproduction of, the output-stationary feeder in Fornt et al., *An Energy-Efficient GeMM-based Convolution Accelerator with On-the-fly im2col*, https://doi.org/10.1109/TVLSI.2023.3286122 . Original reference-model and course material are retained.
