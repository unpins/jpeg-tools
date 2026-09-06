# Changelog

## [Unreleased]

### Fixed

- **`wrjpgcom` produced a corrupt JPEG on Windows — always.** It writes its
  output to standard output and has no other output path, and its standard
  output was left in text mode, so every 0x0A byte in the JPEG came out as
  0x0D 0x0A. `rdjpgcom` then reported "garbage data found in JPEG file".
  `rdjpgcom` was hit the same way when reading a JPEG from standard input
  ("Premature EOF in JPEG file"). Both are fixed; the files the two tools now
  produce on Windows are byte-identical to the ones produced on Linux. Only
  Windows was affected — `cjpeg`, `djpeg` and `jpegtran` were always correct,
  on every platform. The released `v3.1.4-1` Windows binary has this bug; the
  Linux and macOS binaries of that release do not.

### Added

- Every build now encodes, decodes, rotates and comments a test image with all
  five programs and checks the result, on each platform it can run them on. A
  program that starts but no longer works is otherwise invisible: `-version`
  prints the same line either way.

### Changed

- README: `unpin jpeg-tools cjpeg …` never selected a program — it made
  `cjpeg` look like a file to read. The form is
  `unpin jpeg-tools --unpin-program=cjpeg …`, or install the programs and call
  `cjpeg` directly.

## [v3.1.4-1] — 2026-06-06

Initial release: libjpeg-turbo 3.1.4's `cjpeg`, `djpeg`, `jpegtran`,
`rdjpgcom` and `wrjpgcom` as one self-contained binary for Linux (x86_64,
i686, aarch64, armv7l, ppc64le, riscv64), macOS (x86_64, arm64) and Windows
(x86_64), with the five man pages embedded.
