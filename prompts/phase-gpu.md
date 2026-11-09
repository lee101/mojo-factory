GPU phase for the Mojo port __SLUG__ of the Python package __PKG__.

Goal: a GPU path for kernels that are compute-heavy enough to pay for the transfer.

READ FIRST: `MOJO_NOTES.md` section 5 for the GPU API on this toolchain, then
`bench/analysis.md`.

GATE BEFORE ANY GPU WORK
- Only kernels above roughly 2 flops per byte in `bench/analysis.md` are candidates. Below
  that, write "CPU only: memory-bound" in the README and stop.
- Check the shared GPU with `nvidia-smi --query-gpu=memory.free --format=csv,noheader`.
  If it reports under 4000 MiB free, skip this phase and say so in the README.
- Keep device allocations under 2 GB.

RULES
- Use `DeviceContext` from `max.gpu.host` and `block_idx`/`thread_idx` from `max.gpu`.
  Check `MOJO_NOTES.md` for the exact import paths.
- One kernel launch per call, not one per element.
- Copy inputs to the device once, launch, and copy results back once. Do not re-upload
  inside a loop.
- The grid must cover the whole input. Handle the tail explicitly and test it.
- Keep the CPU path. It is the fallback when no device is present. Tests that need a GPU
  must skip cleanly on a CPU-only host, and the README must say they were skipped.
- Measure at the sizes real callers use. If the GPU wins only above a size nobody passes,
  say that. If it loses, revert it and say that.
- Record before and after numbers in the README. No invented numbers.
- Finish with `pixi run build && pixi run test` both green.
