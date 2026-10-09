# Ocula: instructions for contributors and agents

Ocula is the image layer of the AMAGE UI ecosystem, implemented in **Bend 2**:
reading and decoding image formats into pixels, transparency, and the color
information that drawing needs. Read the README for current capabilities and
limits; a roadmap item is not implemented merely because it appears in the
project scope.

## Implementation

- Implement library logic in Bend 2, rather than wrapping an existing image
  library (libpng, zlib, stb_image, ImageMagick, ...).
- Treat every file as untrusted input. Validate lengths, dimensions, and
  indices before allocating or reading, bound every loop, and reject unsupported
  features explicitly instead of guessing.
- Keep the public pixel format (`0xRRGGBBAA`, straight alpha, sRGB) stable and
  documented. Any color conversion must be explicit.
- External tools may generate fixtures or serve as an independent oracle in
  `tools/`; they never take part in decoding.
- The official Bend compiler/runtime, OS APIs, and drivers remain external
  dependencies. Keep any future native bridge minimal, explicit, and separate.
- Before writing Bend, run `bend version` and read `bend guide` from the installed
  toolchain. Verify available syntax/effects instead of assuming old examples work.
- Keep source, comments, documentation, and commit messages in English.

## Writing fast Bend

Correct Bend is not fast Bend by default. Measured rules (Bend 2.0.35):

- Indexed, large or hot data (bytes, pixels, coverage, quads) lives in an
  `Array<U32>` (native flat block, ~1 ns/read), not a `List`. Lists are fine
  when tiny, built once and consumed in order. Arrays are affine and cannot be
  fields of `Data` types: keep them local and convert once at the boundary.
- No `do Result`/`do Maybe` binds or callbacks per byte, pixel or glyph: each
  bind is a closure (45% of a measured profile). Thread state through one
  recursive def that matches on the result.
- `||`, `&&` and `Bool.pick` evaluate both sides; use `match` to stop early.
- Never `Array.clone` or append (`List.append`) in a loop; build with a
  reversed accumulator or a tail parameter.
- A parameter that a def only matches or passes to itself is borrowed (no
  refcount); descend trees with the selector as a parameter.
- Keep non-recursive records small (they are passed flattened; the widest one
  widens every call frame). Box big ones with an `Alias{x: T}` constructor.
- Split independent, balanced work of tens of µs or more with a parallel call
  (`a b = f(l) g(r)`); never parallelize tiny or IO-bound work.
- Measure before and after on the same input; print a result before the next
  `IO.now()`.

Here: inflate, unfilter and packing touch every byte, so they run on arrays
with lookup tables and no closures or `Result` per byte. That took kitty.png
from 49 to ~2 ms per decode (`examples/bench.bend`). Keep validation, but check
once before a loop that provably covers it and say so in a comment. Rows
depend on the row above, so unfiltering stays sequential.

## Linux first

The initial goal is excellent behavior on Ian's actual Linux development machine:
real images loaded and shown with correct dimensions, colors, and transparency,
within the supported formats. Inspect the effective environment before choosing
integrations.

Build compatibility layers as the project progresses, after visible, well-made
Linux results. Do not let speculative Windows or macOS abstractions delay local
quality. Introduce abstractions from concrete needs.

## Working practice

- Preserve existing work and keep the library's boundary clear: drawing and
  composition belong to Chromi. Siblings import Ocula by relative path;
  coordinate API changes with them.
- Favor simple, maintainable code. Back performance claims with measurements.
- Run the native checks and the oracle after changes. Never remove a fixture to
  make a run pass.
- Compilation is not visual proof. Runtime checks are not proofs of the entire
  system. State partial support and unverified behavior explicitly.
- Build sequentially. Do not impose virtual-address limits on the Bend runtime
  or suppress crash reporting. Investigate failures before retrying.
- Keep generated binaries, decoder outputs, logs, crash dumps, credentials, and
  machine-specific evidence out of Git. Stage explicit paths and preserve
  concurrent changes.

See [CONTRIBUTING.md](CONTRIBUTING.md) for validation commands.
