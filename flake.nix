{
  description = "the libjpeg-turbo command-line tools (cjpeg / djpeg / jpegtran / rdjpgcom / wrjpgcom) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # libjpeg-turbo is already a proven dependency across the catalogue (chafa /
  # jxl / heif / avif / openjpeg / rsvg-convert all link its static libjpeg.a),
  # but the library also ships five user-facing JPEG CLIs that nothing packaged
  # yet: cjpeg (encode), djpeg (decode), jpegtran (lossless transform), and the
  # comment-marker tools rdjpgcom / wrjpgcom. Here we turn the tools on
  # (WITH_TOOLS, default upstream) and post-link all five into one multicall
  # `jpeg-tools` binary (multicall.nix), following the avif/jxl/aom one-pkg-one-
  # bin pattern. The library is named after the tools because CI resolves
  # result/bin/<name> (same convention as opus-tools / vorbis-tools).
  #
  # Pure C — no libstdc++/libc++ runtime to fold (simpler than the C++ codec
  # CLIs): musl/darwin link libc statically with nothing extra, mingw just needs
  # `-static` to keep libgcc/libwinpthread out of companion DLLs. The only
  # per-target fix is riscv64's `simdcoverage` helper (shared overlay), identity
  # off riscv so every other arch keeps the cache-hit libjpeg.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # libjpeg-turbo with the CLI tools (cjpeg/djpeg/jpegtran/rdjpgcom/wrjpgcom)
      # enabled, wired onto a (static) scope. Shared by the engine path (returned
      # directly) and the multicall fold (darwin/windows).
      withTools = scope:
        let
          host = scope.stdenv.hostPlatform;
          # riscv64: libjpeg-turbo's `simdcoverage` helper references an RVV
          # jsimd_can_* entry point the 3.1.x RISC-V port doesn't declare, so
          # the build aborts. The shared overlay drops that unused helper; the
          # RVV SIMD in libjpeg.a itself is untouched. Identity off riscv.
          base = if host.isRiscV
                 then ulib.nativeFixes."libjpeg-turbo" scope
                 else scope.libjpeg;
        in
        base.overrideAttrs (old: {
          # WITH_TOOLS (default on) builds the CLIs; turn the TurboJPEG API +
          # its tjbench off (not user-facing, would add a turbojpeg lib) and
          # drop the regression test programs. ENABLE_STATIC/ENABLE_SHARED are
          # already set by pkgsStatic / the mingw cross.
          # SIMD stays ON everywhere. libjpeg-turbo's SIMD kernels are NASM/asm
          # ELF objects (jsimd_*_sse2/_avx2): they can't live in the -flto bitcode
          # module, but the engine hook now rescues them into a native sidecar
          # (module_native.a) that the self-fold links alongside module.bc, so the
          # asm resolves and SIMD is preserved (no per-arch SIMD-off needed).
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DWITH_TOOLS=1"
            "-DWITH_TURBOJPEG=0"
            "-DWITH_TESTS=0"
          ];
          doCheck = false;
          doInstallCheck = false;
          # cjpeg/djpeg/jpegtran build as CMake targets `<tool>-static` (they link
          # the static libjpeg.a) and only get RENAMEd to `<tool>` at install.
          # The engine path captures each link sidecar under the LINK output name,
          # so without this the sidecar is `cjpeg-static.link` and the self-fold's
          # `programs = [ cjpeg … ]` can't find it. Set OUTPUT_NAME so the linked
          # binary is already `cjpeg` (matching the install name and the program
          # list), and drop the now-redundant install RENAME of the `-static`
          # files (the on-disk name is already the plain tool name).
          # rdjpgcom/wrjpgcom already build under their plain names.
          postPatch = (old.postPatch or "") + ''
            for t in cjpeg djpeg jpegtran; do
              echo "set_target_properties($t-static PROPERTIES OUTPUT_NAME $t)" >> CMakeLists.txt
              # Make the install pick up the (now plain-named) binary instead of
              # the RENAMEd `<tool>-static`. EXE is empty on the engine's Linux
              # targets, so match the literal CMake tokens with empty EXE.
              substituteInPlace CMakeLists.txt \
                --replace-fail "PROGRAMS \''${DIR}/$t-static\''${EXE}" "PROGRAMS \''${DIR}/$t\''${EXE}" \
                --replace-fail "RENAME $t\''${EXE})" ")"
            done
          '';
        });

      # Darwin/Windows fold: post-link the five CLIs into one binary.
      mk = pkgs: scope:
        import ./multicall.nix { lib = scope.lib // ulib; }
          {
            pkgs = scope;
            libjpeg = withTools scope;
            extraLinkFlags = if scope.stdenv.hostPlatform.isMinGW then "-static" else "";
          };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jpeg-tools";
      # Man embedded (embedMan defaults to true): multicall.nix re-stages
      # libjpeg-turbo's per-tool doc/<tool>.1 into the build's share/man (cmake's
      # install, which the custom installPhase replaced, would have done this),
      # so both the native and mingw-cross builds harvest their OWN man — no
      # nixpkgs graft needed despite name ≠ nixpkgs attr.
      # Multicall: `jpeg-tools <applet> [args]` dispatches by argv[0]; the bare
      # binary takes the applet as its first arg. Smoke through that form.
      smoke = [ "--unpin-program=cjpeg" "-version" ];
      smokePattern = "libjpeg-turbo";

      # Build via the unpin-llvm engine + emit a bitcode multicall module. On
      # Linux the engine compiles the apps-enabled libjpeg-turbo to bitcode and
      # the standalone self-folds the five CLIs into one `jpeg-tools` binary;
      # darwin (no engine) keeps the objcopy fold in ./multicall.nix; windows via
      # windowsBuild. Pure C — no requires.cxx. pkgsAttr=libjpeg (name ≠ attr).
      pkgsAttr = "libjpeg";
      engine = "unpin-llvm";
      multicall = {
        programs = [
          { name = "cjpeg"; }
          { name = "djpeg"; }
          { name = "jpegtran"; }
          { name = "rdjpgcom"; }
          { name = "wrjpgcom"; }
        ];
      };

      # Native (pkgsStatic): pure C, libjpeg.a folds into the binary; musl links
      # libc statically, darwin links only libSystem. No runtime fold needed.
      build = pkgs:
        if pkgs.stdenv.hostPlatform.isLinux
        then withTools pkgs.pkgsStatic       # engine path: apps → bitcode → selfFold
        else mk pkgs pkgs.pkgsStatic;         # darwin: objcopy fold

      # mingw cross: `-static` (in extraLinkFlags) folds libgcc/libwinpthread so
      # no companion DLLs ride alongside the .exe.
      windowsBuild = pkgs: mk pkgs (ulib.mingwStaticCross pkgs);
    };
}
