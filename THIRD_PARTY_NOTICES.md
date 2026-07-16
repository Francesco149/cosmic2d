# cosmic2d third-party notices

cosmic2d itself is distributed under the MIT license in `LICENSE`. This file
identifies third-party work included in packaged builds. It is attribution,
not an endorsement by the named authors or projects.

## Embedded engine dependencies

| component | version in this source tree | chosen/distributed license |
| --- | --- | --- |
| Lua | 5.4.7 | MIT |
| Dear ImGui | 1.92.4 | MIT |
| stb_image / stb_image_write / stb_vorbis | vendored revisions named in their headers | MIT option |
| dr_wav / dr_mp3 and minimp3 | vendored revisions named in their headers | MIT-0; minimp3 is CC0 |
| Spleen bitmap font | 2.1.0 | BSD 3-Clause |
| Inter Variable font | bundled font revision | SIL Open Font License 1.1 |
| JetBrains Mono font | bundled font revision | SIL Open Font License 1.1 |

Packaged artifacts reproduce the complete notices for these components under
`LICENSES/common/`. The original vendored sources and notices remain
inspectable in a source checkout under `pal/vendor/`; Spleen attribution is
also embedded beside the baked font data in `engine/cm/assets/`.

## Platform runtime dependencies

Windows artifacts carry SDL3 and mcfgthread DLLs and contain statically linked
GCC runtime code. Portable Linux artifacts carry SDL3, the Vulkan loader, the
GCC runtimes, and SDL's pinned audio/window/input dependency closure. The exact
carried filenames are recorded in `RUNTIME-LIBRARIES.txt`. Their pinned
versions and unmodified upstream `LICENSE`, `COPYING`, `NOTICE`, `COPYRIGHT`,
and `AUTHORS` material are collected under `LICENSES/windows-runtime/` or
`LICENSES/linux-runtime/` at package-build time. Those copied upstream files,
not a shortened license label, are authoritative.

The dependency set is derived from the locked Nix build. A dependency update
must regenerate this material; packaging fails if an expected source has no
recognizable licensing or notice file.

## Artifact integrity and unsigned-alpha policy

Each extracted release tree contains `SHA256SUMS`, generated after the last
packaging mutation and covering every regular file except the manifest itself.
Run it from the extracted folder:

```sh
sha256sum --check SHA256SUMS
```

Each `.zip` or `.tar.gz` made by `nix run .#package` also has a sibling
`<archive>.sha256`. Verify that sidecar before extraction. On Windows,
PowerShell's `Get-FileHash <archive> -Algorithm SHA256` prints the value to
compare with the sidecar.

To verify the extracted tree with Windows PowerShell, run this from its root:

```powershell
$ok = $true
Get-Content .\SHA256SUMS | ForEach-Object {
  $expected, $path = $_ -split '  ', 2
  $path = $path.Substring(2).Replace('/', '\')
  $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
  if ($actual -ne $expected) { Write-Error "checksum mismatch: $path"; $ok = $false }
}
if (-not $ok) { throw 'release verification failed' }
```

**Alpha builds are intentionally unsigned.** There is currently no cosmic2d
Authenticode certificate, detached archive signature, or published signing
identity. SHA-256 detects corruption or alteration only when the expected hash
or manifest was obtained through a trusted channel; a checksum shipped beside
tampered bytes is not proof of publisher identity. Windows may therefore show
an unknown-publisher or reputation warning. Do not disable platform safeguards
or bypass such a warning for an artifact whose source you do not trust.

Official alpha downloads must publish the archive checksum on the same release
page and state that the build is unsigned. If signing is introduced, Windows
launchers will use Authenticode and both platform archives will receive a
detached signature tied to a documented, stable publisher identity. Until
then, no artifact or checksum may be described as cryptographically
authenticated.

Project authors exporting their own games remain responsible for notices and
licenses for project-local code, fonts, audio, images, and other assets they
add. Engine notices remain in every packaged game tree.
