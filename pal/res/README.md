# application resources

`cosmic2d.png` is the canonical 256 px application mark. `cosmic2d.ico`
contains 256, 128, 64, 48, 32, 24, and 16 px entries for Windows. Rebuild the
ICO after changing the PNG with:

```sh
nix shell nixpkgs#imagemagick -c magick cosmic2d.png \
  -define icon:auto-resize=256,128,64,48,32,24,16 cosmic2d.ico
```

`windows.rc` binds that icon and the Explorer version fields into both the GUI
and console executables. The public version string comes from the repository
root `VERSION`; the numeric Windows tuple in the RC file must move with it.

These resources identify the engine and its authoring/diagnostic entrances.
A packaged game's root Windows entrance is a small delegating executable built
from the project's validated `icon`/`name`/`version` metadata; the carried
engine binaries keep this truthful cosmic2d identity. PAL API v12 also applies
the project's PNG to the live OS window on both supported platforms.
