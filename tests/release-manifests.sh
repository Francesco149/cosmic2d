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

"$repo/tools/stage-manifest.sh" "$repo" \
  "$repo/dist/manifests/editor.txt" "$stage/editor"
for name in selftest smoke igcanvas uigallery; do
  assert_absent "$stage/editor/projects/$name"
done
assert_present "$stage/editor/projects/picker/project.lua"
assert_present "$stage/editor/projects/demo/project.lua"
assert_present "$stage/editor/engine/cm/ed.lua"
assert_present "$stage/editor/projects/demo/main.lua"

"$repo/tools/stage-manifest.sh" "$repo" \
  "$repo/dist/manifests/play.txt" "$stage/play" demo
for name in selftest smoke igcanvas uigallery; do
  assert_absent "$stage/play/projects/$name"
done
assert_present "$stage/play/projects/picker/project.lua"
assert_present "$stage/play/projects/demo/project.lua"
assert_present "$stage/play/engine/cm/ed.lua"

"$repo/tools/stage-manifest.sh" "$repo" \
  "$repo/dist/manifests/dev.txt" "$stage/dev"
for name in selftest smoke igcanvas uigallery; do
  assert_present "$stage/dev/projects/$name/project.lua"
done
assert_present "$stage/dev/tests/release-manifests.sh"

echo "release manifests: PASS"
