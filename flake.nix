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
          # The windows .exe cannot be run from here, so the USE_SETMODE fix
          # below has to be checked where it lands: in the object. `_setmode`
          # is in the shipped .exe either way (cdjpeg.c pulls it in for
          # cjpeg/djpeg/jpegtran), so only the per-tool object separates a
          # working build from the one that silently wrote CRLF into JPEGs.
          postBuild = (old.postBuild or "") + lib.optionalString scope.stdenv.hostPlatform.isWindows ''
            for t in rdjpgcom wrjpgcom; do
              if [ -f "CMakeFiles/$t.dir/flags.make" ]; then
                f="CMakeFiles/$t.dir/flags.make"; ctx=$(cat "$f")
              elif [ -f build.ninja ]; then
                f=build.ninja; ctx=$(grep -B2 -A20 "CMakeFiles/$t.dir/src/$t.c.obj:" build.ninja)
              else
                echo "guard: no generated build file to read $t's flags from"; exit 1
              fi
              case "$ctx" in
                *USE_SETMODE*) ;;
                *) echo "guard: $t is compiled without USE_SETMODE (read from $f) — its"
                   echo "       stdio stays in text mode and every JPEG it writes to a"
                   echo "       pipe comes out with each 0x0A expanded to 0x0D 0x0A."
                   exit 1 ;;
              esac
            done
          '';
          # `smoke` only runs cjpeg, and only `-version`: an applet that folded
          # onto the wrong entry point, or a tool whose stdio was left in text
          # mode, prints the same line. Run all five for real on every target
          # the builder can execute, against upstream's own test image. The
          # comment round trip goes through a PIPE on purpose — that is the
          # path the Windows text-mode bug corrupted, and the one no `-outfile`
          # covers.
          doInstallCheck = check;
          installCheckPhase = ''
            runHook preInstallCheck
            _b="''${bin:-$out}/bin"
            _i=$NIX_BUILD_TOP/$sourceRoot/testimages/testorig.ppm
            "$_b/cjpeg" -quality 90 -outfile p.jpg "$_i"
            "$_b/djpeg" -outfile p.ppm p.jpg
            "$_b/jpegtran" -rotate 90 -outfile p-rot.jpg p.jpg
            "$_b/wrjpgcom" -comment "unpins round trip" p.jpg > p-com.jpg
            [ "$("$_b/rdjpgcom" p-com.jpg)" = "unpins round trip" ] || {
              echo "rdjpgcom did not read back the comment wrjpgcom wrote"; exit 1; }
            # wrjpgcom only ADDS a marker, so stripping it must give back the
            # exact bytes cjpeg wrote — a byte the pipe mangled shows up here.
            "$_b/jpegtran" -copy none -outfile p-strip.jpg p-com.jpg
            "$_b/jpegtran" -copy none -outfile p-base.jpg p.jpg
            cmp p-strip.jpg p-base.jpg
            echo "installCheck: all five tools round-trip"
            runHook postInstallCheck
          '';
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
            # Upstream applies its own `-DUSE_SETMODE` to cjpeg/djpeg/jpegtran
            # only; `add_executable(rdjpgcom …)` / `(wrjpgcom …)` get no compile
            # flags at all, so the `setmode(fileno(std…), O_BINARY)` calls both
            # tools already carry are compiled out on Windows. wrjpgcom writes
            # its JPEG to stdout and nowhere else (TWO_FILE_COMMANDLINE is not
            # defined), so on Windows every file it produced came out with each
            # 0x0A expanded to 0x0D 0x0A — a corrupt JPEG, always; rdjpgcom hit
            # the same on stdin ("Premature EOF in JPEG file"). Define it here.
            + lib.optionalString scope.stdenv.hostPlatform.isWindows ''
              for t in rdjpgcom wrjpgcom; do
                echo "target_compile_definitions($t PRIVATE USE_SETMODE)" >> CMakeLists.txt
              done
            ''
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
      # Multicall: the applet is chosen by argv[0] (the names `unpin install`
      # puts on PATH) or by `--unpin-program=`; the bare binary lists them. It
      # does NOT take the applet as a positional argument.
      #
      # The smoke is one command matched by one grep line, so it can only prove
      # that one applet starts. The installCheck above is what actually runs all
      # five.
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
