#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-win64-lgpl-runtime.sh [options]

Options:
  --no-docker              Run the container build script directly.
  --image <name>           Docker image name. Default: octans-player-runtime-win64-lgpl:dev
  --output-root <path>     Output root. Default: ./dist
  --help                   Show this help.

Environment:
  OCTANS_RUNTIME_VERSION   Runtime version. Default: 0.0.0-local
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="octans-player-runtime-win64-lgpl:dev"
output_root="${repo_root}/dist"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-${repo_root}/.cache/sources}"
use_docker=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-docker)
            use_docker=0
            shift
            ;;
        --image)
            image_name="${2:?missing image name}"
            shift 2
            ;;
        --output-root)
            output_root="${2:?missing output root}"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mkdir -p "${output_root}" "${source_cache}"

if [[ "${use_docker}" -eq 0 ]]; then
    OCTANS_RUNTIME_OUTPUT="${output_root}" \
    OCTANS_RUNTIME_SOURCE_CACHE="${source_cache}" \
    OCTANS_RUNTIME_VERIFY_SCRIPT="${repo_root}/scripts/verify-runtime-artifact.sh" \
    "${repo_root}/scripts/container/build-win64-lgpl-runtime.sh"
    exit 0
fi

docker build \
    -f "${repo_root}/Dockerfile.win64-lgpl" \
    -t "${image_name}" \
    "${repo_root}"

build_status=0
docker run --rm \
    -e "OCTANS_RUNTIME_VERSION=${OCTANS_RUNTIME_VERSION:-0.0.0-local}" \
    -v "${output_root}:/dist" \
    -v "${source_cache}:/cache/sources" \
    "${image_name}" || build_status=$?

# Docker writes as root into host bind mounts; restore host ownership so CI can prune later.
restore_status=0
"${repo_root}/scripts/docker-restore-bind-mount-ownership.sh" \
    --image "${image_name}" \
    "${output_root}" \
    "${source_cache}" \
    || restore_status=$?
if [[ "${restore_status}" -ne 0 ]]; then
    echo "warning: failed to restore bind-mount ownership after docker build" >&2
fi
if [[ "${build_status}" -ne 0 ]]; then
    exit "${build_status}"
fi
exit "${restore_status}"
