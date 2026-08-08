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
  # (WITH_TOOLS, default upstream) and let nix-lib self-fold all five into one
  # multicall `jpeg-tools` binary, following the avif/jxl/aom one-pkg-one-bin
  # pattern. The library is named after the tools because CI resolves
  # result/bin/<name> (same convention as opus-tools / vorbis-tools).
  #
  # Pure C — no libstdc++/libc++ runtime to fold (simpler than the C++ codec
  # CLIs). No per-target lib fix: nix-lib carries libjpeg-turbo's own (riscv
  # `simdcoverage`, no-LTO).
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # libjpeg-turbo with the CLI tools (cjpeg/djpeg/jpegtran/rdjpgcom/wrjpgcom)
      # enabled, wired onto a (static) scope. Every target — native, darwin and
      # the mingw cross — builds through this.
      withTools = scope:
        let
          lib = scope.lib;
          # bmpsizetest below guards -flto, and only runs where the build host
          # can execute the result (a cross target would need qemu). Everywhere
          # else the test programs are dead weight — don't build them either.
          check = scope.stdenv.buildPlatform.canExecute scope.stdenv.hostPlatform;
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
          postPatch = (old.postPatch or "") + (
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

    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jpeg-tools";
      # Man embedded (embedMan defaults to true): every target keeps cmake's own
      # install, which stages libjpeg-turbo's per-tool doc/<tool>.1 — so each
      # harvests its OWN man, no nixpkgs graft needed despite name ≠ attr.
      # Multicall: `jpeg-tools <applet> [args]` dispatches by argv[0]; the bare
      # binary takes the applet as its first arg. Smoke through that form.
      smoke = [ "--unpin-program=cjpeg" "-version" ];
      smokePattern = "libjpeg-turbo";

      # Build via the unpin-llvm engine + emit a bitcode multicall module: the
      # engine compiles the apps-enabled libjpeg-turbo and the standalone
      # self-folds the five CLIs into one `jpeg-tools` binary on every target,
      # windows included. Pure C — no requires.cxx. pkgsAttr=libjpeg (name ≠ attr).
      pkgsAttr = "libjpeg";
      engine = "unpin-llvm";
      multicall = {
        windows = true;
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
      build = pkgs: withTools pkgs.pkgsStatic;

      windowsBuild = pkgs: withTools (ulib.mingwStaticCross pkgs);
    };
}
