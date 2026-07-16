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
