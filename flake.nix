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

      # apps.test (golden suite) lands at M1.
    };
}
