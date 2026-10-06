# Ocula

**A PNG decoder written in Bend 2, from zlib/DEFLATE to RGBA pixels.**

Ocula is the image layer of the AMAGE UI ecosystem. It decodes PNG files into
straight-alpha RGBA8 rasters for the renderer. Chunk parsing, CRC-32, zlib,
DEFLATE (stored, fixed, and dynamic Huffman), Adler-32, and scanline filters
are all implemented in Bend 2, without libpng, zlib, or any hand-written native
code.

**Status:** early Linux implementation, tested with **Bend 2.0.35**. It decodes
8-bit RGB and RGBA, non-interlaced, and rejects everything else explicitly. It
is not a decoder for every PNG.

## What works today

- Color type 2 (RGB) and 6 (RGBA) at bit depth 8, without interlacing.
- A single leading `IHDR`, consecutive `IDAT` chunks (including empty ones), and
  an empty final `IEND`. Data after `IEND` or after the zlib stream is rejected.
- CRC-32 checked on **every** accepted chunk, Adler-32 checked on the
  decompressed data, and the decompressed length must match the scanlines exactly.
- DEFLATE stored, fixed, and dynamic Huffman blocks, code-length repeats, and
  overlapping LZ77 copies. End-of-block, invalid trees, reserved symbols,
  stored-length complements, lengths, and distances are validated before any
  array access.
- Filters None, Sub, Up, Average, and Paeth, in modulo-256 arithmetic.
- Accepted ancillary chunks: a validated optional `PLTE` for truecolor (pixels
  unchanged), `sRGB` with rendering intent 0–3, `gAMA` 45455 **together with**
  `sRGB`, and a valid `pHYs` before `IDAT`. A PNG with no color information is
  interpreted as sRGB; there is no color management.

The native suite has **101 checks**: CRC and Huffman edge cases, LZ77
back-references, pixel bounds, array capacity, channel order, file reads up to
EOF and the size limit, **34 generated PNGs** compared with their source pixels
(RGB/RGBA, every filter, first row and first pixel, width 1, split `IDAT`,
stored/fixed/dynamic blocks, overlapping copies), and **41 invalid files**
rejected (truncation, CRC/Adler errors, headers, dimension and allocation
limits, filters, zlib/DEFLATE errors, unsupported features).

An external oracle also decoded four real PNGs from `/usr/share/pixmaps`
(`filezilla.png` 48×48, `kitty.png` 256×256, `nvim.png` 128×128,
`helium-browser.png` 256×256), without prior conversion, and every pixel matched
ImageMagick's output. Through the sibling Splina demo, the Kitty icon was drawn
in a real window and the captured 256×256 region matched an independent
composition exactly, including 1445 partially transparent pixels.
See [docs/validation.md](docs/validation.md).

## Quick start

Requirements: the [Bend 2 toolchain](https://bend-lang.com) and Clang 14 or
newer. Ocula has no sibling dependencies.

```sh
git clone https://github.com/amage-si/ocula.git Ocula
cd Ocula
export BEND_NO_TELEMETRY=1
bend version
mkdir -p build
bend tests.bend -o build/tests
./build/tests --threads 2 --gpu off
```

Run the tests from the repository root: they read `fixtures/` by relative path.

Decode a PNG into raw RGBA bytes:

```sh
bend examples/decode.bend -o build/decode
./build/decode --threads 2 --gpu off fixtures/random-00.png build/random-00.rgba
# RGBA8 <width> <height>
cmp build/random-00.rgba fixtures/random-00.rgba
```

An invalid or unsupported file exits with code 1 and a message.

## Using the API

```bend
import Base
import ../Ocula/main.bend as O
import ../Ocula/pixels.bend as P
import ../Ocula/file.bend as F

bytes : +List<U32> <- F.read("image.png")
O.decode_png(bytes) -> Result<&2, &1, String, P.Raster>
```

`Raster{width, height, pixels}` holds `0xRRGGBBAA` values, straight alpha,
sRGB, left to right and top to bottom. Only the first `width × height` entries
of `pixels` belong to the image: the array's capacity is rounded up to a power
of two. `P.packed_pixels(raster)` returns exactly those pixels (for Chromi's
`blit_rgba`), and `P.rgba_bytes(raster)` serializes them as R, G, B, A bytes.
Read the [API reference](docs/api.md) for ownership, limits, and errors.

## Current boundaries

Rejected explicitly: grayscale and indexed color, bit depths 1/2/4/16, Adam7
interlacing, APNG, `tRNS`, zlib preset dictionaries, zlib windows other than
32 KiB (even when valid), `iCCP`/`cHRM`/`cICP`, gamma other than the sRGB value
or without `sRGB`, text/time/EXIF chunks, and every chunk not listed above.
This subset deliberately rejects ancillary metadata that a broader decoder
might ignore. There is no EXIF orientation, DPI-based UI scale, animation, or
color profile support, and no silent fallback to another decoder.

Limits: input up to 2 MiB with values 0–255, 1–4096 pixels per axis, at most
262144 pixels, 4096 chunks, 65536 DEFLATE blocks, and 1052672 bytes of
scanlines. Dimension products are computed only after the limits are checked,
and no allocation follows a chunk length before its limit is validated.

Cost: input and chunks are lists; scanlines and pixels are Bend arrays, which
are trees with logarithmic access and one `U32` per byte or pixel. Huffman
decoding uses counts per code length and a sorted symbol list, so one symbol can
scan up to 288 entries. `IDAT` concatenation and the list handed to Chromi are
linear copies. There is no streaming decode or memory tuning yet. The full
native suite ran in 0.30 s with a sampled peak RSS of about 91 MiB, process
start-up included; this is not an isolated decode benchmark.

The tests and the oracle are evidence for the declared subset; they do not prove
full PNG conformance or the correctness of the runtime and its IO.

## Repository map

| Path | Purpose |
| --- | --- |
| [main.bend](main.bend) | `decode_png`: validation, parsing, inflate, and pixel conversion. |
| [png.bend](png.bend) | Signature, chunks, CRC, header and ancillary-chunk rules. |
| [inflate.bend](inflate.bend) | zlib and DEFLATE: Huffman trees, blocks, LZ77 copies, Adler-32. |
| [pixels.bend](pixels.bend) | Filters, RGBA conversion, and the public `Raster` helpers. |
| [bytes.bend](bytes.bend) | Byte reader, CRC-32, and array allocation. |
| [file.bend](file.bend) | Bounded file reading and writing. |
| [tests.bend](tests.bend) | Native checks. |
| [fixtures/](fixtures/) | Generated PNGs, expected pixels, read-limit files, and their Bend tables. |
| [examples/decode.bend](examples/decode.bend) | Command-line decoder: PNG in, raw RGBA out. |
| [tools/oracle.py](tools/oracle.py) | Validation only: fixture generator and byte-for-byte oracle. |
| [docs/api.md](docs/api.md) | Types, ownership, limits, and the accepted PNG subset. |
| [docs/validation.md](docs/validation.md) | How the decoder was validated, with recorded results. |

## Direction

Next are safe metadata and RGB transparency (`tRNS`), other zlib window sizes,
grayscale and indexed images, measured allocations, and progressive decoding.
These are goals, not supported features.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development rules. The API is
experimental and may change. Licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your option.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution
intentionally submitted for inclusion in this work, as defined in the
Apache-2.0 license, shall be dual licensed as above, without any additional
terms or conditions.
