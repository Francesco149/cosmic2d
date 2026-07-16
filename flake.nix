{
  description = "cosmic2d — tiny 2d pixel-art engine / fantasy console";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      releaseVersion = nixpkgs.lib.removeSuffix "\n" (builtins.readFile ./VERSION);
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
      packages = forAll (pkgs:
        let
          oneLicense = license:
            if builtins.isAttrs license then
              if license ? spdxId then license.spdxId
              else if license ? shortName then license.shortName
              else if license ? fullName then license.fullName
              else "custom"
            else toString license;
          licenseNames = license:
            if builtins.isList license
            then pkgs.lib.concatMapStringsSep ", " oneLicense license
            else oneLicense license;
          component = name: package: { inherit name package; };

          # Release artifacts reproduce upstream legal material from the exact
          # sources pinned by flake.lock. Source archives are build inputs only;
          # the output keeps the small notice files, not dependency sources.
          collectSourceNotices = pname: components:
            pkgs.runCommand pname {
              nativeBuildInputs = with pkgs; [
                coreutils findutils gnutar gzip bzip2 xz
              ];
            } ''
              mkdir -p $out
              printf '%s\n' 'Pinned runtime dependency notices' \
                > $out/README.txt
              printf 'component\tversion\tdeclared package licenses\n' \
                >> $out/README.txt
              ${pkgs.lib.concatMapStringsSep "\n" (entry: ''
                printf '%s\t%s\t%s\n' \
                  ${pkgs.lib.escapeShellArg entry.name} \
                  ${pkgs.lib.escapeShellArg (toString entry.package.version)} \
                  ${pkgs.lib.escapeShellArg
                    (licenseNames (entry.package.meta.license or "not-declared"))} \
                  >> $out/README.txt
              '') components}

              collect() {
                label=$1
                source=$2
                scratch="$TMPDIR/$label"
                if [ -d "$source" ]; then
                  scan=$source
                else
                  mkdir -p "$scratch"
                  tar -xf "$source" -C "$scratch"
                  scan=$scratch
                fi

                mapfile -d "" files < <(
                  find "$scan" -maxdepth 5 -type f \
                    \( -iname 'COPYING*' -o -iname 'LICENSE*' \
                       -o -iname 'NOTICE*' -o -iname 'COPYRIGHT*' \
                       -o -iname 'AUTHORS*' \) \
                    -size -2097152c -print0
                )
                if [ "''${#files[@]}" -eq 0 ]; then
                  echo "$label has no recognizable upstream license/notice files" >&2
                  exit 1
                fi
                for file in "''${files[@]}"; do
                  relative="''${file#"$scan"/}"
                  install -Dm644 "$file" "$out/$label/$relative"
                done
              }

              ${pkgs.lib.concatMapStringsSep "\n" (entry: ''
                collect \
                  ${pkgs.lib.escapeShellArg
                    "${entry.name}-${toString entry.package.version}"} \
                  ${pkgs.lib.escapeShellArg (toString entry.package.src)}
              '') components}
            '';

          commonLicenses = pkgs.runCommand "cosmic2d-common-licenses-${releaseVersion}" {
            nativeBuildInputs = [ pkgs.gnugrep ];
          } ''
            mkdir -p $out
            printf '%s\n' \
              'Embedded cosmic2d dependency notices' \
              'The component inventory is in THIRD_PARTY_NOTICES.md at the artifact root.' \
              > $out/README.txt
            cp ${self}/pal/vendor/imgui/LICENSE.txt $out/Dear-ImGui.txt
            cp ${self}/pal/vendor/fonts/OFL-Inter.txt $out/Inter-OFL-1.1.txt
            cp ${self}/pal/vendor/fonts/OFL-JetBrainsMono.txt \
              $out/JetBrains-Mono-OFL-1.1.txt
            sed -n '499,520p' ${self}/pal/vendor/lua/src/lua.h > $out/Lua.txt
            sed -n '7947,7987p' ${self}/pal/vendor/stb/stb_image.h > $out/stb.txt
            sed -n '9100,9148p' ${self}/pal/vendor/dr_libs/dr_wav.h > $out/dr_wav.txt
            sed -n '5357,5412p' ${self}/pal/vendor/dr_libs/dr_mp3.h > $out/dr_mp3.txt
            sed -n '/^Spleen 2\.1\.0/,/^POSSIBILITY OF SUCH DAMAGE\.]]/p' \
              ${self}/engine/cm/assets/font_5x8.lua \
              | sed '$s/]]$//' > $out/Spleen.txt
            for notice in $out/*.txt; do
              if [ ! -s "$notice" ]; then
                echo "empty embedded dependency notice: $notice" >&2
                exit 1
              fi
            done
            grep -Fq 'Lua.org, PUC-Rio' $out/Lua.txt
            grep -Fq 'Copyright (c) 2017 Sean Barrett' $out/stb.txt
            grep -Fq 'Copyright 2023 David Reid' $out/dr_wav.txt
            grep -Fq 'minimp3' $out/dr_mp3.txt
            grep -Fq 'Copyright (c) 2018-2024, Frederic Cambus' $out/Spleen.txt
            grep -Fq 'Copyright (c) 2014-2025 Omar Cornut' $out/Dear-ImGui.txt
            grep -Fq 'SIL OPEN FONT LICENSE Version 1.1' $out/Inter-OFL-1.1.txt
            grep -Fq 'SIL OPEN FONT LICENSE Version 1.1' \
              $out/JetBrains-Mono-OFL-1.1.txt
          '';

          linuxRuntimeLicenses = collectSourceNotices
            "cosmic2d-linux-runtime-licenses-${releaseVersion}" [
              (component "SDL3" pkgs.sdl3)
              (component "Vulkan-Loader" pkgs.vulkan-loader)
              (component "GCC-Runtime" pkgs.gcc.cc)
              (component "alsa-lib" pkgs.alsa-lib)
              (component "libX11" pkgs.libx11)
              (component "libXext" pkgs.libxext)
              (component "libXcursor" pkgs.libxcursor)
              (component "libXi" pkgs.libxi)
              (component "libXfixes" pkgs.libxfixes)
              (component "libXrandr" pkgs.libxrandr)
              (component "libXScrnSaver" pkgs.libxscrnsaver)
              (component "libXtst" pkgs.libxtst)
              (component "libXrender" pkgs.libxrender)
              (component "libXau" pkgs.libxau)
              (component "libXdmcp" pkgs.libxdmcp)
              (component "libxcb" pkgs.libxcb)
              (component "libusb" pkgs.libusb1)
              (component "JACK2" pkgs.libjack2)
              (component "PipeWire" pkgs.pipewire)
              (component "PulseAudio" pkgs.pulseaudio)
              (component "libdrm" pkgs.libdrm)
              (component "Mesa" pkgs.mesa)
              (component "Wayland" pkgs.wayland)
              (component "libglvnd" pkgs.libglvnd)
              (component "libxkbcommon" pkgs.libxkbcommon)
              (component "libdecor" pkgs.libdecor)
              (component "systemd" pkgs.systemd)
              (component "libsamplerate" pkgs.libsamplerate)
              (component "D-Bus" pkgs.dbus)
              (component "libffi" pkgs.libffi)
              (component "libsndfile" pkgs.libsndfile)
              (component "FLAC" pkgs.flac)
              (component "libvorbis" pkgs.libvorbis)
              (component "Opus" pkgs.libopus)
              (component "libogg" pkgs.libogg)
              (component "mpg123" pkgs.mpg123)
              (component "LAME" pkgs.lame)
            ];

          windowsRuntimeLicenses = collectSourceNotices
            "cosmic2d-windows-runtime-licenses-${releaseVersion}" [
              (component "SDL3" pkgs.sdl3)
              (component "GCC-Runtime" pkgs.gcc.cc)
              (component "mcfgthread"
                pkgs.pkgsCross.mingwW64.windows.mcfgthreads)
            ];
        in rec {
        # nixpkgs makes SDL's optional Vulkan/X11 loaders point directly into
        # the Nix store. That is useful inside Nix, but those compiled-in
        # paths make a bundled release unusable after extraction elsewhere.
        # Keep the normal package untouched and restore SDL's upstream soname
        # lookups only for the portable build.
        sdl3-portable = pkgs.sdl3.overrideAttrs (old: {
          pname = "sdl3-portable";
          postPatch = (old.postPatch or "") + ''
            sed -i \
              -e 's|/nix/store/[^" ]*/lib/libvulkan\.so|libvulkan.so|g' \
              -e 's|/nix/store/[^" ]*/lib/libX11-xcb\.so|libX11-xcb.so|g' \
              src/video/x11/SDL_x11vulkan.c \
              src/video/wayland/SDL_waylandvulkan.c \
              src/video/offscreen/SDL_offscreenvulkan.c \
              src/video/kmsdrm/SDL_kmsdrmvulkan.c \
              src/video/vivante/SDL_vivantevulkan.c \
              src/video/android/SDL_androidvulkan.c
          '';
        });

        cosmic-dev = pkgs.stdenv.mkDerivation {
          pname = "cosmic2d-dev";
          version = releaseVersion;
          src = self;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.glslang ];
          buildInputs = [ pkgs.sdl3 ];
          buildPhase = "make -C pal";
          installPhase = ''
            bash tools/stage-manifest.sh . dist/manifests/dev.txt $out
            mkdir -p $out/LICENSES
            cp -r --no-preserve=mode ${commonLicenses} $out/LICENSES/common
            cp -r --no-preserve=mode ${linuxRuntimeLicenses} \
              $out/LICENSES/linux-runtime
            # root launchers (the human's ask): extract -> run the one you want.
            # The binary auto-chdirs to the dir holding engine/, so a launcher
            # beside engine/ resolves projects/ fine; argv[0]'s basename routes
            # (main.lua resolve_project): cosmic2d-editor -> the project picker
            # (opens projects in the editor), demo -> projects/demo locked.
            cp $out/bin/cosmic $out/cosmic2d-editor
            cp $out/bin/cosmic $out/demo
          '';
          postFixup = ''
            bash ${self}/tools/release-integrity.sh tree $out linux-nix
          '';
        };

        cosmic-editor = cosmic-dev.overrideAttrs (old: {
          pname = "cosmic2d-editor";
          installPhase = builtins.replaceStrings
            [ "dist/manifests/dev.txt" ] [ "dist/manifests/editor.txt" ]
            old.installPhase;
        });
        cosmic = cosmic-editor;

        cosmic-portable-editor = cosmic-editor.overrideAttrs (_: {
          pname = "cosmic2d-portable-editor";
          buildInputs = [ sdl3-portable ];
        });

        # Portable Linux editor tree. Keep glibc as the supported-machine ABI,
        # but carry every other linked library and resolve it relative to the
        # executable. Stripping also removes build paths from debug sections.
        cosmic-linux-portable = pkgs.runCommand "cosmic2d-linux-portable-${releaseVersion}" {
          nativeBuildInputs = [ pkgs.patchelf pkgs.binutils pkgs.findutils ];
        } ''
          cp -r --no-preserve=mode ${cosmic-portable-editor} $out
          chmod -R u+w $out
          chmod +x $out/bin/cosmic $out/cosmic2d-editor $out/demo
          mkdir -p $out/lib

          # ldd reports SDL's complete transitive closure. SDL_GPU dlopens the
          # Vulkan loader, so carry it too; the host still supplies its ICD.
          ldd ${cosmic-portable-editor}/bin/cosmic \
            | sed -n 's|.*=> \(/nix/store/[^ ]*\).*|\1|p' \
            | while read -r lib; do
                case "$(basename "$lib")" in
                  ld-linux-*|libc.so.*|libm.so.*|libmvec.so.*|libpthread.so.*|librt.so.*|libdl.so.*) ;;
                  *) cp -L "$lib" "$out/lib/$(basename "$lib")" ;;
                esac
              done
          cp -L ${pkgs.vulkan-loader}/lib/libvulkan.so.1 $out/lib/
          chmod -R u+w $out

          while IFS= read -r f; do
            if ${pkgs.binutils}/bin/readelf -h "$f" >/dev/null 2>&1; then
              ${pkgs.binutils}/bin/strip --strip-unneeded "$f" 2>/dev/null || true
              case "$f" in
                */bin/*)
                  ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN/../lib' "$f"
                  ${pkgs.patchelf}/bin/patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$f"
                  ;;
                */cosmic2d-editor|*/demo)
                  ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN/lib' "$f"
                  ${pkgs.patchelf}/bin/patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$f"
                  ;;
                *) ${pkgs.patchelf}/bin/patchelf --set-rpath '$ORIGIN' "$f" ;;
              esac
            fi
          done < <(find $out -type f)

          while IFS= read -r f; do
            if ${pkgs.binutils}/bin/readelf -h "$f" >/dev/null 2>&1; then
              metadata="$(${pkgs.patchelf}/bin/patchelf --print-rpath "$f" 2>/dev/null || true)
$(${pkgs.patchelf}/bin/patchelf --print-interpreter "$f" 2>/dev/null || true)"
              if grep -F '/nix/store/' <<<"$metadata"; then
                echo "ELF runtime metadata still names the Nix store: $f" >&2
                exit 1
              fi
            fi
          done < <(find $out -type f)

          bash ${self}/tools/release-integrity.sh tree $out linux
        '';

        # M6 — Windows cross build (mingw-w64 + cross SDL3, both from nixpkgs;
        # the PAL is pure SDL3 so the C ports as-is). Link the shared object
        # tree twice: cosmic.exe is a GUI-subsystem application for normal
        # double-click launches, while cosmic-console.exe retains a console
        # for diagnostics, headless runs, and CI. Both keep static compiler
        # runtimes; SDL3 remains the only adjacent runtime DLL.
        cosmic-windows-dev = let cross = pkgs.pkgsCross.mingwW64;
        in cross.stdenv.mkDerivation {
          pname = "cosmic2d-windows-dev";
          version = releaseVersion;
          src = self;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.glslang ];
          buildInputs = [ cross.sdl3 ];
          dontStrip = true;
          buildPhase = ''
            make -C pal EXE=.exe BIN=../bin/cosmic-console.exe \
              LDFLAGS="-mconsole -static-libgcc -static-libstdc++"
            make -C pal EXE=.exe BIN=../bin/cosmic.exe \
              LDFLAGS="-mwindows -static-libgcc -static-libstdc++"
          '';
          installPhase = ''
            bash tools/stage-manifest.sh . dist/manifests/dev.txt $out
            mkdir -p $out/LICENSES
            cp -r --no-preserve=mode ${commonLicenses} $out/LICENSES/common
            cp -r --no-preserve=mode ${windowsRuntimeLicenses} \
              $out/LICENSES/windows-runtime
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

            # Catch regressions where a normal launcher opens a terminal, or
            # the diagnostic binary loses stderr/stdout console attachment.
            gui_subsystem="$(${cross.stdenv.cc.bintools.targetPrefix}objdump -p \
              $out/bin/cosmic.exe | sed -n 's/^[[:space:]]*Subsystem[[:space:]]*//p')"
            console_subsystem="$(${cross.stdenv.cc.bintools.targetPrefix}objdump -p \
              $out/bin/cosmic-console.exe | sed -n 's/^[[:space:]]*Subsystem[[:space:]]*//p')"
            case "$gui_subsystem" in *"Windows GUI"*) ;; *)
              echo "cosmic.exe is not a Windows GUI executable: $gui_subsystem" >&2; exit 1;;
            esac
            case "$console_subsystem" in *"Windows CUI"*) ;; *)
              echo "cosmic-console.exe is not a Windows console executable: $console_subsystem" >&2; exit 1;;
            esac

            # Every shipped entrance is a copy of one of these two binaries,
            # but assert each staged file: Explorer identity is a release
            # property, not an incidental linker detail.
            expected_version="$(tr -d '\r\n' < VERSION)"
            for exe in $out/bin/cosmic.exe $out/bin/cosmic-console.exe \
                       $out/cosmic2d-editor.exe $out/demo.exe; do
              resource_dump="$(${cross.stdenv.cc.bintools.targetPrefix}objdump -p "$exe")"
              for signature in \
                "The .rsrc Resource Directory section:" \
                "Entry: ID: 0x000003" \
                "Entry: ID: 0x00000e" \
                "Entry: ID: 0x000010"; do
                if ! grep -Fq "$signature" <<<"$resource_dump"; then
                  echo "$exe lacks Windows resource signature: $signature" >&2
                  exit 1
                fi
              done
              version_strings="$(${cross.stdenv.cc.bintools.targetPrefix}strings -el "$exe")"
              for signature in "FileDescription" "cosmic2d 2D game engine" \
                               "ProductName" "cosmic2d" "ProductVersion" \
                               "$expected_version"; do
                if ! grep -Fxq "$signature" <<<"$version_strings"; then
                  echo "$exe lacks Windows version string: $signature" >&2
                  exit 1
                fi
              done
            done

            bash ${self}/tools/release-integrity.sh tree $out windows
          '';
        };

        cosmic-windows-editor = cosmic-windows-dev.overrideAttrs (old: {
          pname = "cosmic2d-windows-editor";
          installPhase = builtins.replaceStrings
            [ "dist/manifests/dev.txt" ] [ "dist/manifests/editor.txt" ]
            old.installPhase;
        });
        cosmic-windows = cosmic-windows-editor;

        # Download-shaped public editor artifacts. The underlying trees have
        # already completed every fixup and own their extracted-file manifest;
        # these derivations only put that final tree under one archive root and
        # add the sibling download checksum.
        cosmic-linux-release = pkgs.runCommand
          "cosmic2d-linux-release-${releaseVersion}" {
            nativeBuildInputs = [ pkgs.coreutils pkgs.gnutar pkgs.gzip ];
          } ''
            mkdir -p $out work/cosmic2d
            cp -r ${cosmic-linux-portable}/. work/cosmic2d/
            chmod -R u+w work/cosmic2d
            tar czf $out/cosmic2d-linux.tar.gz -C work cosmic2d
            bash ${self}/tools/release-integrity.sh archive \
              $out/cosmic2d-linux.tar.gz
          '';

        cosmic-windows-release = pkgs.runCommand
          "cosmic2d-windows-release-${releaseVersion}" {
            nativeBuildInputs = [ pkgs.coreutils pkgs.zip ];
          } ''
            mkdir -p $out work/cosmic2d
            cp -r ${cosmic-windows-editor}/. work/cosmic2d/
            chmod -R u+w work/cosmic2d
            (cd work && zip -X -r -q $out/cosmic2d-windows.zip cosmic2d)
            bash ${self}/tools/release-integrity.sh archive \
              $out/cosmic2d-windows.zip
          '';
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
            runtimeInputs = [ pkgs.diffutils pkgs.findutils ];
            text = suite;
          };

          # `nix run .#package -- <project> [win|linux]` — stage ONE project
          # into a standalone, play-locked, self-contained bundle for a
          # player: the engine runtime + that project only (no tests, no
          # sibling projects), with the launcher renamed so it boots locked
          # to play mode (the R5 convention, D052). Windows is a
          # self-contained archives. Linux bundles non-glibc libraries with a
          # relative RPATH; the supported host ABI is x86_64 glibc Linux.
          packager = pkgs.writeShellApplication {
            name = "cosmic-package";
            runtimeInputs = with pkgs; [ coreutils findutils zip gnutar gzip ];
            text = ''
              name="''${1:-demo}"
              target="''${2:-win}"
              win="${self.packages.${pkgs.system}.cosmic-windows-dev}"
              lin="${self.packages.${pkgs.system}.cosmic-linux-portable}"
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
              if [ "$suffix" = linux ]; then cp -r "$base/lib" "$root/lib"; fi
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
              bash "$src/tools/release-integrity.sh" tree "$root" "$suffix"
              out="$PWD/$name-$suffix"
              if [ "$suffix" = windows ]; then
                ( cd "$work" && zip -r -q "$out.zip" "$name" )
                bash "$src/tools/release-integrity.sh" archive "$out.zip"
                echo "packaged -> $out.zip (+ .sha256)"
              else
                tar czf "$out.tar.gz" -C "$work" "$name"
                bash "$src/tools/release-integrity.sh" archive "$out.tar.gz"
                echo "packaged -> $out.tar.gz (+ .sha256)"
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
