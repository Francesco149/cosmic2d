# Packaged license material

Nix-built artifacts populate this directory with exact license and notice
files from the embedded dependencies and the selected platform's pinned
runtime sources:

- `common/`
- `linux-runtime/` or `windows-runtime/`

This source checkout keeps the originals under `pal/vendor/` and beside the
baked Spleen font in `engine/cm/assets/`. See `THIRD_PARTY_NOTICES.md` for the
inventory, checksum instructions, and unsigned-alpha policy.
