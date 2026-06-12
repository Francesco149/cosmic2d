{
  description = "pettan2d — tiny 2d pixel-art engine / fantasy console";

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
          # Usage: VK_DRIVER_FILES="$PETTAN_LVP_ICD" bin/pettan ...
          PETTAN_LVP_ICD = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json";
          PETTAN_SPLEEN_DIR = "${pkgs.spleen}/share/fonts/misc";
        };
      });

      # the console, built from tracked sources: bin/ + engine/ + projects/
      # + tests/ laid out exactly like the repo (binary paths are relative)
      packages = forAll (pkgs: rec {
        pettan = pkgs.stdenv.mkDerivation {
          pname = "pettan2d";
          version = "0.1-m1";
          src = self;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.glslang ];
          buildInputs = [ pkgs.sdl3 ];
          buildPhase = "make -C pal";
          installPhase = ''
            mkdir -p $out/pal
            cp -r bin engine projects tests $out/
            cp -r pal/shaders $out/pal/
          '';
        };
        default = pettan;
      });

      # The golden suite (D007: pinned lavapipe, headless): selftest
      # cartridge + byte-exact replay of every committed trace + pixel
      # goldens (M5: a .args sidecar holds one argv token per line; the
      # fresh --shot must byte-match the committed .png — same encoder,
      # same lavapipe, so cmp is exact). Shared by `nix run .#test` and
      # `nix flake check` (checks.goldens).
      apps = forAll (pkgs:
        let
          pettan = self.packages.${pkgs.system}.pettan;
          suite = ''
            export VK_DRIVER_FILES=${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json
            export LD_LIBRARY_PATH=${pkgs.vulkan-loader}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            cd ${pettan}
            fail=0
            echo "== selftest =="
            ./bin/pettan projects/selftest --headless --frames 1 || fail=1
            for t in tests/traces/*.ptrace; do
              proj=$(cat "''${t%.ptrace}.project") # sidecar names the cartridge
              echo "== verify $t ($proj) =="
              ./bin/pettan "$proj" --verify "$t" || fail=1
            done
            for a in tests/pixels/*.args; do
              mapfile -t args < "$a"
              echo "== pixels ''${a} =="
              shot="''${TMPDIR:-/tmp}/pettan-pixel.png"
              if ./bin/pettan "''${args[@]}" --shot "$shot" >/dev/null \
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
            name = "pettan-test";
            runtimeInputs = [ pkgs.diffutils ];
            text = suite;
          };
        in {
          test = {
            type = "app";
            program = "${runner}/bin/pettan-test";
          };
        });

      # nix flake check — the same suite as a sandboxed derivation
      checks = forAll (pkgs: {
        goldens = pkgs.runCommand "pettan-goldens" { } ''
          set -o pipefail
          ${self.apps.${pkgs.system}.test.program} | tee $out
        '';
      });
    };
}
