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
