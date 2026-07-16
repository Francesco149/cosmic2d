#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [WINDOWS_DEST]" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out_link=${COSMIC_WINDOWS_RESULT:-"$repo_root/result-windows-dev"}

# Flake source snapshots omit untracked files. Refuse a deceptively successful
# build rather than staging a Windows tree that is missing a newly added module.
mapfile -t untracked < <(git -C "$repo_root" ls-files --others --exclude-standard)
if (( ${#untracked[@]} > 0 )); then
  echo "untracked files are invisible to the Nix Windows build:" >&2
  printf '  %s\n' "${untracked[@]}" >&2
  echo "stage or ignore them before building" >&2
  exit 1
fi

echo "building cosmic-windows-dev..."
nix build "$repo_root#cosmic-windows-dev" --out-link "$out_link"

if [[ $# -eq 1 ]]; then
  exec "$repo_root/tools/stage-windows.sh" "$out_link" "$1"
fi
exec "$repo_root/tools/stage-windows.sh" "$out_link"
