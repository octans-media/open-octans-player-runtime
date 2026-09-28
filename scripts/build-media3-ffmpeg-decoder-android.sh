#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-media3-ffmpeg-decoder-android.sh [options]

Options:
  --no-docker              Run the container build script directly.
  --image <name>           Docker image name. Default: octans-player-runtime-media3-ffmpeg-decoder-android:dev
  --output-root <path>     Output root. Default: ./dist
  --help                   Show this help.

Environment:
  OCTANS_RUNTIME_VERSION   Artifact version. Default: 0.0.0-local
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="octans-player-runtime-media3-ffmpeg-decoder-android:dev"
output_root="${repo_root}/dist"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-${repo_root}/.cache/sources}"
android_sdk_cache="${OCTANS_ANDROID_SDK_ROOT:-${repo_root}/.cache/android-sdk}"
gradle_cache="${GRADLE_USER_HOME:-${repo_root}/.cache/gradle}"
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

mkdir -p "${output_root}" "${source_cache}" "${android_sdk_cache}" "${gradle_cache}"

if [[ "${use_docker}" -eq 0 ]]; then
    OCTANS_RUNTIME_OUTPUT="${output_root}" \
    OCTANS_RUNTIME_SOURCE_CACHE="${source_cache}" \
    OCTANS_ANDROID_SDK_ROOT="${android_sdk_cache}" \
    GRADLE_USER_HOME="${gradle_cache}" \
    OCTANS_RUNTIME_VERIFY_SCRIPT="${repo_root}/scripts/verify-media3-ffmpeg-decoder-artifact.sh" \
    OCTANS_RUNTIME_MANIFEST="${repo_root}/build-manifests/media3-ffmpeg-decoder-android-components.json" \
    OCTANS_RUNTIME_OVERLAY_DIR="${repo_root}/scripts/overlays/media3-ffmpeg-decoder" \
    "${repo_root}/scripts/container/build-media3-ffmpeg-decoder-android.sh"
    exit 0
fi

docker build \
    -f "${repo_root}/Dockerfile.media3-ffmpeg-decoder-android" \
    -t "${image_name}" \
    "${repo_root}"

build_status=0
docker run \
    --rm \
    -e "OCTANS_RUNTIME_VERSION=${OCTANS_RUNTIME_VERSION:-0.0.0-local}" \
    -v "${output_root}:/dist" \
    -v "${source_cache}:/cache/sources" \
    -v "${android_sdk_cache}:/cache/android-sdk" \
    -v "${gradle_cache}:/cache/gradle" \
    "${image_name}" || build_status=$?

# Docker writes as root into host bind mounts; restore host ownership so CI can prune later.
restore_status=0
"${repo_root}/scripts/docker-restore-bind-mount-ownership.sh" \
    --image "${image_name}" \
    "${output_root}" \
    "${source_cache}" \
    "${android_sdk_cache}" \
    "${gradle_cache}" \
    || restore_status=$?
if [[ "${restore_status}" -ne 0 ]]; then
    echo "warning: failed to restore bind-mount ownership after docker build" >&2
fi
if [[ "${build_status}" -ne 0 ]]; then
    exit "${build_status}"
fi
exit "${restore_status}"
