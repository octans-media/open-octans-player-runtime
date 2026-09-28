#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:-}"

if [[ "${artifact_root}" == "--help" || "${artifact_root}" == "-h" ]]; then
    echo "Usage: scripts/verify-media3-libass-renderer-artifact.sh <artifact-root>"
    exit 0
fi

if [[ -z "${artifact_root}" ]]; then
    echo "Usage: scripts/verify-media3-libass-renderer-artifact.sh <artifact-root>" >&2
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

check_aar_entry() {
    local aar_path="$1"
    local entry="$2"
    if unzip -l "${aar_path}" | awk '{print $4}' | grep -Fxq "${entry}"; then
        ok "$(basename "${aar_path}") contains ${entry}"
    else
        fail "$(basename "${aar_path}") missing ${entry}"
    fi
}

check_aar_entry_absent() {
    local aar_path="$1"
    local pattern="$2"
    if unzip -l "${aar_path}" | awk '{print $4}' | grep -Eq "${pattern}"; then
        fail "$(basename "${aar_path}") contains forbidden entry matching ${pattern}"
    else
        ok "$(basename "${aar_path}") excludes ${pattern}"
    fi
}

check_aar_class() {
    local aar_path="$1"
    local class_entry="$2"
    local temp_dir
    temp_dir="$(mktemp -d)"
    unzip -q "${aar_path}" classes.jar -d "${temp_dir}"
    if jar tf "${temp_dir}/classes.jar" | grep -Fxq "${class_entry}"; then
        ok "$(basename "${aar_path}") classes.jar contains ${class_entry}"
    else
        fail "$(basename "${aar_path}") classes.jar missing ${class_entry}"
    fi
    rm -rf "${temp_dir}"
}

check_readelf_so() {
    local so_path="$1"
    local soname="$2"
    shift 2
    local required_needed=("$@")
    local output
    output="$(readelf -d "${so_path}")"

    if grep -Fq "Library soname: [${soname}]" <<<"${output}"; then
        ok "$(basename "${so_path}") SONAME ${soname}"
    else
        fail "$(basename "${so_path}") SONAME mismatch; expected ${soname}"
    fi

    local needed
    for needed in "${required_needed[@]}"; do
        if grep -Fq "Shared library: [${needed}]" <<<"${output}"; then
            ok "$(basename "${so_path}") NEEDED ${needed}"
        else
            fail "$(basename "${so_path}") missing NEEDED ${needed}"
        fi
    done

    local forbidden
    for forbidden in libass.so libasskt.so libc++_shared.so; do
        if grep -Fq "Shared library: [${forbidden}]" <<<"${output}"; then
            fail "$(basename "${so_path}") must not NEEDED ${forbidden}"
        else
            ok "$(basename "${so_path}") does not NEEDED ${forbidden}"
        fi
    done
}

check_native_libraries() {
    local temp_dir
    temp_dir="$(mktemp -d)"
    unzip -q "${ass_kt_aar_path}" -d "${temp_dir}"

    local abi
    for abi in arm64-v8a armeabi-v7a; do
        check_readelf_so \
            "${temp_dir}/jni/${abi}/liboctans_ass_renderer.so" \
            "liboctans_ass_renderer.so"
        check_readelf_so \
            "${temp_dir}/jni/${abi}/liboctans_ass_renderer_jni.so" \
            "liboctans_ass_renderer_jni.so" \
            "liboctans_ass_renderer.so"
    done

    rm -rf "${temp_dir}"
}

if [[ ! -d "${artifact_root}" ]]; then
    fail "artifact root does not exist: ${artifact_root}"
    exit 1
fi

require_command jar
require_command javap
require_command jq
require_command readelf
require_command sha256sum
require_command unzip

manifest_path="${artifact_root}/runtime-manifest.json"
ass_kt_aar_path="${artifact_root}/aar/lib_ass_kt-release.aar"
ass_media_aar_path="${artifact_root}/aar/lib_ass_media-release.aar"

require_file "${manifest_path}"
require_file "${ass_kt_aar_path}"
require_file "${ass_media_aar_path}"
require_file "${artifact_root}/build/android-media3-libass-renderer-manifest.json"
require_file "${artifact_root}/build/lib_ass_kt-aar-contents.txt"
require_file "${artifact_root}/build/lib_ass_media-aar-contents.txt"
require_file "${artifact_root}/build/lib_ass_kt-classes.txt"
require_file "${artifact_root}/build/lib_ass_media-classes.txt"
require_file "${artifact_root}/build/native-inventory.txt"
require_file "${artifact_root}/build/javap-Ass.txt"
require_file "${artifact_root}/build/patches-applied.txt"
require_file "${artifact_root}/build/upstream-submodules.txt"
require_file "${artifact_root}/build/autoreconf.log"
require_file "${artifact_root}/build/sha256sums.txt"
require_file "${artifact_root}/build/sbom.spdx.json"
require_dir_with_content "${artifact_root}/licenses"
require_dir_with_content "${artifact_root}/sources"
require_dir_with_content "${artifact_root}/build/patches"

for patch_name in \
    0001-rename-native-libraries.patch \
    0002-limit-packaged-abis.patch \
    0003-remove-duplicate-cxx-runtime.patch \
    0004-record-octans-artifact-metadata.patch \
    0005-fix-android-cross-configure-env.patch \
    0006-configure-android-system-fontconfig.patch \
    0007-align-mkv-font-attachment-detection.patch; do
    require_file "${artifact_root}/build/patches/${patch_name}"
    if grep -Fxq "${patch_name}" "${artifact_root}/build/patches-applied.txt" 2>/dev/null; then
        ok "patch applied ${patch_name}"
    else
        fail "patch not listed in patches-applied.txt: ${patch_name}"
    fi
done

if [[ "${failures}" -eq 0 ]]; then
    check_manifest_field '.runtimeId' 'octans-player-runtime-lgpl-media3-libass-renderer-android'
    check_manifest_field '.artifactKind' 'media3-libass-renderer'
    check_manifest_field '.target' 'android-media3-libass-renderer'
    check_manifest_field '.licenseFlavor' 'LGPL'
    check_manifest_field '.libassAndroid.commit' '07b447fabceee6a0811e58652a468bb4b5429163'
    check_manifest_field '.libassAndroid.ownershipPolicy.rendererSharedLibrary' 'liboctans_ass_renderer.so'
    check_manifest_field '.libassAndroid.ownershipPolicy.jniSharedLibrary' 'liboctans_ass_renderer_jni.so'

    abis="$(jq -r '.abis | sort | join(",")' "${manifest_path}")"
    if [[ "${abis}" == "arm64-v8a,armeabi-v7a" ]]; then
        ok "manifest abis=${abis}"
    else
        fail "manifest abis mismatch: ${abis}"
    fi
fi

if [[ -f "${ass_kt_aar_path}" ]]; then
    check_aar_entry "${ass_kt_aar_path}" "jni/arm64-v8a/liboctans_ass_renderer.so"
    check_aar_entry "${ass_kt_aar_path}" "jni/arm64-v8a/liboctans_ass_renderer_jni.so"
    check_aar_entry "${ass_kt_aar_path}" "jni/armeabi-v7a/liboctans_ass_renderer.so"
    check_aar_entry "${ass_kt_aar_path}" "jni/armeabi-v7a/liboctans_ass_renderer_jni.so"
    check_aar_entry "${ass_kt_aar_path}" "classes.jar"
    check_aar_entry_absent "${ass_kt_aar_path}" '(^|/)libass\.so$'
    check_aar_entry_absent "${ass_kt_aar_path}" '(^|/)libasskt\.so$'
    check_aar_entry_absent "${ass_kt_aar_path}" '(^|/)libc\+\+_shared\.so$'
    check_aar_entry_absent "${ass_kt_aar_path}" '^jni/x86/'
    check_aar_entry_absent "${ass_kt_aar_path}" '^jni/x86_64/'
    check_aar_class "${ass_kt_aar_path}" "io/github/peerless2012/ass/Ass.class"
    check_aar_class "${ass_kt_aar_path}" "io/github/peerless2012/ass/AssRender.class"
    check_native_libraries
fi

if [[ -f "${ass_media_aar_path}" ]]; then
    check_aar_entry "${ass_media_aar_path}" "classes.jar"
    check_aar_entry_absent "${ass_media_aar_path}" '^jni/'
    check_aar_class "${ass_media_aar_path}" "io/github/peerless2012/ass/media/AssHandler.class"
    check_aar_class "${ass_media_aar_path}" "io/github/peerless2012/ass/media/extractor/AssMatroskaExtractor.class"
    check_aar_class "${ass_media_aar_path}" "io/github/peerless2012/ass/media/factory/AssRenderersFactory.class"
    check_aar_class "${ass_media_aar_path}" "io/github/peerless2012/ass/media/widget/AssSubtitleView.class"
fi

if grep -Fq "configureFonts(" "${artifact_root}/build/javap-Ass.txt" \
    && grep -Fq "nativeAssConfigureFonts(" "${artifact_root}/build/javap-Ass.txt" \
    && grep -Fq "nativeAssRenderInit(long, java.lang.String, java.lang.String, java.lang.String)" "${artifact_root}/build/javap-Ass.txt"; then
    ok "javap exposes configureFonts and native font hooks"
else
    fail "javap does not expose expected libass font hooks"
fi

for license_file in \
    "${artifact_root}/licenses/libass-android-LICENSE" \
    "${artifact_root}/licenses/libass-COPYING" \
    "${artifact_root}/licenses/expat-COPYING" \
    "${artifact_root}/licenses/fontconfig-COPYING" \
    "${artifact_root}/licenses/freetype-LICENSE.TXT" \
    "${artifact_root}/licenses/fribidi-COPYING" \
    "${artifact_root}/licenses/harfbuzz-COPYING" \
    "${artifact_root}/licenses/libunibreak-LICENCE"; do
    require_file "${license_file}"
done

if grep -Eq 'libass\.so|libasskt\.so|libc\+\+_shared\.so' "${artifact_root}/build/lib_ass_kt-aar-contents.txt"; then
    fail "lib_ass_kt AAR contents include forbidden native library name"
else
    ok "lib_ass_kt AAR contents exclude forbidden native library names"
fi

if grep -Eq 'Shared library: \[(libass\.so|libasskt\.so|libc\+\+_shared\.so)\]' "${artifact_root}/build/native-inventory.txt"; then
    fail "native inventory includes forbidden NEEDED library"
else
    ok "native inventory excludes forbidden NEEDED libraries"
fi

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
    echo "Media3 libass renderer artifact verification failed with ${failures} issue(s)." >&2
    exit 1
fi

echo "Media3 libass renderer artifact verification passed."
