# vendored third-party code

| dir | what | version | license | provenance | local changes |
| --- | --- | --- | --- | --- | --- |
| `lua/` | Lua, embedded in the PAL | 5.4.7 | MIT (see `lua/src/lua.h` tail) | lua.org tarball via nixpkgs `lua5_4.src` | none — deterministic string-hash seed is injected as a build define (D003); `doc/` and upstream `Makefile` dropped |
| `stb/` | stb_image, stb_image_write, stb_vorbis | image 2.28, image_write 1.16, vorbis 1.22 | public domain / MIT dual | nixpkgs `stb` @ 5736b15 | none |
| `dr_libs/` | dr_wav, dr_mp3 (including minimp3) | wav 0.14.6, mp3 0.7.4 | public domain / MIT-0; minimp3 CC0 | upstream single-file headers | none |
| `imgui/` | Dear ImGui core, SDL3 + SDL_GPU backends, stdlib helper | 1.92.4 | MIT (`imgui/LICENSE.txt`) | upstream release plus SDL_GPU backend | `imconfig.h`; demo windows omitted |
| `fonts/` | Inter Variable, JetBrains Mono Regular | pinned font files | OFL-1.1 (`OFL-*.txt`) | upstream font releases | none |

Policy: D011/D049 in docs/DECISIONS.md. Keep this table accurate on every
bump. Packaged copies and platform-runtime notices are assembled under
`LICENSES/`; the public inventory is `THIRD_PARTY_NOTICES.md`.
