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

      # nix run .#test — the golden suite (D007: pinned lavapipe, headless):
      # selftest cartridge + byte-exact replay of every committed trace
      apps = forAll (pkgs:
        let
          pettan = self.packages.${pkgs.system}.pettan;
          runner = pkgs.writeShellApplication {
            name = "pettan-test";
            text = ''
              export VK_DRIVER_FILES=${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json
              export LD_LIBRARY_PATH=${pkgs.vulkan-loader}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
              cd ${pettan}
              fail=0
              echo "== selftest =="
              ./bin/pettan projects/selftest --headless --frames 1 || fail=1
              for t in tests/traces/*.ptrace; do
                name=$(basename "$t" .ptrace)
                case "$name" in
                  sandbox) proj=projects/sandbox ;;
                  *) proj=tests/cartridges/$name ;;
                esac
                echo "== verify $t ($proj) =="
                ./bin/pettan "$proj" --verify "$t" || fail=1
              done
              if [ "$fail" = 0 ]; then echo "ALL GREEN"; else echo "FAILURES"; fi
              exit "$fail"
            '';
          };
        in {
          test = {
            type = "app";
            program = "${runner}/bin/pettan-test";
          };
        });
    };
}
