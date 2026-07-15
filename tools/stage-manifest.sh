#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: stage-manifest SOURCE MANIFEST DEST [PROJECT]" >&2
  exit 2
fi

source_root=$1
manifest=$2
dest=$3
project=${4:-}

mkdir -p "$dest"
while IFS= read -r entry || [[ -n "$entry" ]]; do
  [[ -z "$entry" || "$entry" == \#* ]] && continue
  if [[ "$entry" == *'@PROJECT@'* ]]; then
    if [[ -z "$project" || "$project" == */* || "$project" == .* ]]; then
      echo "play manifest needs a safe project name" >&2
      exit 2
    fi
    entry=${entry//@PROJECT@/$project}
  fi
  if [[ ! -e "$source_root/$entry" ]]; then
    echo "manifest entry does not exist: $entry" >&2
    exit 1
  fi
  mkdir -p "$dest/$(dirname "$entry")"
  cp -r "$source_root/$entry" "$dest/$entry"
done < "$manifest"
