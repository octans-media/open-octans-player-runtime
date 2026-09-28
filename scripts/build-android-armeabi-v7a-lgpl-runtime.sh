#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-android-armeabi-v7a-lgpl-runtime.sh [options]

Options:
  --no-docker              Run the container build script directly.
  --toolchain-smoke        Validate only the armv7 NDK toolchain, Meson and CMake.
  --deps-only              Build armv7 shared dependencies only, then stop before FFmpeg.
  --ffmpeg-only            Build armv7 shared dependencies and FFmpeg, then stop before mpv.
  --image <name>           Docker image name. Default: octans-player-runtime-android-armeabi-v7a-lgpl:dev
  --output-root <path>     Output root. Default: ./dist
  --help                   Show this help.

Environment:
  OCTANS_RUNTIME_VERSION   Runtime version. Default: 0.0.0-local
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_name="octans-player-runtime-android-armeabi-v7a-lgpl:dev"
output_root="${repo_root}/dist"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-${repo_root}/.cache/sources}"
use_docker=1
toolchain_smoke=0
deps_only=0
ffmpeg_only=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-docker)
            use_docker=0
            shift
            ;;
        --toolchain-smoke)
            toolchain_smoke=1
            shift
            ;;
        --deps-only)
            deps_only=1
            shift
            ;;
        --ffmpeg-only)
            ffmpeg_only=1
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
    OCTANS_RUNTIME_VERIFY_SCRIPT="${repo_root}/scripts/verify-android-armeabi-v7a-runtime-artifact.sh" \
    OCTANS_RUNTIME_MANIFEST="${repo_root}/build-manifests/android-armeabi-v7a-lgpl-components.json" \
    OCTANS_RUNTIME_TOOLCHAIN_SMOKE="${toolchain_smoke}" \
    OCTANS_RUNTIME_DEPS_ONLY="${deps_only}" \
    OCTANS_RUNTIME_FFMPEG_ONLY="${ffmpeg_only}" \
    "${repo_root}/scripts/container/build-android-armeabi-v7a-lgpl-runtime.sh"
    exit 0
fi

docker_args=(
    --rm
    -e "OCTANS_RUNTIME_VERSION=${OCTANS_RUNTIME_VERSION:-0.0.0-local}"
    -e "OCTANS_RUNTIME_VERIFY_SCRIPT=/workspace/scripts/verify-android-armeabi-v7a-runtime-artifact.sh"
    -e "OCTANS_RUNTIME_TOOLCHAIN_SMOKE=${toolchain_smoke}"
    -e "OCTANS_RUNTIME_DEPS_ONLY=${deps_only}"
    -e "OCTANS_RUNTIME_FFMPEG_ONLY=${ffmpeg_only}"
    -v "${output_root}:/dist"
    -v "${source_cache}:/cache/sources"
)

host_ndk_home="${OCTANS_ANDROID_NDK_HOME:-${ANDROID_NDK_HOME:-}}"
if [[ -n "${host_ndk_home}" ]]; then
    if [[ ! -d "${host_ndk_home}" ]]; then
        echo "Configured Android NDK path does not exist: ${host_ndk_home}" >&2
        exit 1
    fi

    docker_args+=(
        -e "OCTANS_ANDROID_NDK_HOME=/opt/octans-android-ndk"
        -v "${host_ndk_home}:/opt/octans-android-ndk:ro"
    )
fi

docker build \
    -f "${repo_root}/Dockerfile.android-armeabi-v7a-lgpl" \
    -t "${image_name}" \
    "${repo_root}"

build_status=0
docker run "${docker_args[@]}" "${image_name}" || build_status=$?

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
