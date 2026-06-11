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

      # libjpeg-turbo with the CLI tools enabled, wired onto a (static) scope.
      mk = pkgs: scope:
        let
          host = scope.stdenv.hostPlatform;
          # riscv64: libjpeg-turbo's `simdcoverage` helper references an RVV
          # jsimd_can_* entry point the 3.1.x RISC-V port doesn't declare, so
          # the build aborts. The shared overlay drops that unused helper; the
          # RVV SIMD in libjpeg.a itself is untouched. Identity off riscv.
          base = if host.isRiscV
                 then ulib.nativeFixes."libjpeg-turbo" scope
                 else scope.libjpeg;
          libjpeg = base.overrideAttrs (old: {
            # WITH_TOOLS (default on) builds the CLIs; turn the TurboJPEG API +
            # its tjbench off (not user-facing, would add a turbojpeg lib) and
            # drop the regression test programs. ENABLE_STATIC/ENABLE_SHARED are
            # already set by pkgsStatic / the mingw cross.
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-DWITH_TOOLS=1"
              "-DWITH_TURBOJPEG=0"
              "-DWITH_TESTS=0"
            ];
            doCheck = false;
            doInstallCheck = false;
          });
        in
        import ./multicall.nix { lib = scope.lib // ulib; }
          {
            pkgs = scope;
            inherit libjpeg;
            extraLinkFlags = if host.isMinGW then "-static" else "";
          };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "jpeg-tools";
      # No man embed: matches the avif/jxl/aom/heif multicall precedent and
      # sidesteps the name≠nixpkgs-attr man-graft path. (libjpeg-turbo does ship
      # cjpeg/djpeg/jpegtran man pages; can be revisited via pkgsAttr later.)
      embedMan = false;
      # Multicall: `jpeg-tools <applet> [args]` dispatches by argv[0]; the bare
      # binary takes the applet as its first arg. Smoke through that form.
      smoke = [ "cjpeg" "-version" ];
      smokePattern = "libjpeg-turbo";

      # Native (pkgsStatic): pure C, libjpeg.a folds into the binary; musl links
      # libc statically, darwin links only libSystem. No runtime fold needed.
      build = pkgs: mk pkgs pkgs.pkgsStatic;

      # mingw cross: `-static` (in extraLinkFlags) folds libgcc/libwinpthread so
      # no companion DLLs ride alongside the .exe.
      windowsBuild = pkgs: mk pkgs (ulib.mingwStaticCross pkgs);
    };
}
