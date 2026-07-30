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
  # `-static` to keep libgcc/libwinpthread out of companion DLLs. No per-target
  # lib fix: nix-lib carries libjpeg-turbo's own (riscv `simdcoverage`, no-LTO).
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # libjpeg-turbo with the CLI tools (cjpeg/djpeg/jpegtran/rdjpgcom/wrjpgcom)
      # enabled, wired onto a (static) scope. Shared by the engine path
      # (engineFold, returned directly) and the windows objcopy fold.
      withTools = { engineFold }: scope:
        let
          lib = scope.lib;
          # bmpsizetest below guards the engine path's -flto, and only runs where
          # the build host can execute the result (a cross target would need
          # qemu). Everywhere else the test programs are dead weight — don't
          # build them either.
          check = engineFold && scope.stdenv.buildPlatform.canExecute scope.stdenv.hostPlatform;
        in
        scope.libjpeg.overrideAttrs (old: {
          # WITH_TOOLS (default on) builds the CLIs; turn the TurboJPEG API +
          # its tjbench off (not user-facing, would add a turbojpeg lib).
          # ENABLE_STATIC/ENABLE_SHARED are already set by pkgsStatic / the
          # mingw cross.
          # SIMD stays ON everywhere: libjpeg-turbo's NASM/asm kernels can't live
          # in a bitcode module, but the engine hook rescues native objects into a
          # sidecar (module_native.a) that the self-fold links alongside module.bc
          # — so no per-arch SIMD-off is needed.
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DWITH_TOOLS=1"
            "-DWITH_TURBOJPEG=0"
            "-DWITH_TESTS=${if check then "1" else "0"}"
          ];
          # Regression guard for the full-LTO miscompile of the BMP I/O modules:
          # built with LTO, bmpsizetest hangs and then OOMs. It is why nix-lib
          # pins libjpeg-turbo to the lto=false engine stdenv set-wide, and why
          # the -flto below is kept as narrow as each platform allows.
          doCheck = check;
          checkPhase = "ctest -R bmpsizetest --output-on-failure --timeout 120";
          doInstallCheck = false;
          # Every object of this package is therefore native — including the ones
          # holding `main`. But the engine module hook's entry trampoline is
          # bitcode calling `extern main`, so with no `main` in module.bc it binds
          # to the dispatcher's own `main` and every applet tail-loops forever.
          # Compile the main-bearing translation units with -flto so each `main`
          # reaches module.bc, keeping libjpeg.a itself native.
          #
          # And cjpeg/djpeg/jpegtran build as CMake targets `<tool>-static` (they
          # link the static libjpeg.a), only RENAMEd to `<tool>` at install. The
          # engine captures each link sidecar under the LINK output name, so
          # without OUTPUT_NAME the sidecar is `cjpeg-static.link` and the
          # self-fold's `programs = [ cjpeg … ]` can't find it. Set it, and drop
          # the now-redundant install RENAME. rdjpgcom/wrjpgcom already build
          # under their plain names.
          #
          # BOTH ARE ENGINE-ONLY, each fatal to the objcopy fold windows uses:
          # objcopy does not read a bitcode .o ("plugin needed to handle lto
          # object"), and multicall.nix templates off `link.txt`'s ` -o
          # cjpeg-static` — renamed, its sed silently no-ops and the link loses
          # the dispatcher, leaving no `main` at all.
          postPatch = (old.postPatch or "")
            + lib.optionalString engineFold (
            # darwin needs MORE than the five: the hook's `ld.lld -r` is the ELF
            # driver, and a loose Mach-O object is a hard error there ("unknown
            # file type") where on ELF it is merely dropped into the sidecar. So
            # every own object goes to bitcode; only libjpeg.a stays Mach-O, and
            # an ARCHIVE member the ELF driver can't read is skipped (warning)
            # and rescued, which is the case the hook is built for.
            # bmpsizetest-static rides along — where it exists at all — so the
            # guard below keeps testing the SAME codegen the shipped tools get
            # (it compiles its own copies of rdbmp/wrbmp, LTO here, not on Linux).
            (if scope.stdenv.hostPlatform.isDarwin then ''
              for t in cjpeg-static djpeg-static jpegtran-static rdjpgcom wrjpgcom${lib.optionalString check " bmpsizetest-static"}; do
                echo "target_compile_options($t PRIVATE -flto)" >> CMakeLists.txt
              done
            '' else ''
              for s in cjpeg djpeg jpegtran rdjpgcom wrjpgcom; do
                echo "set_source_files_properties(src/$s.c PROPERTIES COMPILE_OPTIONS -flto)" >> CMakeLists.txt
              done
            '')
            + ''
              for t in cjpeg djpeg jpegtran; do
                echo "set_target_properties($t-static PROPERTIES OUTPUT_NAME $t)" >> CMakeLists.txt
                # Make the install pick up the (now plain-named) binary instead of
                # the RENAMEd `<tool>-static`. EXE is empty on the engine's Linux
                # targets, so match the literal CMake tokens with empty EXE.
                substituteInPlace CMakeLists.txt \
                  --replace-fail "PROGRAMS \''${DIR}/$t-static\''${EXE}" "PROGRAMS \''${DIR}/$t\''${EXE}" \
                  --replace-fail "RENAME $t\''${EXE})" ")"
              done
            '');
        });

      # Windows fold: post-link the five CLIs into one binary. Linux AND darwin
      # go through the engine self-fold instead (mingw has no engine).
      mk = pkgs: scope:
        import ./multicall.nix { lib = scope.lib // ulib; }
          {
            pkgs = scope;
            libjpeg = withTools { engineFold = false; } scope;
            extraLinkFlags = if scope.stdenv.hostPlatform.isMinGW then "-static" else "";
          };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jpeg-tools";
      # Man embedded (embedMan defaults to true): multicall.nix re-stages
      # libjpeg-turbo's per-tool doc/<tool>.1 into the build's share/man for the
      # mingw cross (cmake's install, which its custom installPhase replaced,
      # would have done this); the engine path keeps cmake's own install. Either
      # way each target harvests its OWN man — no nixpkgs graft needed despite
      # name ≠ nixpkgs attr.
      # Multicall: `jpeg-tools <applet> [args]` dispatches by argv[0]; the bare
      # binary takes the applet as its first arg. Smoke through that form.
      smoke = [ "--unpin-program=cjpeg" "-version" ];
      smokePattern = "libjpeg-turbo";

      # Build via the unpin-llvm engine + emit a bitcode multicall module: the
      # engine compiles the apps-enabled libjpeg-turbo and the standalone
      # self-folds the five CLIs into one `jpeg-tools` binary, on Linux and
      # darwin alike. Only windows (no engine) keeps the objcopy fold in
      # ./multicall.nix. Pure C — no requires.cxx. pkgsAttr=libjpeg (name ≠ attr).
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
      # libc statically, darwin links only libSystem.
      build = pkgs: withTools { engineFold = true; } pkgs.pkgsStatic;

      # mingw cross: `-static` (in extraLinkFlags) folds libgcc/libwinpthread so
      # no companion DLLs ride alongside the .exe.
      windowsBuild = pkgs: mk pkgs (ulib.mingwStaticCross pkgs);
    };
}
