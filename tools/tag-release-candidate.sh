#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: tools/tag-release-candidate.sh [--push] [REF]

Create the next annotated v<VERSION>-rc.N tag at REF (default: HEAD).
With --push, the commit must already be on origin/main; pushing the tag
triggers .github/workflows/release-candidate.yml.
EOF
  exit "${1:-2}"
}

push=false
case "${1:-}" in
  --push) push=true; shift ;;
  -h|--help) usage 0 ;;
esac
[[ $# -le 1 ]] || usage
ref=${1:-HEAD}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "refusing to tag a dirty worktree" >&2
  exit 1
}
commit=$(git rev-parse --verify "$ref^{commit}")
version=$(tr -d '\r\n' < VERSION)
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || {
  echo "VERSION cannot form a safe tag: $version" >&2
  exit 1
}

git fetch --tags origin
if $push; then
  git fetch origin main
  git merge-base --is-ancestor "$commit" refs/remotes/origin/main || {
    echo "$commit is not on origin/main; push main first" >&2
    exit 1
  }
fi

base="v${version}-rc"
next=1
while IFS= read -r existing; do
  number=${existing#"$base."}
  if [[ "$number" =~ ^[1-9][0-9]*$ ]] && (( number >= next )); then
    next=$((number + 1))
  fi
done < <(git tag --list "$base.*")
tag="$base.$next"

git tag -a "$tag" "$commit" \
  -m "cosmic2d $version release candidate $next"
echo "created $tag -> $commit"

if $push; then
  git push origin "refs/tags/$tag"
  echo "pushed $tag; the release-candidate workflow will build it"
else
  echo "local only; push it with: git push origin refs/tags/$tag"
fi
