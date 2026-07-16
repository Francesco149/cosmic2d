#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: release-integrity.sh tree ROOT {linux|linux-nix|windows}" >&2
  echo "       release-integrity.sh archive ARCHIVE" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
mode=$1

case "$mode" in
  tree)
    [[ $# -eq 3 ]] || usage
    root=${2%/}
    platform=$3
    [[ -d "$root" ]] || { echo "release tree does not exist: $root" >&2; exit 1; }

    case "$platform" in
      linux|linux-nix) runtime_licenses=linux-runtime ;;
      windows)         runtime_licenses=windows-runtime ;;
      *) usage ;;
    esac

    for required in LICENSE THIRD_PARTY_NOTICES.md LICENSES/README.md \
                    LICENSES/common/README.txt \
                    "LICENSES/$runtime_licenses/README.txt"; do
      if [[ ! -f "$root/$required" ]]; then
        echo "release tree lacks required legal metadata: $required" >&2
        exit 1
      fi
    done

    # A release is a real, inspectable folder on both supported platforms.
    # Refuse unchecked symlinks (and accidental Nix-store links) instead of
    # producing a manifest that silently omits them.
    link=$(find "$root" -type l -print -quit)
    if [[ -n "$link" ]]; then
      echo "release tree contains an unchecked symlink: $link" >&2
      exit 1
    fi

    inventory="$root/RUNTIME-LIBRARIES.txt"
    {
      printf 'cosmic2d carried runtime libraries\n'
      printf 'platform: %s\n\n' "$platform"
      case "$platform" in
        linux)
          printf 'These shared objects are carried in lib/:\n'
          find "$root/lib" -maxdepth 1 -type f -printf 'lib/%f\n' 2>/dev/null \
            | LC_ALL=C sort
          ;;
        linux-nix)
          printf '%s\n' \
            'This Nix-linked tree resolves shared libraries from its pinned Nix closure.' \
            'Use the cosmic-linux-portable artifact for a tree that carries lib/ itself.'
          ;;
        windows)
          printf 'These runtime DLL copies are carried in the tree:\n'
          (
            cd "$root"
            find . -type f -iname '*.dll' -printf '%P\n' | LC_ALL=C sort
          )
          ;;
      esac
      printf '\nThe matching pinned source notices are under LICENSES/%s/.\n' \
        "$runtime_licenses"
    } > "$inventory"

    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    (
      cd "$root"
      LC_ALL=C find . -type f ! -path ./SHA256SUMS -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum
    ) > "$tmp"
    [[ -s "$tmp" ]] || { echo "refusing an empty release checksum manifest" >&2; exit 1; }
    mv "$tmp" "$root/SHA256SUMS"
    trap - EXIT

    (cd "$root" && sha256sum --check --strict SHA256SUMS >/dev/null)
    ;;

  archive)
    [[ $# -eq 2 ]] || usage
    archive=$2
    [[ -f "$archive" && ! -L "$archive" ]] \
      || { echo "release archive does not exist or is a symlink: $archive" >&2; exit 1; }
    directory=$(cd "$(dirname "$archive")" && pwd)
    basename=$(basename "$archive")
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    (cd "$directory" && sha256sum "$basename") > "$tmp"
    mv "$tmp" "$archive.sha256"
    trap - EXIT
    (cd "$directory" && sha256sum --check --strict "$basename.sha256" >/dev/null)
    ;;

  *) usage ;;
esac
