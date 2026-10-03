#!/usr/bin/env bash
set -euo pipefail

runtime_root="${1:-}"

if [[ -z "${runtime_root}" ]]; then
    echo "Usage: scripts/verify-android-runtime-artifact.sh <runtime-root>" >&2
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

check_forbidden_text() {
    local name="$1"
    local path="$2"
    local forbidden=(
        "--enable-gpl"
        "--enable-nonfree"
        "--enable-libx264"
        "--enable-libx265"
        "--enable-libfdk-aac"
        "--enable-openssl"
        "libx264"
        "libx265"
        "libfdk_aac"
        "libdvdcss"
        "License:[[:space:]]*nonfree"
        "gpl[[:space:]]*=[[:space:]]*true"
        "-Dgpl[[:space:]]*=[[:space:]]*true"
        "enable-gpl"
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

check_required_text() {
    local name="$1"
    local path="$2"
    shift 2

    if [[ ! -f "${path}" ]]; then
        fail "${name}: missing ${path}"
        return
    fi

    local pattern
    for pattern in "$@"; do
        if grep -Eiq -- "${pattern}" "${path}"; then
            ok "${name}: required text found: ${pattern}"
        else
            fail "${name}: required text missing: ${pattern}"
        fi
    done
}

check_required_glob() {
    local name="$1"
    shift

    local pattern
    for pattern in "$@"; do
        shopt -s nullglob
        local matches=("${runtime_root}/jniLibs/arm64-v8a"/${pattern})
        shopt -u nullglob

        if [[ "${#matches[@]}" -gt 0 ]]; then
            ok "${name}: required shared object found: ${pattern}"
        else
            fail "${name}: required shared object missing: ${pattern}"
        fi
    done
}

is_android_system_so() {
    local so_name
    so_name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    case "${so_name}" in
        ld-android.so|libaaudio.so|libandroid.so|libc.so|libdl.so|libegl.so|libgcc.so|libglesv2.so|libjnigraphics.so|liblog.so|libm.so|libmediandk.so|libnativewindow.so|libopensles.so|libstdc++.so|libsync.so|libvulkan.so|libz.so)
            return 0
            ;;
    esac

    return 1
}

check_imported_sos_present() {
    local lib_dir="${runtime_root}/jniLibs/arm64-v8a"
    local readelf_bin=""

    if command -v llvm-readelf >/dev/null 2>&1; then
        readelf_bin="llvm-readelf"
    elif command -v readelf >/dev/null 2>&1; then
        readelf_bin="readelf"
    else
        fail "import gate: readelf not found"
        return
    fi

    shopt -s nullglob
    local so
    local imported
    local missing=()
    for so in "${lib_dir}"/lib*.so*; do
        while IFS= read -r imported; do
            [[ -z "${imported}" ]] && continue
            if is_android_system_so "${imported}"; then
                continue
            fi
            if [[ ! -f "${lib_dir}/${imported}" ]]; then
                missing+=("$(basename "${so}") -> ${imported}")
            fi
        done < <("${readelf_bin}" -d "${so}" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
    done
    shopt -u nullglob

    if [[ "${#missing[@]}" -gt 0 ]]; then
        fail "import gate: missing runtime shared object(s): ${missing[*]}"
    else
        ok "import gate: all non-system shared object imports are bundled"
    fi
}

check_forbidden_undefined_symbols() {
    local lib_dir="${runtime_root}/jniLibs/arm64-v8a"
    local readelf_bin=""

    if command -v llvm-readelf >/dev/null 2>&1; then
        readelf_bin="llvm-readelf"
    elif command -v readelf >/dev/null 2>&1; then
        readelf_bin="readelf"
    else
        fail "undefined symbol gate: readelf not found"
        return
    fi

    local forbidden_pattern='(__addtf3|__divtf3|__eqtf2|__multf3|__netf2|__subtf3|__emutls_get_address|__aarch64_ldadd8_(acq|acq_rel|rel|relax|sync))(@|$)'

    shopt -s nullglob
    local so
    local hits=()
    for so in "${lib_dir}"/lib*.so*; do
        while IFS= read -r hit; do
            [[ -z "${hit}" ]] && continue
            hits+=("$(basename "${so}") -> ${hit}")
        done < <("${readelf_bin}" -Ws "${so}" 2>/dev/null | awk '$7 == "UND" { print $8 }' | grep -E "${forbidden_pattern}" || true)
    done
    shopt -u nullglob

    if [[ "${#hits[@]}" -gt 0 ]]; then
        fail "undefined symbol gate: forbidden compiler runtime symbol(s): ${hits[*]}"
    else
        ok "undefined symbol gate: no unresolved compiler runtime builtins"
    fi
}

if [[ ! -d "${runtime_root}" ]]; then
    fail "runtime root does not exist: ${runtime_root}"
    exit 1
fi

manifest_path="${runtime_root}/runtime-manifest.json"
component_manifest_path="${runtime_root}/build/android-arm64-lgpl-components.json"

require_file "${manifest_path}"
require_file "${component_manifest_path}"
require_dir_with_content "${runtime_root}/jniLibs/arm64-v8a"
require_dir_with_content "${runtime_root}/assets/mpv"
require_dir_with_content "${runtime_root}/licenses"
require_dir_with_content "${runtime_root}/sources"
require_dir_with_content "${runtime_root}/build"

if [[ -f "${manifest_path}" ]]; then
    python3 - <<'PY' "${manifest_path}" || failures=$((failures + 1))
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

expected = {
    "runtimeId": "octans-player-runtime-lgpl-android-arm64",
    "target": "android-arm64",
    "abi": "arm64-v8a",
    "androidApi": 26,
    "licenseFlavor": "LGPL",
}

errors = []
for key, value in expected.items():
    if manifest.get(key) != value:
        errors.append(f"{key}: expected {value}, got {manifest.get(key)}")

if not manifest.get("version"):
    errors.append("version is required")

components = manifest.get("components") or []
if not components:
    errors.append("components must not be empty")

required_components = {
    "mpv",
    "ffmpeg",
    "libplacebo",
    "libass",
    "freetype2",
    "fribidi",
    "harfbuzz",
    "libpng",
    "zlib",
    "dav1d",
    "zimg",
    "lcms2",
    "mbedtls",
    "libxml2",
    "fontconfig",
    "libunibreak",
}
component_names = {str(component.get("name", "")) for component in components}
missing_components = sorted(required_components - component_names)
if missing_components:
    errors.append(f"required components missing: {', '.join(missing_components)}")

for component in components:
    for key in ("name", "version", "license", "sourceUrl", "purpose"):
        if not component.get(key):
            errors.append(f"component is missing {key}: {component}")

    source_hash = component.get("sourceHash") or {}
    if not any(source_hash.get(key) for key in ("sha256", "sha1", "md5", "commit")):
        errors.append(f"component is missing source hash: {component}")

    license_value = str(component.get("license", ""))
    if (
        license_value.startswith("GPL")
        or "AGPL" in license_value
        or "nonfree" in license_value.lower()
        or "proprietary" in license_value.lower()
    ):
        errors.append(f"forbidden component license: {component}")

profiles = manifest.get("androidProfiles") or {}
dv_profile = profiles.get("dolbyVisionP5ColorFix") or {}
dv_options = dv_profile.get("mpvOptions") or {}
if dv_options.get("vo") != "gpu-next" or dv_options.get("hwdec") != "no":
    errors.append("dolbyVisionP5ColorFix profile must document gpu-next + hwdec=no")

if errors:
    for error in errors:
        print(f"FAIL manifest: {error}", file=sys.stderr)
    sys.exit(1)

print("OK   runtime-manifest.json")
PY
fi

if [[ -f "${component_manifest_path}" ]]; then
    python3 -m json.tool "${component_manifest_path}" >/dev/null || fail "invalid android component manifest json"
fi

check_required_glob \
    "runtime shared object gate" \
    "libmpv.so" \
    "libavcodec*.so*" \
    "libavformat*.so*" \
    "libavutil*.so*" \
    "libswresample*.so*" \
    "libswscale*.so*" \
    "libass*.so*" \
    "libplacebo*.so*" \
    "libfreetype*.so*" \
    "libfribidi*.so*" \
    "libharfbuzz*.so*" \
    "libfontconfig*.so*" \
    "libxml2*.so*" \
    "libpng*.so*" \
    "libdav1d*.so*" \
    "libzimg*.so*" \
    "liblcms2*.so*" \
    "libmbedcrypto*.so*" \
    "libmbedtls*.so*" \
    "libmbedx509*.so*" \
    "libc++_shared.so"

ffmpeg_config="${runtime_root}/build/ffmpeg-configure.txt"
libplacebo_options="${runtime_root}/build/dependency-build-options/libplacebo.txt"
mpv_options="${runtime_root}/build/mpv-meson-options.txt"
cross_file="${runtime_root}/build/android-aarch64.ini"
sha256sums="${runtime_root}/build/sha256sums.txt"
sbom="${runtime_root}/build/sbom.spdx.json"

require_file "${ffmpeg_config}"
require_file "${libplacebo_options}"
require_file "${mpv_options}"
require_file "${cross_file}"
require_file "${sha256sums}"
require_file "${sbom}"
require_file "${runtime_root}/assets/mpv/mpv.conf"
require_file "${runtime_root}/assets/mpv/input.conf"
require_file "${runtime_root}/assets/mpv/fonts.conf"

check_forbidden_text "ffmpeg configure gate" "${ffmpeg_config}"
check_forbidden_text "libplacebo options gate" "${libplacebo_options}"
check_forbidden_text "mpv options gate" "${mpv_options}"
check_required_text \
    "ffmpeg configure gate" \
    "${ffmpeg_config}" \
    "--target-os=android" \
    "--arch=aarch64" \
    "--disable-gpl" \
    "--disable-nonfree" \
    "--enable-version3" \
    "--disable-openssl" \
    "--enable-shared" \
    "--disable-static" \
    "--enable-jni" \
    "--enable-mediacodec" \
    "--enable-mbedtls" \
    "--enable-libdav1d" \
    "--enable-libass" \
    "--enable-libfreetype" \
    "--enable-libfribidi" \
    "--enable-libharfbuzz" \
    "--enable-libzimg" \
    "--enable-lcms2" \
    "--enable-zlib"
check_required_text \
    "libplacebo options gate" \
    "${libplacebo_options}" \
    "-Dvulkan=enabled" \
    "-Dvk-proc-addr=enabled" \
    "-Dopengl=enabled" \
    "-Dgl-proc-addr=enabled" \
    "-Dshaderc=enabled" \
    "-Dglslang=disabled" \
    "-Dlcms=enabled" \
    "-Dlibdovi=disabled"
check_required_text \
    "mpv options gate" \
    "${mpv_options}" \
    "^[[:space:]]*gpl[[:space:]]+false" \
    "^[[:space:]]*libmpv[[:space:]]+true" \
    "^[[:space:]]*cplayer[[:space:]]+false" \
    "^[[:space:]]*android-media-ndk[[:space:]]+enabled" \
    "^[[:space:]]*egl-android[[:space:]]+enabled" \
    "^[[:space:]]*gl[[:space:]]+enabled" \
    "^[[:space:]]*vulkan[[:space:]]+enabled" \
    "^[[:space:]]*shaderc[[:space:]]+disabled" \
    "^[[:space:]]*spirv-cross[[:space:]]+disabled" \
    "^[[:space:]]*lcms2[[:space:]]+enabled" \
    "^[[:space:]]*zimg[[:space:]]+enabled" \
    "^[[:space:]]*lua[[:space:]]+disabled" \
    "^[[:space:]]*javascript[[:space:]]+disabled"

check_imported_sos_present
check_forbidden_undefined_symbols

if [[ -f "${sbom}" ]]; then
    python3 -m json.tool "${sbom}" >/dev/null || fail "invalid sbom json"
fi

if [[ -f "${sha256sums}" ]]; then
    (
        cd "${runtime_root}"
        sha256sum -c build/sha256sums.txt
    ) || failures=$((failures + 1))
fi

if [[ "${failures}" -gt 0 ]]; then
    echo "Android runtime artifact verification failed: ${failures} failure(s)" >&2
    exit 1
fi

echo "Android runtime artifact verification passed."
