# Interactive convolution simulators

Open these HTML files directly in a browser:

- [NHWC.html](NHWC.html): channel-first-unrolling implicit convolution with tile scheduling.
- [NCHW.html](NCHW.html): channel-last-unrolling implicit convolution with tile scheduling.
- [explicit_simulator.html](explicit_simulator.html): explicit im2col visualization.
- [im2collette_simulator.html](im2collette_simulator.html): im2collette visualization.

The files are self-contained; no web server is required. They are visual/educational models, not HDL simulation engines. Defaults and modeled details can differ from a particular RTL build; use each implementation's Python runner to check its RTL against reference results. The HTML files retain their original credits and contents.
