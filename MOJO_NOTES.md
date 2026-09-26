# Mojo dialect notes (verified by probe against the pinned compiler, not by docs)

Toolchain these notes describe: `mojo ==__MOJO_PIN__` (set in `MOJO_PIN` in
`bin/port.sh`; every repo receives this file with the marker already substituted).
Every claim below was checked by compiling it. `bin/probe-confirm.py` and
`bin/probe-hints.py` in the factory regenerate the list; re-run them after any
toolchain bump rather than trusting this file.

## 0. Two things that break everything if you forget them

- **`MODULAR_HOME` must point at the env's `share/max`.** Without it every import
  fails with `unable to locate module 'std'`, which looks like a missing package
  but is not. `pixi run` sets it for you. A bare `mojo build` does not:
  ```bash
  export MODULAR_HOME="$(dirname "$(dirname "$(which mojo)")")/share/max"
  ```
- **`mojo build -o` takes an output FILE path**, not a directory. A directory there
  fails late, at link time, with `ld: cannot open output file ... Is a directory`.

## 1. Language changes from the 0.x/1.0 dialect

- **`fn` has been removed. Use `def` for everything.** `fn` is a hard error:
  `'fn' has been removed; use 'def' instead`.
- `UnsafePointer` is deprecated in favour of **`Pointer`**. It still compiles, with
  a warning, so old code builds — but write `Pointer[T, AnyOrigin[mut=True]]`.
- `int(x)` / `float(x)` are **not builtins**. Use the type as a constructor:
  `Int(x)`, `Float64(x)`. There is no `.to_int()`, `.int()`, or `round(x).to_int()`.
- `simdwidthof[DType.float64]()` is gone. It is now
  `from std.sys import simd_width_of` then `simd_width_of[DType.float64]()`.
  A hardcoded `comptime W = 4` is always valid and is often the better choice.
- `SIMD` has no `.min()` / `.max()` methods. The free `min(a, b)` / `max(a, b)`
  work on both scalars and `SIMD` values.

## 2. Export / FFI

- `@export("symbol_name")` sits on the line above the def. The ABI is an *effect*
  before the arrow: `def f(a: Int) abi("C") -> Float64:`.
- **`@export` now REQUIRES an explicit `abi()`.** Omitting it is an error:
  `@export requires an explicit 'abi()' effect on the function`. This is stricter
  than 1.0, where it only warned.
- An `abi("C")` function **may not be `raises`**. Put the fallible work in a
  `try:` / `except:` inside the body instead.
- `@export` rejects parametric functions, including an inferred pointer origin
  (`Pointer[Float64, _]`). Annotate the origin explicitly.
- Buffers cross the C ABI as **`Int` addresses**, rebuilt inside the wrapper:
  ```mojo
  var q = Pointer[Float64, AnyOrigin[mut=True]](unsafe_from_address=addr)
  ```
- Pointers are NON-NULLABLE: constructing one from address 0 fails a compile-time
  constraint. Take `Int` and construct inside the branch that uses it.
- `AnyOrigin[mut=True]` is the only usable mutable origin name. `MutableAnyOrigin`
  and friends do not exist.

## 3. Memory and SIMD (all verified working)

```mojo
comptime Ptr = Pointer[Float64, AnyOrigin[mut=True]]
comptime W = simd_width_of[DType.float64]()

var i = 0
while i + W <= n:                      # vector body
    p.store(i, p.load[width=W](i) * 2.0)
    i += W
while i < n:                           # scalar tail
    p.store(i, p.unsafe_load(i) * 2.0)
    i += 1
```
- `p.load[width=W](i)` / `p.store(i, v)` / `v.reduce_add()` all work.
- `p.unsafe_load(i)` for a scalar load; `p.unsafe_offset(i)[]` also works.
- Positional `p[i]` still compiles but warns; prefer `unsafe_load`.

## 4. Parallelism — moved from `std` to `max`

`parallelize` is NOT gone. It moved package. On 1.2.0:

| import | result on 1.2.0 |
| --- | --- |
| `from max.algorithm import parallelize` | **WORKS** — this is the live path |
| `from max.algorithm import sync_parallelize` | **WORKS** |
| `from std.algorithm import parallelize` | `package 'algorithm' does not contain 'parallelize'` |
| `from std.algorithm.functional import parallelize` | gone |
| `from std.sys import parallelize` / `spawn` | `package 'sys' does not contain ...` |
| `from std.threading import ...` | `unable to locate module 'threading'` |
| `from std.algorithm import sort` | `package 'algorithm' does not contain 'sort'` |

`std.algorithm` no longer exporting `sort` is the tell: the `std` module was gutted
while the capability moved to `max`. So a port is parallelisable — just not through
the old import. Verified by building `mojo-anndata` on 1.2.0: its
`from max.algorithm import parallelize` compiles and the port builds.

`max.parallel` and `max.core` do NOT exist; `max.algorithm` is the one.

Do NOT write `from std.algorithm import parallelize` — it does not compile. If a
port is serial where it could be parallel, that is a real gap, not a toolchain
excuse; use the `max` form behind a size threshold and prove it with the benchmark.

## 5. GPU — the host API moved from `std.gpu` to `max.gpu`

Same story as parallelism. The `std.gpu` module is gone entirely
(`unable to locate module 'gpu'`), so `from std.gpu import thread_idx` no longer
resolves — but the capability is not gone with it:

```mojo
from max.gpu import block_idx, thread_idx      # WORKS
from max.gpu.host import DeviceContext         # WORKS
```

and the full host surface is present and compiles on 1.2.0:

- `ctx.enqueue_create_buffer[DType.float64](count)`
- `ctx.enqueue_copy(dst, src)`
- `ctx.enqueue_function[kernel](...)`
- `ctx.synchronize()`
- `ctx.name()`

`DeviceContext()` construction needs a `raises` context (`def main() raises:`), and
`DeviceContext` is not `Writable`, so do not `print` it. There is no
`ctx.devices()`; enumerate through the `max.gpu` module instead.

Verified end to end: `mojo-numba` and `mojo-imagehash` carry working `max.gpu.host`
GPU paths and both build on 1.2.0.

- `from std.memory import stack_allocation` resolves, but the old
  `stack_allocation[T](n)` form does NOT: it fails with
  `no matching function in call to 'stack_allocation'`. Check the signature by
  compiling rather than assuming the historic shape.

Practical rule: a GPU path is only worth shipping if you can compile AND run it,
and the rules in `prompts/accel.md` about launch count, single copy-in/copy-out and
tail coverage all still apply. The GPU is shared with production workloads — see
the memory limits there. A CPU-only port is a legitimate answer when a kernel is
below roughly 2 flops per byte, but "the host API is missing" is NOT a valid
reason: it is in `max`, and 28 ports already use it.

## 6. Build

- Build cost is ~2-5s and essentially FIXED regardless of function count. Batch
  many functions into ONE compilation unit rather than compiling files separately.
- `mojo run` JITs in ~1.2s per invocation; a built shared lib + ctypes call is ~0.9us.
- `mojo build --emit shared-lib` errors if the file defines `main`.

## 7. Diagnosing a moved symbol

Do not guess module paths. A bare unknown name makes the compiler name the module
it expected:

```mojo
def _p() -> Int:
    return simd_width_of[DType.float64]()   # -> "did you mean to import it from 'std.sys'?"
```
No hint means the symbol is gone, not relocated. `bin/probe-hints.py` automates this.
