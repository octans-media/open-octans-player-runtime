#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:-}"

if [[ "${artifact_root}" == "--help" || "${artifact_root}" == "-h" ]]; then
    echo "Usage: scripts/verify-media3-ffmpeg-decoder-artifact.sh <artifact-root>"
    exit 0
fi

if [[ -z "${artifact_root}" ]]; then
    echo "Usage: scripts/verify-media3-ffmpeg-decoder-artifact.sh <artifact-root>" >&2
    exit 2
fi

failures=0

fail() {
    echo "FAIL $*" >&2
    failures=$((failures + 1))
}

ok() {
    echo "OK   $*"
}

require_command() {
    local name="$1"
    if ! command -v "${name}" >/dev/null 2>&1; then
        fail "required command not found: ${name}"
    fi
}

require_file() {
    local path="$1"
    if [[ -f "${path}" ]]; then
        ok "${path}"
    else
        fail "missing file: ${path}"
    fi
}

require_dir_with_content() {
    local path="$1"
    if [[ ! -d "${path}" ]]; then
        fail "missing directory: ${path}"
        return
    fi

    if find "${path}" -type f | head -n 1 | grep -q .; then
        ok "${path}"
    else
        fail "empty directory: ${path}"
    fi
}

check_manifest_field() {
    local name="$1"
    local expected="$2"
    local actual
    actual="$(jq -r "${name} // empty" "${manifest_path}")"
    if [[ "${actual}" == "${expected}" ]]; then
        ok "manifest ${name}=${expected}"
    else
        fail "manifest ${name}: expected ${expected}, got ${actual:-<empty>}"
    fi
}

check_no_forbidden_text() {
    local name="$1"
    local path="$2"
    local forbidden=(
        "--enable-gpl"
        "--enable-nonfree"
        "--enable-libx264"
        "--enable-libx265"
        "--enable-libfdk-aac"
        "License:[[:space:]]*nonfree"
        "enabledGpl[[:space:]]*:[[:space:]]*true"
        "enabledNonfree[[:space:]]*:[[:space:]]*true"
    )

    if [[ ! -f "${path}" ]]; then
        fail "${name}: missing ${path}"
        return
    fi

    local hits=()
    local pattern
    for pattern in "${forbidden[@]}"; do
        if grep -Eiq -- "${pattern}" "${path}"; then
            hits+=("${pattern}")
        fi
    done

    if [[ "${#hits[@]}" -gt 0 ]]; then
        fail "${name}: forbidden text found: ${hits[*]}"
    else
        ok "${name}: no forbidden text"
    fi
}

check_aar_entry() {
    local entry="$1"
    if unzip -l "${aar_path}" | awk '{print $4}' | grep -Fxq "${entry}"; then
        ok "AAR contains ${entry}"
    else
        fail "AAR missing ${entry}"
    fi
}

check_aar_class() {
    local class_entry="$1"
    local temp_dir
    temp_dir="$(mktemp -d)"
    unzip -q "${aar_path}" classes.jar -d "${temp_dir}"
    if jar tf "${temp_dir}/classes.jar" | grep -Fxq "${class_entry}"; then
        ok "classes.jar contains ${class_entry}"
    else
        fail "classes.jar missing ${class_entry}"
    fi
    rm -rf "${temp_dir}"
}

check_aar_class_absent() {
    local class_entry="$1"
    local temp_dir
    temp_dir="$(mktemp -d)"
    unzip -q "${aar_path}" classes.jar -d "${temp_dir}"
    if jar tf "${temp_dir}/classes.jar" | grep -Fxq "${class_entry}"; then
        fail "classes.jar must not contain ${class_entry}"
    else
        ok "classes.jar excludes ${class_entry}"
    fi
    rm -rf "${temp_dir}"
}

if [[ ! -d "${artifact_root}" ]]; then
    fail "artifact root does not exist: ${artifact_root}"
    exit 1
fi

require_command jq
require_command jar
require_command sha256sum
require_command unzip

manifest_path="${artifact_root}/runtime-manifest.json"
aar_path="${artifact_root}/aar/media3-decoder-ffmpeg-release.aar"

require_file "${manifest_path}"
require_file "${aar_path}"
require_file "${artifact_root}/build/android-media3-ffmpeg-decoder-manifest.json"
require_file "${artifact_root}/build/ffmpeg-configure-arm64-v8a.txt"
require_file "${artifact_root}/build/ffmpeg-configure-armeabi-v7a.txt"
require_file "${artifact_root}/build/enabled-decoders.txt"
require_file "${artifact_root}/build/enabled-filters.txt"
require_file "${artifact_root}/build/graph-smoke-summary.txt"
require_file "${artifact_root}/build/graph-smoke-dynaudnorm-low-window-5point1-astats.txt"
require_file "${artifact_root}/build/graph-smoke-dynaudnorm-low-window-7point1-astats.txt"
require_file "${artifact_root}/build/aar-contents.txt"
require_file "${artifact_root}/build/sha256sums.txt"
require_file "${artifact_root}/build/sbom.spdx.json"
require_dir_with_content "${artifact_root}/licenses"
require_dir_with_content "${artifact_root}/sources"

if [[ "${failures}" -eq 0 ]]; then
    check_manifest_field '.runtimeId' 'octans-player-runtime-lgpl-media3-ffmpeg-decoder-android'
    check_manifest_field '.artifactKind' 'media3-ffmpeg-decoder'
    check_manifest_field '.target' 'android-media3-ffmpeg-decoder'
    check_manifest_field '.licenseFlavor' 'LGPL'

    abis="$(jq -r '.abis | sort | join(",")' "${manifest_path}")"
    if [[ "${abis}" == "arm64-v8a,armeabi-v7a" ]]; then
        ok "manifest abis=${abis}"
    else
        fail "manifest abis mismatch: ${abis}"
    fi

    enabled_gpl="$(jq -r '.ffmpeg.configurePolicy.enabledGpl' "${manifest_path}")"
    enabled_nonfree="$(jq -r '.ffmpeg.configurePolicy.enabledNonfree' "${manifest_path}")"
    if [[ "${enabled_gpl}" == "false" && "${enabled_nonfree}" == "false" ]]; then
        ok "manifest FFmpeg GPL/nonfree disabled"
    else
        fail "manifest FFmpeg GPL/nonfree policy invalid: enabledGpl=${enabled_gpl}, enabledNonfree=${enabled_nonfree}"
    fi
fi

expected_decoders=$'aac\nac3\neac3\ndca\ntruehd\nflac\nopus\nvorbis\nmp3'
actual_decoders="$(cat "${artifact_root}/build/enabled-decoders.txt" 2>/dev/null || true)"
if [[ "${actual_decoders}" == "${expected_decoders}" ]]; then
    ok "enabled decoder list matches"
else
    fail "enabled decoder list mismatch"
fi

expected_filters=$'abuffer\nabuffersink\naformat\npan\ndynaudnorm\naresample'
actual_filters="$(cat "${artifact_root}/build/enabled-filters.txt" 2>/dev/null || true)"
if [[ "${actual_filters}" == "${expected_filters}" ]]; then
    ok "enabled filter list matches"
else
    fail "enabled filter list mismatch"
fi

manifest_filters="$(jq -r '.ffmpeg.enabledFilters // [] | .[]' "${manifest_path}" 2>/dev/null || true)"
if [[ "${manifest_filters}" == "${expected_filters}" ]]; then
    ok "manifest enabled filter list matches"
else
    fail "manifest enabled filter list mismatch"
fi

for configure_file in \
    "${artifact_root}/build/ffmpeg-configure-arm64-v8a.txt" \
    "${artifact_root}/build/ffmpeg-configure-armeabi-v7a.txt"; do
    configure_filters="$({ grep -Eo -- '--enable-filter=[^[:space:]]+' "${configure_file}" || true; } \
        | sed 's/^--enable-filter=//' \
        | sort -u \
        | sed '/^$/d')"
    expected_sorted_filters="$(printf '%s\n' aformat pan dynaudnorm aresample | sort -u)"
    if [[ "${configure_filters}" == "${expected_sorted_filters}" ]]; then
        ok "$(basename "${configure_file}") filter flags match whitelist"
    else
        fail "$(basename "${configure_file}") filter flags mismatch: ${configure_filters}"
    fi
done

check_no_forbidden_text "arm64 FFmpeg configure" "${artifact_root}/build/ffmpeg-configure-arm64-v8a.txt"
check_no_forbidden_text "armeabi-v7a FFmpeg configure" "${artifact_root}/build/ffmpeg-configure-armeabi-v7a.txt"
check_no_forbidden_text "runtime manifest" "${manifest_path}"

if grep -Fq "result=passed" "${artifact_root}/build/graph-smoke-summary.txt" \
    && grep -Fq "synthetic_5point1_output=stereo/48000/f32le" "${artifact_root}/build/graph-smoke-summary.txt" \
    && grep -Fq "synthetic_7point1_output=stereo/48000/f32le" "${artifact_root}/build/graph-smoke-summary.txt"; then
    ok "graph smoke summary passed"
else
    fail "graph smoke summary missing expected stereo/48000 evidence"
fi

profile="dynaudnorm-low-window"
if grep -Fq "profile=${profile}" "${artifact_root}/build/graph-smoke-summary.txt" \
    && grep -Fq "profile_${profile}_result=passed" "${artifact_root}/build/graph-smoke-summary.txt"; then
    ok "graph smoke ${profile} summary passed"
else
    fail "graph smoke ${profile} summary missing"
fi
for astats_file in \
    "${artifact_root}/build/graph-smoke-${profile}-5point1-astats.txt" \
    "${artifact_root}/build/graph-smoke-${profile}-7point1-astats.txt"; do
    if awk '/RMS level dB:/ && $NF != "-inf" { count++ } END { exit(count >= 2 ? 0 : 1) }' "${astats_file}"; then
        ok "$(basename "${astats_file}") has non-zero stereo energy"
    else
        fail "$(basename "${astats_file}") missing non-zero stereo energy"
    fi
done

if [[ -f "${aar_path}" ]]; then
    check_aar_entry "jni/arm64-v8a/libffmpegJNI.so"
    check_aar_entry "jni/armeabi-v7a/libffmpegJNI.so"
    check_aar_entry "classes.jar"
    check_aar_class "androidx/media3/decoder/ffmpeg/FfmpegLibrary.class"
    check_aar_class "androidx/media3/decoder/ffmpeg/FfmpegAudioRenderer.class"
    check_aar_class "androidx/media3/decoder/ffmpeg/FfmpegAudioDecoder.class"
    check_aar_class "androidx/media3/decoder/ffmpeg/FfmpegAudioProcessingOptions.class"
    check_aar_class_absent "androidx/media3/decoder/ffmpeg/ExperimentalFfmpegVideoRenderer.class"
fi

for license_file in \
    "${artifact_root}/licenses/media3-LICENSE" \
    "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv2.1" \
    "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv3" \
    "${artifact_root}/licenses/ffmpeg-LICENSE.md"; do
    require_file "${license_file}"
done

if find "${artifact_root}" \( -name '*.a' -o -path '*/.cxx/*' -o -path '*/android-libs/*' -o -path '*/.git/*' -o -path '*/build/intermediates/*' \) -print | grep -q .; then
    fail "artifact contains forbidden build intermediates"
else
    ok "artifact contains no forbidden build intermediates"
fi

if [[ -f "${artifact_root}/build/sha256sums.txt" ]]; then
    (
        cd "${artifact_root}"
        sha256sum -c build/sha256sums.txt >/dev/null
    ) && ok "sha256sums.txt verified" || fail "sha256sums.txt verification failed"
fi

if [[ "${failures}" -gt 0 ]]; then
    echo "Media3 FFmpeg decoder artifact verification failed with ${failures} issue(s)." >&2
    exit 1
fi

echo "Media3 FFmpeg decoder artifact verification passed."
