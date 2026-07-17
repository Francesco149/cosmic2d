#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'chmod -R u+w "$stage" 2>/dev/null || true; rm -rf "$stage"' EXIT

assert_present() {
  [[ -e "$1" ]] || { echo "missing release entry: $1" >&2; exit 1; }
}
assert_absent() {
  [[ ! -e "$1" ]] || { echo "internal entry leaked into release: $1" >&2; exit 1; }
}
assert_legal_skeleton() {
  assert_present "$1/LICENSE"
  assert_present "$1/LICENSES/README.md"
  assert_present "$1/THIRD_PARTY_NOTICES.md"
}

"$repo/tools/stage-manifest.sh" "$repo" \
  "$repo/dist/manifests/editor.txt" "$stage/editor"
for name in selftest smoke igcanvas uigallery padtest inputproof cellar; do
  assert_absent "$stage/editor/projects/$name"
done
assert_present "$stage/editor/projects/picker/project.lua"
assert_present "$stage/editor/projects/demo/project.lua"
assert_present "$stage/editor/engine/cm/ed.lua"
assert_present "$stage/editor/projects/demo/main.lua"
assert_present "$stage/editor/pal/res/cosmic2d.png"
assert_legal_skeleton "$stage/editor"

"$repo/tools/stage-manifest.sh" "$repo" \
  "$repo/dist/manifests/play.txt" "$stage/play" demo
for name in selftest smoke igcanvas uigallery padtest inputproof cellar; do
  assert_absent "$stage/play/projects/$name"
done
assert_present "$stage/play/projects/picker/project.lua"
assert_present "$stage/play/projects/demo/project.lua"
assert_present "$stage/play/engine/cm/ed.lua"
assert_present "$stage/play/pal/res/cosmic2d.png"
assert_absent "$stage/play/README.md"
assert_legal_skeleton "$stage/play"

# Player packaging replaces the absent engine README with project-owned
# metadata. The icon and every player-facing text/legal reference are required
# and project-relative before any archive is published.
lua "$repo/tools/player-bundle.lua" \
  "$stage/play/projects/demo" "$stage/play" demo linux
assert_present "$stage/play/README.md"
assert_present "$stage/play/PLAY.txt"
assert_present "$stage/play/icon.png"
cmp "$stage/play/icon.png" "$stage/play/projects/demo/icon.png"
for phrase in "# cosmic demo" 'Version `0.1`' "## Controls" \
              "flash-jump" "## Credits" "cosmic2d contributors" \
              "## Licenses" "projects/demo/LICENSE.md" \
              'Run `./demo`'; do
  grep -Fq "$phrase" "$stage/play/README.md" || {
    echo "player README lacks project metadata: $phrase" >&2; exit 1;
  }
done
if grep -Fq "## Make a game" "$stage/play/README.md"; then
  echo "play bundle retained the engine authoring README" >&2
  exit 1
fi

# Windows uses the same metadata and emits resources for its delegating root
# launcher. Pin the project strings and numeric version mapping before windres.
lua "$repo/tools/player-bundle.lua" \
  "$stage/play/projects/demo" "$stage/play" demo windows "$stage/player.rc"
for phrase in 'IDI_GAME ICON "game.ico"' 'FILEVERSION 0,1,0,0' \
              'VALUE "FileDescription", "cosmic demo\0"' \
              'VALUE "ProductVersion", "0.1\0"'; do
  grep -Fq "$phrase" "$stage/player.rc" || {
    echo "player RC lacks project metadata: $phrase" >&2; exit 1;
  }
done

# Fail closed on paths that escape the project and on missing player files.
bad="$stage/bad-player-project"
bad_out="$stage/bad-player-output"
mkdir -p "$bad" "$bad_out"
cp "$repo/projects/demo/icon.png" "$bad/icon.png"
printf '%s\n' \
  'return {' \
  '  name="bad", version="1", description="bad",' \
  '  icon="../icon.png", controls="CONTROLS.md", credits="CREDITS.md",' \
  '  licenses={"LICENSE.md"},' \
  '}' > "$bad/project.lua"
for file in CONTROLS.md CREDITS.md LICENSE.md; do
  printf 'fixture\n' > "$bad/$file"
done
if lua "$repo/tools/player-bundle.lua" "$bad" "$bad_out" bad linux \
     >/dev/null 2>&1; then
  echo "player metadata accepted a project-escaping icon" >&2
  exit 1
fi
sed -i 's|icon="../icon.png"|icon="icon.png"|; s|controls="CONTROLS.md"|controls="MISSING.md"|' \
  "$bad/project.lua"
if lua "$repo/tools/player-bundle.lua" "$bad" "$bad_out" bad linux \
     >/dev/null 2>&1; then
  echo "player metadata accepted a missing controls file" >&2
  exit 1
fi
sed -i 's|controls="MISSING.md"|controls="CONTROLS.md"|; s|icon="icon.png"|icon="CONTROLS.md"|' \
  "$bad/project.lua"
if lua "$repo/tools/player-bundle.lua" "$bad" "$bad_out" bad linux \
     >/dev/null 2>&1; then
  echo "player metadata accepted text as its icon" >&2
  exit 1
fi
sed -i 's|icon="CONTROLS.md"|icon="icon.png"|; s|controls="CONTROLS.md"|controls="icon.png"|' \
  "$bad/project.lua"
if lua "$repo/tools/player-bundle.lua" "$bad" "$bad_out" bad linux \
     >/dev/null 2>&1; then
  echo "player metadata accepted binary controls content" >&2
  exit 1
fi

"$repo/tools/stage-manifest.sh" "$repo" \
  "$repo/dist/manifests/dev.txt" "$stage/dev"
for name in selftest smoke igcanvas uigallery padtest inputproof cellar; do
  assert_present "$stage/dev/projects/$name/project.lua"
done
assert_present "$stage/dev/tests/release-manifests.sh"
assert_present "$stage/dev/tools/release-integrity.sh"
assert_present "$stage/dev/tools/player-bundle.lua"
assert_present "$stage/dev/tools/windows-player-launcher.c"
assert_present "$stage/dev/pal/res/cosmic2d.png"
assert_legal_skeleton "$stage/dev"

# The integrity helper runs after every package's final mutation. Exercise it
# with spaces and non-ASCII paths, prove the manifest detects tampering, and
# prove archive sidecars are relative to (and verify beside) their archive.
fixture="$stage/integrity tree π"
mkdir -p "$fixture/LICENSES/common" "$fixture/LICENSES/linux-runtime" \
         "$fixture/lib" "$fixture/projects/space name"
cp "$repo/LICENSE" "$fixture/LICENSE"
cp "$repo/LICENSES/README.md" "$fixture/LICENSES/README.md"
cp "$repo/THIRD_PARTY_NOTICES.md" "$fixture/THIRD_PARTY_NOTICES.md"
printf 'common notices\n' > "$fixture/LICENSES/common/README.txt"
printf 'runtime notices\n' > "$fixture/LICENSES/linux-runtime/README.txt"
printf 'runtime\n' > "$fixture/lib/libexample.so.1"
printf 'unicode and spaces\n' > "$fixture/projects/space name/π.txt"
printf 'nested manifests are ordinary project data\n' \
  > "$fixture/projects/space name/SHA256SUMS"

"$repo/tools/release-integrity.sh" tree "$fixture" linux
assert_present "$fixture/SHA256SUMS"
assert_present "$fixture/RUNTIME-LIBRARIES.txt"
(
  cd "$fixture"
  sha256sum --check --strict SHA256SUMS >/dev/null
  [[ $(<SHA256SUMS) != *"  ./SHA256SUMS"* ]]
  [[ $(<SHA256SUMS) == *"  ./projects/space name/SHA256SUMS"* ]]
  [[ $(<RUNTIME-LIBRARIES.txt) == *"lib/libexample.so.1"* ]]
)

printf 'tampered\n' >> "$fixture/projects/space name/π.txt"
if (cd "$fixture" && sha256sum --check --strict SHA256SUMS >/dev/null 2>&1); then
  echo "release checksum failed to detect tampering" >&2
  exit 1
fi
printf 'unicode and spaces\n' > "$fixture/projects/space name/π.txt"

ln -s LICENSE "$fixture/unchecked-link"
if "$repo/tools/release-integrity.sh" tree "$fixture" linux >/dev/null 2>&1; then
  echo "release integrity accepted an unchecked symlink" >&2
  exit 1
fi
rm "$fixture/unchecked-link"

archive="$stage/demo release.tar.gz"
printf 'archive bytes\n' > "$archive"
"$repo/tools/release-integrity.sh" archive "$archive"
assert_present "$archive.sha256"
(cd "$stage" && sha256sum --check --strict "$(basename "$archive").sha256" >/dev/null)

echo "release manifests: PASS"
