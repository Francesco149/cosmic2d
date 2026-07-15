#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f $1 ]]; then
  echo "usage: $0 GAME-linux.tar.gz" >&2
  exit 2
fi

archive=$(realpath "$1")
case "$(basename "$archive")" in
  *-linux.tar.gz) game=${archive##*/}; game=${game%-linux.tar.gz} ;;
  *) echo "expected a *-linux.tar.gz archive" >&2; exit 2 ;;
esac

runtime=${CONTAINER_RUNTIME:-}
if [[ -z $runtime ]]; then
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null; then runtime=$candidate; break; fi
  done
fi
if [[ -z $runtime ]]; then
  echo "need podman or docker (or set CONTAINER_RUNTIME)" >&2
  exit 2
fi

# The archive is the only host input. Debian supplies the supported glibc ABI
# and a software Vulkan driver; the engine must supply all other libraries.
"$runtime" run --rm \
  --tmpfs /tmp:rw,nosuid,size=128m \
  -v "$archive:/artifact/game.tar.gz:ro" \
  docker.io/library/debian:13-slim sh -euxc '
    apt-get update
    apt-get install -y --no-install-recommends mesa-vulkan-drivers xvfb xauth
    mkdir /tmp/game
    tar xzf /artifact/game.tar.gz -C /tmp/game
    root=$(find /tmp/game -mindepth 1 -maxdepth 1 -type d -print -quit)
    test -n "$root"
    ! ldd "$root/bin/'"$game"'" | grep -F "/nix/store/"
    chmod -R a-w "$root"
    mkdir /tmp/home /tmp/runtime
    HOME=/tmp/home XDG_RUNTIME_DIR=/tmp/runtime \
      SDL_VULKAN_LIBRARY="$root/lib/libvulkan.so.1" \
      SDL_VIDEODRIVER=offscreen \
      VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json \
      xvfb-run -a "$root/bin/'"$game"'" --headless --frames 1
  '
