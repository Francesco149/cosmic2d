{
  description = "cosmic2d — tiny 2d pixel-art engine / fantasy console";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs { inherit system; }));
    in {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            gnumake
            pkg-config
            sdl3
            glslang        # GLSL -> SPIR-V (committed .spv)
            vulkan-loader
            vulkan-tools   # vulkaninfo for driver debugging
            lua5_4         # tooling scripts only; the PAL embeds vendored lua
            spleen         # bitmap font source for the M1 font bake
            gdb
          ];
          # Pinned software-vulkan ICD: the ONLY driver goldens may use (D007).
          # Usage: VK_DRIVER_FILES="$COSMIC_LVP_ICD" bin/cosmic ...
          COSMIC_LVP_ICD = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json";
          COSMIC_SPLEEN_DIR = "${pkgs.spleen}/share/fonts/misc";
        };
      });

      # Three explicit distribution shapes share the compiled PAL but stage
      # different allowlists. Dev carries fixtures/tests; editor carries only
      # the picker and intentional demos; play is staged by the packager below.
      packages = forAll (pkgs: rec {
        cosmic-dev = pkgs.stdenv.mkDerivation {
          pname = "cosmic2d-dev";
          version = "0.1-m1";
          src = self;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.glslang ];
          buildInputs = [ pkgs.sdl3 ];
          buildPhase = "make -C pal";
          installPhase = ''
            bash tools/stage-manifest.sh . dist/manifests/dev.txt $out
            # root launchers (the human's ask): extract -> run the one you want.
            # The binary auto-chdirs to the dir holding engine/, so a launcher
            # beside engine/ resolves projects/ fine; argv[0]'s basename routes
            # (main.lua resolve_project): cosmic2d-editor -> the project picker
            # (opens projects in the editor), demo -> projects/demo locked.
            cp $out/bin/cosmic $out/cosmic2d-editor
            cp $out/bin/cosmic $out/demo
          '';
        };

        cosmic-editor = cosmic-dev.overrideAttrs (old: {
          pname = "cosmic2d-editor";
          installPhase = builtins.replaceStrings
            [ "dist/manifests/dev.txt" ] [ "dist/manifests/editor.txt" ]
            old.installPhase;
        });
        cosmic = cosmic-editor;

        # M6 — Windows cross build (mingw-w64 + cross SDL3, both from nixpkgs;
        # the PAL is pure SDL3 so the C ports as-is). The cross stdenv sets
        # CC/PKG_CONFIG/PKG_CONFIG_PATH; we only add EXE + a console subsystem
        # (-mconsole, so stderr/headless work) and static libgcc. Output is a
        # self-contained tree: cosmic.exe + SDL3.dll beside engine/projects/.
        cosmic-windows-dev = let cross = pkgs.pkgsCross.mingwW64;
        in cross.stdenv.mkDerivation {
          pname = "cosmic2d-windows-dev";
          version = "0.1-m6";
          src = self;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.glslang ];
          buildInputs = [ cross.sdl3 ];
          dontStrip = true;
          buildPhase = ''
            make -C pal EXE=.exe \
              LDFLAGS="-mconsole -static-libgcc -static-libstdc++"
          '';
          installPhase = ''
            bash tools/stage-manifest.sh . dist/manifests/dev.txt $out
            cp ${cross.sdl3.out}/bin/SDL3.dll $out/bin/
          '';
          # the mingw stdenv symlinks runtime DLLs (libmcfgthread) into bin/;
          # Windows can't follow a /nix/store symlink, so materialize real files
          postFixup = ''
            for f in $out/bin/*.dll; do
              if [ -L "$f" ]; then t=$(readlink -f "$f"); rm "$f"; cp "$t" "$f"; fi
            done
            # root launchers (the human's ask): extract -> double-click the one
            # you want. argv[0]'s basename routes (main.lua resolve_project):
            # cosmic2d-editor.exe -> the project picker (opens in the editor),
            # demo.exe -> projects/demo locked to play. The runtime DLLs go
            # beside them (Windows loads DLLs from the launching exe's own dir).
            cp $out/bin/cosmic.exe $out/cosmic2d-editor.exe
            cp $out/bin/cosmic.exe $out/demo.exe
            cp $out/bin/*.dll $out/
          '';
        };

        cosmic-windows-editor = cosmic-windows-dev.overrideAttrs (old: {
          pname = "cosmic2d-windows-editor";
          installPhase = builtins.replaceStrings
            [ "dist/manifests/dev.txt" ] [ "dist/manifests/editor.txt" ]
            old.installPhase;
        });
        cosmic-windows = cosmic-windows-editor;
        default = cosmic;
      });

      # The golden suite (D007: pinned lavapipe, headless): selftest
      # cartridge + byte-exact replay of every committed trace + pixel
      # goldens (M5: a .args sidecar holds one argv token per line; the
      # fresh --shot must byte-match the committed .png — same encoder,
      # same lavapipe, so cmp is exact). Shared by `nix run .#test` and
      # `nix flake check` (checks.goldens).
      apps = forAll (pkgs:
        let
          cosmic = self.packages.${pkgs.system}.cosmic-dev;
          suite = ''
            export VK_DRIVER_FILES=${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json
            export LD_LIBRARY_PATH=${pkgs.vulkan-loader}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            cd ${cosmic}
            fail=0
            echo "== release manifests =="
            ./tests/release-manifests.sh || fail=1
            echo "== selftest =="
            ./bin/cosmic projects/selftest --headless --frames 1 || fail=1
            for t in tests/traces/*.ctrace; do
              proj=$(cat "''${t%.ctrace}.project") # sidecar names the cartridge
              echo "== verify $t ($proj) =="
              ./bin/cosmic "$proj" --verify "$t" || fail=1
            done
            for a in tests/pixels/*.args; do
              mapfile -t args < "$a"
              echo "== pixels ''${a} =="
              shot="''${TMPDIR:-/tmp}/cosmic-pixel.png"
              if ./bin/cosmic "''${args[@]}" --shot "$shot" >/dev/null \
                 && cmp -s "$shot" "''${a%.args}.png"; then
                echo "pixel match"
              else
                echo "PIXEL MISMATCH (or run failed): ''${a%.args}.png"
                fail=1
              fi
            done
            if [ "$fail" = 0 ]; then echo "ALL GREEN"; else echo "FAILURES"; fi
            exit "$fail"
          '';
          runner = pkgs.writeShellApplication {
            name = "cosmic-test";
            runtimeInputs = [ pkgs.diffutils ];
            text = suite;
          };

          # `nix run .#package -- <project> [win|linux]` — stage ONE project
          # into a standalone, play-locked, self-contained bundle for a
          # player: the engine runtime + that project only (no tests, no
          # sibling projects), with the launcher renamed so it boots locked
          # to play mode (the R5 convention, D052). Windows is a
          # self-contained zip (SDL3.dll bundled); linux is a tar.gz that
          # needs SDL3 on the box (or run via nix). Output lands in $PWD.
          packager = pkgs.writeShellApplication {
            name = "cosmic-package";
            runtimeInputs = with pkgs; [ coreutils findutils zip gnutar gzip ];
            text = ''
              name="''${1:-demo}"
              target="''${2:-win}"
              win="${self.packages.${pkgs.system}.cosmic-windows-dev}"
              lin="${self.packages.${pkgs.system}.cosmic-dev}"
              src="${self}"
              case "$target" in
                win|windows) base="$win"; exe="cosmic.exe"; newexe="$name.exe"; suffix="windows";;
                linux)       base="$lin"; exe="cosmic";     newexe="$name";     suffix="linux";;
                *) echo "usage: package <project> [win|linux]"; exit 1;;
              esac
              if [ ! -f "$base/projects/$name/project.lua" ]; then
                echo "no project 'projects/$name' in the build tree"; exit 1
              fi
              work="$(mktemp -d)"; root="$work/$name"
              mkdir -p "$root"
              bash "$src/tools/stage-manifest.sh" "$base" \
                "$src/dist/manifests/play.txt" "$root" "$name"
              chmod -R u+w "$root"
              # rename the launcher -> boots projects/<name> locked to play mode
              mv "$root/bin/$exe" "$root/bin/$newexe"
              chmod +x "$root/bin/$newexe" # --no-preserve dropped the +x bit
              # Tooling remains deliberately available in an exported game;
              # only the named launcher defaults to locked play mode.
              cp "$root/bin/$newexe" "$root/bin/cosmic2d-editor''${exe##cosmic}"
              cp "$src/README.md" "$root/README.md" 2>/dev/null || true
              cp "$src/LICENSE" "$root/LICENSE" 2>/dev/null || true
              printf 'cosmic2d — %s\n\nRun  bin/%s  to play.\n' "$name" "$newexe" > "$root/PLAY.txt"
              out="$PWD/$name-$suffix"
              if [ "$suffix" = windows ]; then
                ( cd "$work" && zip -r -q "$out.zip" "$name" ); echo "packaged -> $out.zip"
              else
                tar czf "$out.tar.gz" -C "$work" "$name"; echo "packaged -> $out.tar.gz"
              fi
              rm -rf "$work"
            '';
          };
        in {
          test = {
            type = "app";
            program = "${runner}/bin/cosmic-test";
          };
          package = {
            type = "app";
            program = "${packager}/bin/cosmic-package";
          };
        });

      # nix flake check — the same suite as a sandboxed derivation
      checks = forAll (pkgs: {
        goldens = pkgs.runCommand "cosmic-goldens" { } ''
          set -o pipefail
          ${self.apps.${pkgs.system}.test.program} | tee $out
        '';
      });
    };
}
