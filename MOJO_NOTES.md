# Mojo 1.0 nightly dialect notes (verified by probe, not docs)

Pinned toolchain: `mojo ==1.0.0b3.dev2026072406` from `https://conda.modular.com/max-nightly`.

## Export / FFI
- Export syntax: `@export("symbol_name")` on the line above the def. The ABI is an
  *effect* before the arrow: `def f(a: Int) abi("C") -> Float64:`.
  Omitting `abi("C")` only warns; putting it after the return type is a parse error.
- `@export` rejects parametric functions. Any inferred parameter — including a
  pointer origin (`UnsafePointer[Float64, _]`) — makes it parametric.
- The only usable mutable origin name is `AnyOrigin[mut=True]`.
  `MutableAnyOrigin` / `MutableStaticOrigin` / `StaticMutableOrigin` do not exist;
  bare `AnyOrigin` is parametric over `mut`; `ImmStaticOrigin` rejects stores.
- Buffers therefore cross the C ABI as `Int` addresses, rebuilt inside the wrapper:
  `UnsafePointer[Float64, AnyOrigin[mut=True]](unsafe_from_address=addr)`.
- Pointers are NON-NULLABLE: constructing from address 0 fails a compile-time
  constraint. Pass the address as `Int` and construct only inside the branch that uses it.
- An `@export ... abi("C")` function cannot be `raises`; wrap fallible work in
  `try:` / `except:` inside it.
- `out` is a reserved word — not usable as a parameter name *or* a local variable name.

## Language
- `comptime Ptr = UnsafePointer[...]` works as a type alias; `comptime W = 4` as a SIMD width.
- `p.load[width=W](i)` / `p.store(i, vec)` / `vec.reduce_add()` work.
- `SIMD` has no `.min()` / `.max()` methods; use the free `min(a, b)` / `max(a, b)`.
- `ord("=")` yields `Int` and will not implicitly convert to `UInt8`.
- stdlib is namespaced under `std.` (e.g. `from std.gpu.host import DeviceContext`).

## Build
- `mojo build --emit shared-lib` errors if the file defines `main`, and errors if the
  `-o` directory does not already exist.
- Build cost is ~2-5s and essentially FIXED regardless of function count (1 fn 5.17s,
  20 fns 4.96s). Optimization level barely matters. Batch many functions into ONE
  compilation unit rather than compiling files separately.
- `mojo run` JITs in ~1.2s per invocation; a built shared lib + ctypes call is ~0.9us.

## GPU
- CONFIRMED WORKING on this machine's RTX 5090 (sm_120 / cc 12.0) with the plain `mojo`
  1.0.0b2 package — probe compiled, launched a kernel and passed a host/device parity
  check on 2026-07-29. The `max` conda package was NOT required; the installed `mojo`
  already ships the `std.gpu` host API and runtime. Try without `max` first.
  `from std.gpu.host import DeviceContext`, `from std.gpu import thread_idx`.
- Per-thread scratch (e.g. a traversal stack) comes from
  `from std.memory import stack_allocation`, indexed by `thread_idx.x`. Do not malloc
  per thread. Guard for overflow with a brute-force fallback path rather than UB.
- `DeviceContext()` raises, so wrappers need `try:` / `except:`.
- `ctx.enqueue_create_buffer[DType.float64](n)`, `ctx.enqueue_copy(dst, src)` (either
  direction, device buffer or raw host pointer),
  `ctx.enqueue_function[kernel](args, grid_dim=..., block_dim=...)`, `ctx.synchronize()`.
- GPU only wins at high arithmetic intensity; below ~2 flops/byte it loses to CPU at
  every array size. Measure before claiming a speedup.

## wasm (only if the port targets the browser)
- Mojo's LLVM has no wasm backend registered. Path is: `mojo build --emit llvm` ->
  rewrite datalayout/triple + strip target-cpu/features -> `clang>=20 --target=wasm32`
  -> `wasm-ld`. Export params must be `Int32` (`Int` is i64 -> BigInt in JS).
