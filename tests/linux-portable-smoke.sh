#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ! -f $1 || ! -f $2 ]]; then
  echo "usage: $0 cosmic2d-linux.tar.gz GAME-linux.tar.gz" >&2
  exit 2
fi

editor_archive=$(realpath "$1")
play_archive=$(realpath "$2")
case "$(basename "$editor_archive")" in
  cosmic2d-linux.tar.gz) ;;
  *) echo "expected the cosmic2d-linux.tar.gz editor archive" >&2; exit 2 ;;
esac
case "$(basename "$play_archive")" in
  *-linux.tar.gz)
    game=$(basename "$play_archive")
    game=${game%-linux.tar.gz}
    ;;
  *) echo "expected a *-linux.tar.gz play archive" >&2; exit 2 ;;
esac

for archive in "$editor_archive" "$play_archive"; do
  sidecar="$archive.sha256"
  [[ -f $sidecar ]] || { echo "missing archive checksum: $sidecar" >&2; exit 1; }
  (cd "$(dirname "$archive")" &&
    sha256sum --check --strict "$(basename "$sidecar")" >/dev/null)
done

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

# The two archives are the only release inputs. Debian supplies the supported
# glibc ABI and a software Vulkan driver; the engine must supply every other
# runtime library. Run as uid 65534 so chmod really proves the extracted trees
# are read-only (container root can bypass ordinary mode bits).
"$runtime" run --rm \
  --tmpfs /tmp:rw,nosuid,size=384m \
  -v "$editor_archive:/artifact/editor.tar.gz:ro" \
  -v "$play_archive:/artifact/play.tar.gz:ro" \
  -e "GAME=$game" \
  docker.io/library/debian:13-slim sh -euxc '
    apt-get update
    apt-get install -y --no-install-recommends mesa-vulkan-drivers util-linux

    extract_base="/tmp/extracted releases π"
    editor_parent="$extract_base/editor archive"
    play_parent="$extract_base/play archive"
    mkdir -p "$editor_parent" "$play_parent"
    tar xzf /artifact/editor.tar.gz -C "$editor_parent"
    tar xzf /artifact/play.tar.gz -C "$play_parent"

    one_root() {
      parent=$1
      count=$(find "$parent" -mindepth 1 -maxdepth 1 -type d | wc -l)
      test "$count" -eq 1
      find "$parent" -mindepth 1 -maxdepth 1 -type d -print -quit
    }
    editor_root=$(one_root "$editor_parent")
    play_root=$(one_root "$play_parent")

    test -x "$editor_root/cosmic2d-editor"
    test -x "$editor_root/demo"
    test -x "$editor_root/bin/cosmic"
    test -x "$play_root/$GAME"
    test -x "$play_root/bin/$GAME"
    test -x "$play_root/bin/cosmic2d-editor"
    test -s "$play_root/icon.png"
    grep -F "# cosmic demo" "$play_root/README.md"
    grep -F "Version " "$play_root/README.md"
    grep -F "0.1" "$play_root/README.md"
    grep -F "## Controls" "$play_root/README.md"
    grep -F "## Credits" "$play_root/README.md"
    grep -F "## Licenses" "$play_root/README.md"
    # The A6 bundled demo matrix ships complete in the editor archive.
    for name in demo cellar swarm; do
      test -f "$editor_root/projects/$name/README.md"
      test -s "$editor_root/projects/$name/icon.png"
      test -f "$editor_root/projects/$name/CONTROLS.md"
    done
    test -f "$editor_root/lib/libvulkan.so.1"
    test -f "$play_root/lib/libvulkan.so.1"

    for root in "$editor_root" "$play_root"; do
      (cd "$root" && sha256sum --check --strict SHA256SUMS >/dev/null)
    done
    for exe in "$editor_root/bin/cosmic" "$editor_root/cosmic2d-editor" \
               "$editor_root/demo" "$play_root/$GAME" \
               "$play_root/bin/$GAME" \
               "$play_root/bin/cosmic2d-editor"; do
      ! ldd "$exe" | grep -F /nix/store/
    done

    chown -R 0:0 "$editor_root" "$play_root"
    chmod -R a-w "$editor_root" "$play_root"
    if setpriv --reuid=65534 --regid=65534 --clear-groups \
         touch "$editor_root/write-probe" 2>/dev/null; then
      echo "unprivileged process could write the editor install" >&2
      exit 1
    fi
    if setpriv --reuid=65534 --regid=65534 --clear-groups \
         touch "$play_root/write-probe" 2>/dev/null; then
      echo "unprivileged process could write the play install" >&2
      exit 1
    fi

    user_root="/tmp/user state λ"
    home="$user_root/home"
    xdg="$user_root/xdg data"
    runtime="$user_root/runtime"
    outside="$user_root/unrelated cwd"
    mkdir -p "$home" "$xdg" "$runtime" "$outside"
    chmod 700 "$runtime"
    chown -R 65534:65534 "$user_root"

    run_release() {
      root=$1
      launcher=$2
      shift 2
      (cd "$outside" && setpriv --reuid=65534 --regid=65534 --clear-groups \
        env HOME="$home" XDG_DATA_HOME="$xdg" XDG_RUNTIME_DIR="$runtime" \
          SDL_VULKAN_LIBRARY="$root/lib/libvulkan.so.1" \
          SDL_VIDEODRIVER=offscreen \
          VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json \
          "$launcher" "$@")
    }

    # Capped boots prove every public entrance resolves from an unrelated cwd
    # without creating interactive diagnostic noise.
    run_release "$editor_root" "$editor_root/cosmic2d-editor" \
      --headless --frames 1
    run_release "$editor_root" "$editor_root/demo" --headless --frames 1
    run_release "$editor_root" "$editor_root/bin/cosmic" projects/cellar \
      --headless --frames 1
    run_release "$editor_root" "$editor_root/bin/cosmic" projects/swarm \
      --headless --frames 1
    run_release "$editor_root" "$editor_root/bin/cosmic" \
      --headless --frames 1
    run_release "$play_root" "$play_root/$GAME" --headless --frames 1
    run_release "$play_root" "$play_root/bin/$GAME" --headless --frames 1
    run_release "$play_root" "$play_root/bin/cosmic2d-editor" \
      --headless --frames 1
    test ! -e "$xdg/cosmic2d/engine/diagnostics"

    # Uncapped headless sessions still count as interactive. Quit through the
    # engine itself, then prove both archives logged under the external XDG
    # root rather than attempting to mutate their read-only project trees.
    run_release "$editor_root" "$editor_root/bin/cosmic" --headless \
      --eval "cm.main.request_quit()"
    run_release "$play_root" "$play_root/$GAME" --headless \
      --eval "cm.main.request_quit()"
    diag="$xdg/cosmic2d/engine/diagnostics"
    test -d "$diag"
    test "$(find "$diag" -maxdepth 1 -type f -name "process-*.log" | wc -l)" \
      -eq 2
    grep -F "booted projects/picker" "$diag"/process-*.log
    grep -F "booted projects/$GAME" "$diag"/process-*.log
    case "$diag" in
      "$editor_root"/*|"$play_root"/*)
        echo "diagnostics landed inside a release tree" >&2; exit 1;;
    esac

    for root in "$editor_root" "$play_root"; do
      (cd "$root" && sha256sum --check --strict SHA256SUMS >/dev/null)
    done
    echo "linux clean-machine matrix: PASS"
  '
