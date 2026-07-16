#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! -f $1 || ! -f $2 ]]; then
  echo "usage: $0 cosmic2d-windows.zip GAME-windows.zip" >&2
  exit 2
fi
for command in powershell.exe wslpath; do
  command -v "$command" >/dev/null || {
    echo "need $command (run this wrapper from WSL on the native Windows host)" >&2
    exit 2
  }
done

editor=$(realpath "$1")
play=$(realpath "$2")
for archive in "$editor" "$play"; do
  [[ -f $archive.sha256 ]] || {
    echo "missing archive checksum: $archive.sha256" >&2
    exit 1
  }
done

win_temp=$(powershell.exe -NoProfile -NonInteractive -Command \
  '[IO.Path]::GetTempPath()' | tr -d '\r\n')
wsl_temp=$(wslpath -u "$win_temp")
stage="$wsl_temp/cosmic2d native smoke π $$"
mkdir -p "$stage"
trap 'chmod -R u+w "$stage" 2>/dev/null || true; rm -rf "$stage"' EXIT

cp "$editor" "$editor.sha256" "$play" "$play.sha256" \
  tests/windows-portable-smoke.ps1 "$stage/"
editor_stage="$stage/$(basename "$editor")"
play_stage="$stage/$(basename "$play")"

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$(wslpath -w "$stage/windows-portable-smoke.ps1")" \
  -EditorArchive "$(wslpath -w "$editor_stage")" \
  -PlayArchive "$(wslpath -w "$play_stage")"
