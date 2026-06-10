# vendored third-party code

| dir | what | version | license | provenance | local changes |
| --- | --- | --- | --- | --- | --- |
| `lua/` | Lua, embedded in the PAL | 5.4.7 | MIT (see `lua/src/lua.h` tail) | lua.org tarball via nixpkgs `lua5_4.src` | none — deterministic string-hash seed is injected as a build define (D003); `doc/` and upstream `Makefile` dropped |
| `stb/` | stb_image, stb_image_write | nothings/stb @ 5736b15 | public domain / MIT dual | nixpkgs `stb` | none |

Policy: D011 in docs/DECISIONS.md. Keep this table accurate on every bump.
