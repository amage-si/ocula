# Changelog

All notable changes to Ocula are recorded here. Ocula follows
[semantic versioning](https://semver.org) in its 0.x form: while the API is
experimental, a minor version (0.2.0) may change it in breaking ways and a
patch version (0.1.1) only fixes. Ocula is built from source together with its
sibling AMAGE libraries; the set of versions tested together is listed in
[eco-build's releases](https://github.com/amage-si/eco-build/tree/main/releases).

## [0.1.0] - 2026-10-09

First tagged release, tested with Bend 2.0.35 on Linux (X11/XWayland) as part
of AMAGE Eco 0.1.0.

### Included

- PNG decoding of 8-bit RGB and RGBA, non-interlaced, with CRC-32 on every
  chunk and Adler-32 on the data.
- zlib/DEFLATE (stored, fixed, dynamic Huffman) with table-driven decoding,
  and all five scanline filters.
- `kitty.png` (256x256) decodes in about 2 ms (about 49 ms before the decoder
  was reworked).
- 104 native checks; real PNGs match ImageMagick pixel for pixel.

[0.1.0]: https://github.com/amage-si/ocula/releases/tag/v0.1.0
