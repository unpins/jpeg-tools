# jpeg-tools

Standalone build of the [libjpeg-turbo](https://libjpeg-turbo.org/) command-line
tools — `cjpeg`, `djpeg`, `jpegtran`, `rdjpgcom` and `wrjpgcom` — as a single
self-contained binary.

[![CI](https://github.com/unpins/jpeg-tools/actions/workflows/jpeg-tools.yml/badge.svg)](https://github.com/unpins/jpeg-tools/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

The classic JPEG toolbox from the SIMD-accelerated libjpeg-turbo: compress to
JPEG, decompress from JPEG, transform JPEGs losslessly, and read/write the
textual comment marker — the same `libjpeg` that FFmpeg, ImageMagick, chafa and
countless image pipelines link, with its CLIs in one binary.

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin jpeg-tools cjpeg -quality 90 -outfile out.jpg in.ppm     # encode PPM/BMP/GIF/Targa -> JPEG
unpin jpeg-tools djpeg -outfile out.ppm in.jpg                 # decode JPEG -> PPM/BMP/GIF/Targa
unpin jpeg-tools jpegtran -rotate 90 -outfile rot.jpg in.jpg   # lossless rotate/crop/optimize
unpin jpeg-tools wrjpgcom -comment "shot on a phone" in.jpg > out.jpg   # write a comment marker
unpin jpeg-tools rdjpgcom out.jpg                              # read comment markers
```

To install the programs onto your PATH:

```bash
unpin install jpeg-tools
```

## Build locally

```bash
nix build github:unpins/jpeg-tools
./result/bin/jpeg-tools cjpeg -version
```

Or run directly:

```bash
nix run github:unpins/jpeg-tools -- djpeg -outfile out.ppm in.jpg
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/jpeg-tools/releases) page has standalone binaries for manual download.

## Build notes

- One package per library: libjpeg-turbo's five CLIs are post-linked into a
  single multicall `jpeg-tools` binary, with the applet names embedded so
  `unpin` can recreate the `cjpeg`/`djpeg`/… argv[0] shims. The package is named
  after the tools (CI resolves `result/bin/<name>`), like `opus-tools`.
- The tools share their support code as loose objects (`cdjpeg`, `rdswitch` are
  compiled into cjpeg, djpeg *and* jpegtran), so the merge dedups those by name
  against one template link and renames the per-tool globals — rather than
  re-deriving the link line by hand.
- Pure C: there is no C++/libstdc++ runtime to fold. `libjpeg.a` links
  statically into the binary; the TurboJPEG API and the regression-test programs
  are turned off.
- **Windows:** `mingw` cross, single `.exe`, no companion DLLs (`-static` folds
  out libgcc/libwinpthread).
- **macOS:** static `libjpeg.a`, links only `libSystem`.
- **RISC-V:** the unused `simdcoverage` build helper (which references an RVV
  intrinsic the port doesn't declare) is dropped; the RVV SIMD in `libjpeg.a` is
  untouched.
