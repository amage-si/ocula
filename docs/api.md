# Ocula API

Ocula depends only on `Base` from the official Bend toolchain (`Base.Array`,
`Base.File`). Import paths are relative to the calling file. A module next to
the `Ocula` directory uses:

```bend
import Base
import ./Ocula/main.bend as O
import ./Ocula/pixels.bend as P
import ./Ocula/file.bend as F
```

`main.bend`, `pixels.bend`, and `file.bend` are the public modules. `bytes.bend`,
`inflate.bend`, and `png.bend` are internal and may change freely.

## Entry points

| Function | Contract |
| --- | --- |
| `O.decode_png(bytes: +List<U32>)` | `Result<&2, &1, String, P.Raster>`. Pure; every error is a `Fail{message}`. |
| `F.read(path: String)` | `IO(+List<U32>)`. Reads in 64 KiB chunks until EOF, stopping at 2 MiB + 1 byte so that oversized input is detected. IO errors end the program through `IO.die`. |
| `F.write(path, bytes)` | `IO(Unit)`. Writes a byte list. |
| `P.pixel(raster, x, y)` | `Result<&2, &1, String, P.Raster & U32>`. Checks x and y against the dimensions and returns the raster with the pixel. |
| `P.packed_pixels(raster)` | Consumes the raster; returns exactly `width × height` packed `0xRRGGBBAA` values, row-major. |
| `P.rgba_bytes(raster)` | Consumes the raster; returns `width × height × 4` bytes in R, G, B, A order. |

## Raster

```bend
Raster{width: U32, height: U32, pixels: Array<U32>}
```

- Pixels are `0xRRGGBBAA`, straight (non-premultiplied) alpha, sRGB, left to
  right and top to bottom. RGB images get alpha 255.
- The array's capacity is rounded up to a power of two. Only the first
  `width × height` entries belong to the image; the tail does not.
- Bend arrays index modulo their capacity. The decoder validates every index
  derived from input before using it. The helpers assume a `Raster` produced by
  `decode_png`; constructors are public in Bend, but a forged buffer with a
  wrong capacity is outside the contract.

## Accepted PNG subset

| Aspect | Accepted |
| --- | --- |
| Color type and depth | 2 (RGB) or 6 (RGBA), 8 bits |
| Interlace | None |
| Chunk order | `IHDR` first and once; consecutive `IDAT` (empty allowed); empty `IEND` last; nothing after it |
| Integrity | CRC-32 on every accepted chunk; Adler-32 of the decompressed data; exact decompressed length |
| zlib | 32 KiB window, no preset dictionary, nothing after the stream |
| DEFLATE | Stored, fixed, and dynamic blocks; overlapping copies |
| Filters | None, Sub, Up, Average, Paeth |
| `PLTE` | Optional for truecolor; length, order, and duplicates validated; ignored for pixels |
| `sRGB` | Rendering intent 0–3 |
| `gAMA` | Only 45455, and only with `sRGB` (in either order) |
| `pHYs` | Valid and before `IDAT`; not used as a UI scale |

Everything else is rejected with a message, including `tRNS`, `iCCP`, `cHRM`,
`cICP`, text, time, and EXIF chunks. An image without color chunks is treated
as sRGB.

## Limits

| Limit | Value |
| --- | --- |
| Input | 2 MiB, values 0–255 |
| Width and height | 1 to 4096 |
| Pixels | 262144 |
| Chunks | 4096 |
| DEFLATE blocks | 65536 |
| Scanline bytes | 1052672 |
| Huffman code length | 15 |

Dimension products are computed after division-based limit checks. No buffer is
allocated from a chunk length before that length is validated. An LZ77 distance
may not exceed the bytes already written, the window, or the output.

## Command-line example

`examples/decode.bend` takes `input.png output.rgba` after the runtime options:

```sh
./build/decode --threads 2 --gpu off input.png output.rgba
```

It prints `RGBA8 <width> <height>` and writes `rgba_bytes`. A decode error exits
with code 1 and the message; wrong arguments exit with code 2.

## Runtime boundary

All decoding happens in Bend. The official runtime implements file IO and
arrays; the C it generates and libc are external dependencies.
