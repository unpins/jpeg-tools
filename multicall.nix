# libjpeg-turbo ships five command-line tools — cjpeg, djpeg, jpegtran,
# rdjpgcom and wrjpgcom — as separate executables. To honour the unpins
# one-pkg-one-bin rule we post-link them into a single multicall binary at
# $out/bin/jpeg-tools; `lib.withAliases` then embeds the tool names as an
# UNPIN_META block so unpin's installer can recreate the argv[0] shims.
#
# Link mechanics (vs avif/jxl, which reuse one app's link.txt as-is):
#
#   * libjpeg-turbo uses the CMake "Unix Makefiles" generator (cmake, no ninja),
#     so every target gets a `CMakeFiles/<t>.dir/link.txt` with its exact link
#     command. We reuse cjpeg-static's link.txt as the template (it links the
#     static libjpeg.a) and splice the other tools' objects + a dispatcher in.
#
#   * The CATCH that makes this different from avif: the JPEG tools share their
#     support code as LOOSE objects, not a single archive. cdjpeg.c.o and
#     rdswitch.c.o are compiled into cjpeg-static, djpeg-static AND
#     jpegtran-static. Splicing every tool's full object set would give three
#     copies of cdjpeg.o → "multiple definition" (the e2fsprogs landmine). The
#     copies are byte-equivalent, so we DEDUP the splice list by basename
#     against the template's objects (and each other) — the shared cdjpeg.o /
#     rdswitch.o come from the template, and every spliced main resolves its
#     start_input/parse_switches refs against that one copy.
#
#   * Each tool's main TU (cjpeg.c, djpeg.c, jpegtran.c, …) also defines its own
#     non-static globals beyond main() — parse_switches, usage, progname — so
#     splicing djpeg.c.o + jpegtran.c.o clashes with the template's cjpeg.c.o
#     and with each other. Each such symbol is defined AND called only within
#     its own TU, so the iterative-rename pass (below) renames them per-tool in
#     the spliced objects (def + intra-object ref move together); the template's
#     objects are never touched, so the shared cdjpeg refs stay resolvable.
#
#   * The tools are pure C (no libstdc++/libc++), so the link driver is cc and
#     there is no C++ runtime to fold — `extraLinkFlags` only carries the mingw
#     `-static` (folds libgcc/libwinpthread out of companion DLLs); darwin and
#     musl link libc statically with nothing extra.
{ lib }:
{ pkgs, libjpeg, name ? "jpeg-tools", extraLinkFlags ? "" }:
let
  multicall = libjpeg.overrideAttrs (old: {
    pname = "jpeg-tools-multi";

    # Ship only the multicall binary (drop the lib/dev/man outputs libjpeg has).
    outputs = [ "out" ];
    separateDebugInfo = false;
    postInstall = "";

    postBuild = (old.postBuild or "") + ''
      mkdir -p multicall

      # The five user-facing CLI tools. cjpeg/djpeg/jpegtran build as
      # `<tool>-static` (they link the static libjpeg.a); rdjpgcom/wrjpgcom are
      # self-contained and build under their plain name.
      tools=(cjpeg djpeg jpegtran rdjpgcom wrjpgcom)
      dir_for() { case "$1" in cjpeg|djpeg|jpegtran) echo "$1-static";; *) echo "$1";; esac; }

      # CMake names objects `.c.o` on ELF/Mach-O but `.c.obj` for mingw.
      oext=o
      [ -n "$(find . -path '*cjpeg-static.dir/src/cjpeg.c.obj' -print -quit)" ] && oext=obj

      # Each tool's main translation-unit object (where main() lives).
      declare -A MAINOBJ
      present=()
      for t in "''${tools[@]}"; do
        d="$(dir_for "$t")"
        mo="$(find . -path "*$d.dir/src/$t.c.$oext" | head -1)"
        [ -n "$mo" ] && { MAINOBJ[$t]="$mo"; present+=("$t"); }
      done
      [ ''${#present[@]} -ge 2 ] || { echo "multicall: expected >=2 tools, got ''${present[*]:-none}" >&2; exit 1; }
      printf '%s\n' "''${present[@]}" > multicall/apps.list

      # Template = cjpeg-static: its link.txt links the static libjpeg.a and
      # carries the platform link flags. We splice every OTHER tool's objects in.
      tmpl=cjpeg
      tmpldir="$(dir_for "$tmpl")"
      linktxt="$(find . -path "*$tmpldir.dir/link.txt" | head -1)"
      [ -n "$linktxt" ] || { echo "multicall: $tmpl link.txt not found (non-Makefile generator?)" >&2; exit 1; }

      # Symbol prefix (Mach-O leads C symbols with '_'), read from a main object.
      if $NM --defined-only "''${MAINOBJ[$tmpl]}" | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Distinct entry points: rename each tool's main → <tool>_main (in place;
      # the template's cjpeg.c.o is renamed too, it stays in its own link.txt).
      for t in "''${present[@]}"; do
        $OBJCOPY --redefine-sym "''${up}main=''${up}''${t}_main" "''${MAINOBJ[$t]}"
      done

      # Splice list: every object of every NON-template tool whose basename is
      # not already present in the template (dedups the shared cdjpeg.c.o /
      # rdswitch.c.o) and not already spliced. The template's objects + libjpeg.a
      # stay in its link.txt; spliced mains resolve their shared-helper refs
      # against the template's single copy.
      declare -A SEEN
      for o in $(find . -path "*$tmpldir.dir/*.$oext"); do SEEN["$(basename "$o")"]=1; done
      splice=""
      for t in "''${present[@]}"; do
        [ "$t" = "$tmpl" ] && continue
        d="$(dir_for "$t")"
        for o in $(find . -path "*$d.dir/*.$oext" | sort); do
          b="$(basename "$o")"
          [ -n "''${SEEN[$b]:-}" ] && continue
          SEEN["$b"]=1
          splice="$splice $o"
        done
      done

      # Dispatcher (shared canonical generator — see nix-lib
      # lib.multicallTableDispatcherC). Invoked at COLUMN 0 so the heredoc
      # terminators in the generated script reach the shell at column 0.
      # The generator reads a TSV `<applet>\t<fn-base>` and calls `<fn-base>_main`;
      # sanitize exactly as the mains were renamed so the symbols match.
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        printf '%s\t%s\n' "$a" "$(printf '%s' "$a" | tr -c 'A-Za-z0-9_' '_')"
      done < multicall/apps.list > multicall/applets.list
${lib.multicallTableDispatcherC { inherit name; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Reuse cjpeg-static's link command: splice the non-template objects + the
      # dispatcher in front of the output, retarget to multicall/${name}, append
      # the runtime-folding flags. The trailing ` libjpeg.a` in the template line
      # stays after the new -o target.
      linkbase="$(sed -E "s| -o (\"?)$tmpldir(\.exe)?(\"?)|$splice multicall/dispatcher.o -o multicall/${name}|" "$linktxt") ${extraLinkFlags}"

      # Iterative link: each failed attempt names remaining strong duplicates
      # (per-tool globals like parse_switches/usage shared by name across the
      # tool mains); rename those in the spliced (non-template) objects and
      # relink. Template objects are sacrosanct (renaming one would break the
      # shared cdjpeg/rdswitch refs the other mains resolve against it).
      converged=0
      for _ in $(seq 1 20); do
        if eval "$linkbase" 2>multicall/link.err; then converged=1; break; fi
        cat multicall/link.err >&2
        sed -nE "s/.*multiple definition of [\`']([^']+)'.*/\1/p; s/.*duplicate symbol '([^']+)'.*/\1/p" \
          multicall/link.err | sort -u > multicall/clash.syms
        [ -s multicall/clash.syms ] || { echo "multicall: link failed without a duplicate-symbol diagnostic" >&2; exit 1; }
        while IFS= read -r sym; do
          hit=0
          for t in "''${present[@]}"; do
            [ "$t" = "$tmpl" ] && continue
            d="$(dir_for "$t")"
            for obj in $(find . -path "*$d.dir/*.$oext"); do
              raw=$($NM --defined-only "$obj" | awk -v s="$sym" '$3==s {print $3; exit}')
              [ -n "$raw" ] || continue
              $OBJCOPY --redefine-sym "$raw=''${up}''${t}__''${raw#"$up"}" "$obj"
              hit=1
            done
          done
          [ "$hit" = 1 ] || { echo "multicall: clashing symbol '$sym' only in template '$tmpl' — not renamable" >&2; exit 1; }
        done < multicall/clash.syms
      done
      [ "$converged" = 1 ] || { echo "multicall: link did not converge in 20 passes" >&2; exit 1; }

      # mingw gcc may auto-append .exe; normalize to the suffixless name.
      [ -f multicall/${name} ] || mv multicall/${name}.exe multicall/${name}
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 multicall/${name} "$out/bin/${name}"
      while IFS= read -r a; do
        [ -n "$a" ] && ln -s ${name} "$out/bin/$a"
      done < multicall/apps.list

      # libjpeg-turbo ships a man page per tool as a source file (doc/<tool>.1);
      # cmake's install — which we replaced with this custom phase — would have
      # placed them under share/man/man1. Re-stage exactly the pages for the
      # applets we actually ship so embedMan harvests them into the binary's ZIP
      # (`unpin man jpeg-tools <tool>`). Native and the mingw cross both run this,
      # so each target harvests its OWN man (no nixpkgs graft; name ≠ attr).
      mkdir -p "$out/share/man/man1"
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        m="$(find "$NIX_BUILD_TOP" -path "*/doc/$a.1" -print -quit 2>/dev/null)"
        [ -n "$m" ] && install -m644 "$m" "$out/share/man/man1/$a.1"
      done < multicall/apps.list
      runHook postInstall
    '';
  });
  aliased = lib.withAliases pkgs
    {
      primary = name;
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if pkgs.stdenv.hostPlatform.isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/${name}" ] && mv "$out/bin/${name}" "$out/bin/${name}.exe"
  '';
})
else aliased
