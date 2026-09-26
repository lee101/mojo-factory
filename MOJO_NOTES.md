# Mojo dialect notes (verified by probe against the pinned compiler, not by docs)

Toolchain these notes describe: `mojo ==1.1.0.dev2026081105`.
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

## 4. Parallelism — REMOVED from the stdlib

`parallelize` **does not exist** in this toolchain. It is not in `std.algorithm`
(that module no longer even exports `sort`), not a builtin, and there is no
`std.parallelism` / `std.threading`. The compiler offers no "did you mean" hint
for it, which means it was removed rather than moved.

Consequence: a port that parallelised on the CPU must either
(a) keep the work serial and say so honestly in its benchmark table, or
(b) find the replacement in the `max` package and verify it compiles.
Do NOT write `from std.algorithm import parallelize` and assume it works.

## 5. GPU — host API not present in the stdlib

- `from std.gpu import thread_idx` **works**.
- `from std.memory import stack_allocation` resolves, but its signature does not
  match the old `stack_allocation[T](n)` form — check it by compiling.
- **`DeviceContext` does not exist**: not in `std.gpu.host`, not in `std.gpu`, and
  the compiler has no replacement to suggest. `ctx.enqueue_create_buffer`,
  `enqueue_copy`, `enqueue_function` and `synchronize` are therefore unavailable
  too. The `max` package ships GPU sources under
  `site-packages/max/sys/_hal/`; look there if you need a device path.

Practical rule: a GPU path is only worth writing if you can compile and run it.
Otherwise state in the README that the port is CPU-only and why. The GPU is shared
with production workloads — see the memory limits in `prompts/accel.md`.

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
