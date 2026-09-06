# jpeg-tools

The [libjpeg-turbo](https://libjpeg-turbo.org/) command-line programs as a single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/jpeg-tools/actions/workflows/jpeg-tools.yml/badge.svg)](https://github.com/unpins/jpeg-tools/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

The classic JPEG programs from the SIMD-accelerated libjpeg-turbo: compress to
JPEG, decompress from JPEG, transform JPEGs losslessly, and read/write the
textual comment marker — the same `libjpeg` that FFmpeg, ImageMagick, chafa and
countless image pipelines link, with its programs in one binary.

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install jpeg-tools`.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin jpeg-tools --unpin-program=cjpeg -quality 90 -outfile out.jpg in.ppm
unpin jpeg-tools --unpin-program=djpeg -outfile out.ppm in.jpg
unpin jpeg-tools --unpin-program=jpegtran -rotate 90 -outfile rot.jpg in.jpg
```

Or install them and call each by name, which is usually what you want:

```bash
unpin install jpeg-tools
cjpeg -quality 90 -outfile out.jpg in.ppm
```

`unpin install jpeg-tools` creates the `cjpeg`, `djpeg`, `jpegtran`, `rdjpgcom`, and `wrjpgcom` commands.

## Programs

| command | what it does |
| --- | --- |
| `cjpeg` | encode PPM/BMP/GIF/Targa → JPEG |
| `djpeg` | decode JPEG → PPM/BMP/GIF/Targa |
| `jpegtran` | lossless rotate / crop / optimize JPEGs |
| `rdjpgcom` | read JPEG comment markers |
| `wrjpgcom` | write a JPEG comment marker |

## Man pages

`cjpeg.1`, `djpeg.1`, `jpegtran.1`, `rdjpgcom.1` and `wrjpgcom.1` are embedded in
the binary — read with `unpin man jpeg-tools <tool>` (e.g. `unpin man jpeg-tools cjpeg`).

## Build locally

```bash
nix build github:unpins/jpeg-tools
./result/bin/jpeg-tools --unpin-program=cjpeg -version
```

Or run directly:

```bash
nix run github:unpins/jpeg-tools -- --unpin-program=djpeg -outfile out.ppm in.jpg
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/jpeg-tools/releases) page has standalone binaries for manual download.

## Build notes

- libjpeg-turbo's five programs are combined into the single `jpeg-tools`
  binary; the package is named after the tools, like `opus-tools`.
- Pure C: `libjpeg.a` links statically into the binary. The TurboJPEG API and
  the regression-test programs are left out.
- Every build encodes, decodes, rotates and comments a test image before it is
  accepted, so a program that starts but no longer works fails the build.
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs (`-static` folds
  out libgcc/libwinpthread).
- **macOS:** static `libjpeg.a`, links only `libSystem`.
- **RISC-V:** the unused `simdcoverage` build helper (which references an RVV
  intrinsic the port doesn't declare) is dropped; the RVV SIMD in `libjpeg.a` is
  untouched.
