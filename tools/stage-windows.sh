#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 WINDOWS_BUILD [WINDOWS_DEST]" >&2
  echo "WINDOWS_DEST may be a C:\\ path or its /mnt/c equivalent." >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 2
fi

for command in powershell.exe wslpath realpath; do
  command -v "$command" >/dev/null || {
    echo "need $command (run this helper from WSL on the Windows host)" >&2
    exit 2
  }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_root=$(realpath -- "$1")
if [[ ! -f "$source_root/cosmic2d-editor.exe" ||
      ! -f "$source_root/engine/boot.lua" ]]; then
  echo "not a staged cosmic2d Windows development tree: $source_root" >&2
  exit 1
fi

dest_spec=${2:-${COSMIC_WINDOWS_STAGE:-}}
if [[ -z "$dest_spec" ]]; then
  windows_profile=$(powershell.exe -NoProfile -NonInteractive -Command \
    '$env:USERPROFILE' | tr -d '\r\n')
  if [[ -z "$windows_profile" ]]; then
    echo "could not resolve the Windows user profile" >&2
    exit 1
  fi
  dest_spec="$windows_profile\\cosmic2d-win"
fi

if [[ "$dest_spec" =~ ^[[:alpha:]]:[\\/] ]]; then
  dest_root=$(wslpath -u -- "$dest_spec")
else
  dest_root=$(realpath -m -- "$dest_spec")
fi
dest_windows=$(wslpath -w -- "$dest_root")
if [[ ! "$dest_windows" =~ ^[[:alpha:]]:\\ ]]; then
  echo "Windows stage must live on a mounted Windows drive: $dest_root" >&2
  exit 1
fi
if [[ "$dest_root" == "$source_root" || "$dest_root" == / ||
      "$dest_root" == /mnt/[^/] ]]; then
  echo "refusing unsafe Windows stage destination: $dest_root" >&2
  exit 1
fi
if [[ -e "$dest_root" && ! -d "$dest_root" ]]; then
  echo "Windows stage destination is not a directory: $dest_root" >&2
  exit 1
fi
if [[ -d "$dest_root" && -n "$(find "$dest_root" -mindepth 1 -maxdepth 1 -print -quit)" &&
      ! -f "$dest_root/.cosmic2d-dev-stage" &&
      ( ! -f "$dest_root/cosmic2d-editor.exe" ||
        ! -f "$dest_root/engine/boot.lua" ) ]]; then
  echo "refusing to replace an unrecognized non-empty directory: $dest_root" >&2
  exit 1
fi

parent=$(dirname -- "$dest_root")
base=$(basename -- "$dest_root")
mkdir -p -- "$parent"
next=$(mktemp -d -p "$parent" ".${base}.next.XXXXXXXX")
old="$next.old"
shortcut_helper=$(mktemp -p "$parent" ".cosmic2d-shortcut.XXXXXXXX.ps1")

cleanup() {
  rm -rf -- "$next" 2>/dev/null || true
  rm -f -- "$shortcut_helper" 2>/dev/null || true
}
trap cleanup EXIT

cp -rL --no-preserve=ownership -- "$source_root"/. "$next"/
chmod -R u+w -- "$next"

preserved=0
preserve_file() {
  local path=$1 rel
  [[ -f "$path" ]] || return
  rel=${path#"$dest_root"/}
  mkdir -p -- "$next/$(dirname -- "$rel")"
  cp -p -- "$path" "$next/$rel"
  preserved=$((preserved + 1))
}

preserve_editor_state() {
  local path=$1 rel entry copied=0
  [[ -d "$path" ]] || return
  rel=${path#"$dest_root"/}
  rm -rf -- "$next/$rel"
  mkdir -p -- "$next/$rel"
  # Session files and journals may contain the only copy of unsaved work.
  # Rewind history is explicitly derived cache and can approach gigabytes, so
  # let the freshly staged editor rebuild it instead of copying it every time.
  while IFS= read -r -d '' entry; do
    cp -a -- "$entry" "$next/$rel/"
    copied=1
  done < <(find "$path" -mindepth 1 -maxdepth 1 ! -name history -print0)
  if (( copied )); then
    preserved=$((preserved + 1))
  else
    rmdir -- "$next/$rel"
  fi
}

if [[ -d "$dest_root" ]]; then
  preserve_file "$dest_root/.recent.dat"
  # USER PROJECTS live beside the shipped demos in projects/: any project
  # directory the fresh stage does not ship is the human's own work and
  # must survive a restage WHOLESALE — the .ed-only preservation silently
  # dropped two native projects' payload files (D139 addendum 3; the
  # journals allowed a full recovery, but only because nothing had been
  # closed unsaved). `.ed` is skipped here so the editor-state pass below
  # applies its usual rules (sessions + journals kept, derived history
  # rebuilt).
  if [[ -d "$dest_root/projects" ]]; then
    for proj in "$dest_root/projects"/*/; do
      [[ -d "$proj" ]] || continue
      pname=$(basename -- "$proj")
      if [[ ! -e "$next/projects/$pname" ]]; then
        mkdir -p -- "$next/projects/$pname"
        while IFS= read -r -d '' entry; do
          cp -a -- "$entry" "$next/projects/$pname/"
        done < <(find "$proj" -mindepth 1 -maxdepth 1 ! -name .ed -print0)
        preserved=$((preserved + 1))
      fi
    done
  fi
  while IFS= read -r -d '' state; do preserve_editor_state "$state"; done \
    < <(find "$dest_root" -type d -name .ed -prune -print0)
  if [[ -d "$dest_root/projects" ]]; then
    while IFS= read -r -d '' state; do preserve_file "$state"; done \
      < <(find "$dest_root/projects" -type f \
        \( -name video.dat -o -name knobs.dat -o -name map.dat \) -print0)
  fi
fi

{
  echo "cosmic2d Windows development stage"
  echo "managed by tools/stage-windows.sh"
} > "$next/.cosmic2d-dev-stage"

had_old=false
if [[ -d "$dest_root" ]]; then
  if ! mv -- "$dest_root" "$old"; then
    echo "could not replace $dest_windows; close any running staged editor and retry" >&2
    exit 1
  fi
  had_old=true
fi
if ! mv -- "$next" "$dest_root"; then
  if $had_old; then mv -- "$old" "$dest_root" || true; fi
  echo "could not publish the completed Windows stage: $dest_windows" >&2
  exit 1
fi
if $had_old && ! rm -rf -- "$old"; then
  echo "warning: could not remove previous stage: $(wslpath -w -- "$old")" >&2
fi

# Run the helper from NTFS rather than a WSL UNC path; Windows PowerShell 5.1
# applies fewer location/security quirks to a local-drive script.
cp -- "$repo_root/tools/install-windows-shortcut.ps1" "$shortcut_helper"
shortcut=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$(wslpath -w -- "$shortcut_helper")" \
  -StageRoot "$dest_windows" | tr -d '\r')
rm -f -- "$shortcut_helper"

echo "windows development build staged -> $dest_windows"
echo "preserved Windows-side state entries -> $preserved"
echo "Start Menu shortcut -> $shortcut"
