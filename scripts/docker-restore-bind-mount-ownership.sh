#!/usr/bin/env bash
# Restore host ownership of Docker bind mounts after a root container writes into them.
#
# Docker builds run as root by default. Files created under host bind mounts become
# root-owned, so the runner user cannot later prune CI cache directories.
# This helper reassigns ownership to the mount root's existing host owner (the
# directory itself was created by the host user and keeps that ownership).
#
# Usage:
#   scripts/docker-restore-bind-mount-ownership.sh [--image IMAGE] PATH [PATH...]
set -euo pipefail

image_name=""
paths=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            image_name="${2:?missing image name}"
            shift 2
            ;;
        --help|-h)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        --)
            shift
            paths+=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *)
            paths+=("$1")
            shift
            ;;
    esac
done

if [[ ${#paths[@]} -eq 0 ]]; then
    echo "Usage: $0 [--image IMAGE] PATH [PATH...]" >&2
    exit 2
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required to restore bind-mount ownership" >&2
    exit 1
fi

mount_args=()
idx=0
for host_path in "${paths[@]}"; do
    if [[ ! -e "${host_path}" ]]; then
        continue
    fi

    # Resolve to absolute path so docker bind mounts are unambiguous.
    abs_path="$(cd "$(dirname "${host_path}")" && pwd)/$(basename "${host_path}")"
    mount_args+=(-v "${abs_path}:/fix-mounts/m${idx}")
    idx=$((idx + 1))
done

if [[ ${#mount_args[@]} -eq 0 ]]; then
    exit 0
fi

restore_image="${image_name}"
if [[ -n "${restore_image}" ]] && ! docker image inspect "${restore_image}" >/dev/null 2>&1; then
    restore_image=""
fi
if [[ -z "${restore_image}" ]]; then
    restore_image="ubuntu:26.04"
fi

docker run --rm --user 0:0 \
    "${mount_args[@]}" \
    --entrypoint bash \
    "${restore_image}" \
    -c '
        set -euo pipefail
        shopt -s nullglob
        for mount_dir in /fix-mounts/m*; do
            [[ -e "${mount_dir}" ]] || continue
            owner="$(stat -c "%u:%g" "${mount_dir}")"
            chown -R "${owner}" "${mount_dir}"
        done
    '
