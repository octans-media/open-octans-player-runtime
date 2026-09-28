#!/usr/bin/env bash
set -euo pipefail

runtime_root="${1:-}"

if [[ -z "${runtime_root}" ]]; then
    echo "Usage: scripts/verify-runtime-artifact.sh <runtime-root>" >&2
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
        local matches=("${runtime_root}/bin"/${pattern})
        shopt -u nullglob

        if [[ "${#matches[@]}" -gt 0 ]]; then
            ok "${name}: required DLL found: ${pattern}"
        else
            fail "${name}: required DLL missing: ${pattern}"
        fi
    done
}

is_windows_system_dll() {
    local dll_name
    dll_name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    case "${dll_name}" in
        advapi32.dll|avrt.dll|bcrypt.dll|cfgmgr32.dll|comdlg32.dll|crypt32.dll|d3d11.dll|dwmapi.dll|dwrite.dll|dxgi.dll|gdi32.dll|imm32.dll|kernel32.dll|msvcrt.dll|ncrypt.dll|ntdll.dll|ole32.dll|oleaut32.dll|opengl32.dll|secur32.dll|shcore.dll|shell32.dll|shlwapi.dll|user32.dll|uxtheme.dll|version.dll|winspool.drv|ws2_32.dll)
            return 0
            ;;
        api-ms-win-*.dll)
            return 0
            ;;
    esac

    return 1
}

check_imported_dlls_present() {
    local bin_dir="${runtime_root}/bin"
    local objdump_bin=""

    if command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
        objdump_bin="x86_64-w64-mingw32-objdump"
    elif command -v objdump >/dev/null 2>&1; then
        objdump_bin="objdump"
    else
        fail "import gate: objdump not found"
        return
    fi

    shopt -s nullglob
    local dll
    local imported
    local missing=()
    for dll in "${bin_dir}"/*.dll; do
        while IFS= read -r imported; do
            [[ -z "${imported}" ]] && continue
            if is_windows_system_dll "${imported}"; then
                continue
            fi
            if [[ ! -f "${bin_dir}/${imported}" ]]; then
                missing+=("$(basename "${dll}") -> ${imported}")
            fi
        done < <("${objdump_bin}" -p "${dll}" | sed -n 's/^[[:space:]]*DLL Name: //p')
    done
    shopt -u nullglob

    if [[ "${#missing[@]}" -gt 0 ]]; then
        fail "import gate: missing runtime DLL(s): ${missing[*]}"
    else
        ok "import gate: all non-system DLL imports are bundled"
    fi
}

if [[ ! -d "${runtime_root}" ]]; then
    fail "runtime root does not exist: ${runtime_root}"
    exit 1
fi

manifest_path="${runtime_root}/runtime-manifest.json"
require_file "${manifest_path}"
require_dir_with_content "${runtime_root}/bin"
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
    "runtimeId": "octans-player-runtime-lgpl-win64",
    "target": "win-x64",
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
    "vulkan-headers",
    "vulkan-loader",
    "spirv-cross",
    "shaderc",
    "mingw-w64-gcc-runtime",
}
component_names = {str(component.get("name", "")) for component in components}
missing_components = sorted(required_components - component_names)
if missing_components:
    errors.append(f"required components missing: {', '.join(missing_components)}")

for component in components:
    for key in ("name", "version", "license", "sourceUrl"):
        if not component.get(key):
            errors.append(f"component is missing {key}: {component}")
    license_value = str(component.get("license", ""))
    is_gcc_runtime_exception = (
        component.get("name") == "mingw-w64-gcc-runtime"
        and license_value == "GPL-3.0-or-later WITH GCC-exception-3.1"
    )
    if (
        (license_value.startswith("GPL") and not is_gcc_runtime_exception)
        or "AGPL" in license_value
        or "nonfree" in license_value.lower()
    ):
        errors.append(f"forbidden component license: {component}")

if errors:
    for error in errors:
        print(f"FAIL manifest: {error}", file=sys.stderr)
    sys.exit(1)

print("OK   runtime-manifest.json")
PY
fi

shopt -s nullglob
mpv_dlls=("${runtime_root}/bin"/mpv*.dll)
avcodec_dlls=("${runtime_root}/bin"/avcodec*.dll)
avformat_dlls=("${runtime_root}/bin"/avformat*.dll)
avutil_dlls=("${runtime_root}/bin"/avutil*.dll)
shopt -u nullglob

[[ "${#mpv_dlls[@]}" -gt 0 ]] || fail "missing mpv*.dll"
[[ "${#avcodec_dlls[@]}" -gt 0 ]] || fail "missing avcodec*.dll"
[[ "${#avformat_dlls[@]}" -gt 0 ]] || fail "missing avformat*.dll"
[[ "${#avutil_dlls[@]}" -gt 0 ]] || fail "missing avutil*.dll"

[[ "${#mpv_dlls[@]}" -gt 0 ]] && ok "mpv dll: ${mpv_dlls[0]}"
[[ "${#avcodec_dlls[@]}" -gt 0 ]] && ok "avcodec dll: ${avcodec_dlls[0]}"
[[ "${#avformat_dlls[@]}" -gt 0 ]] && ok "avformat dll: ${avformat_dlls[0]}"
[[ "${#avutil_dlls[@]}" -gt 0 ]] && ok "avutil dll: ${avutil_dlls[0]}"

ffmpeg_config="${runtime_root}/build/ffmpeg-configure.txt"
libplacebo_options="${runtime_root}/build/dependency-build-options/libplacebo.txt"
mpv_options="${runtime_root}/build/mpv-meson-options.txt"
runtime_feature_summary="${runtime_root}/build/runtime-feature-summary.json"
sha256sums="${runtime_root}/build/sha256sums.txt"
sbom="${runtime_root}/build/sbom.spdx.json"

require_file "${ffmpeg_config}"
require_file "${libplacebo_options}"
require_file "${mpv_options}"
require_file "${runtime_feature_summary}"
require_file "${sha256sums}"
require_file "${sbom}"

check_forbidden_text "ffmpeg configure gate" "${ffmpeg_config}"
check_forbidden_text "libplacebo options gate" "${libplacebo_options}"
check_forbidden_text "mpv options gate" "${mpv_options}"
check_required_text \
    "ffmpeg configure gate" \
    "${ffmpeg_config}" \
    "--disable-gpl" \
    "--disable-nonfree" \
    "--disable-openssl" \
    "--enable-shared" \
    "--disable-static" \
    "--enable-d3d11va" \
    "--enable-dxva2" \
    "--enable-vulkan" \
    "--enable-libdav1d" \
    "--enable-libass" \
    "--enable-libfreetype" \
    "--enable-libfribidi" \
    "--enable-libharfbuzz" \
    "--enable-libzimg" \
    "--enable-lcms2" \
    "--disable-ffnvcodec" \
    "--disable-nvdec" \
    "--disable-nvenc" \
    "--disable-amf"
check_required_text \
    "libplacebo options gate" \
    "${libplacebo_options}" \
    "-Dvulkan=enabled" \
    "-Dvk-proc-addr=enabled" \
    "-Dd3d11=enabled" \
    "-Dshaderc=enabled" \
    "-Dlcms=enabled" \
    "-Dglslang=disabled" \
    "-Dlibdovi=disabled"
check_required_text \
    "mpv options gate" \
    "${mpv_options}" \
    "^[[:space:]]*gpl[[:space:]]+false" \
    "^[[:space:]]*libmpv[[:space:]]+true" \
    "^[[:space:]]*cplayer[[:space:]]+false" \
    "^[[:space:]]*d3d11[[:space:]]+enabled" \
    "^[[:space:]]*d3d-hwaccel[[:space:]]+enabled" \
    "^[[:space:]]*d3d9-hwaccel[[:space:]]+enabled" \
    "^[[:space:]]*vulkan[[:space:]]+enabled" \
    "^[[:space:]]*shaderc[[:space:]]+enabled" \
    "^[[:space:]]*spirv-cross[[:space:]]+enabled" \
    "^[[:space:]]*wasapi[[:space:]]+enabled" \
    "^[[:space:]]*lcms2[[:space:]]+enabled" \
    "^[[:space:]]*zimg[[:space:]]+enabled" \
    "^[[:space:]]*direct3d[[:space:]]+disabled" \
    "^[[:space:]]*rubberband[[:space:]]+disabled" \
    "^[[:space:]]*lua[[:space:]]+disabled" \
    "^[[:space:]]*javascript[[:space:]]+disabled"
check_required_glob \
    "runtime DLL gate" \
    "avcodec*.dll" \
    "avformat*.dll" \
    "avutil*.dll" \
    "libass*.dll" \
    "*freetype*.dll" \
    "*fribidi*.dll" \
    "*harfbuzz*.dll" \
    "*placebo*.dll" \
    "*zimg*.dll" \
    "*lcms2*.dll" \
    "vulkan-1.dll" \
    "*dav1d*.dll" \
    "*shaderc*.dll" \
    "*spirv-cross*.dll" \
    "libgcc_s_seh-1.dll" \
    "libstdc++-6.dll"
check_imported_dlls_present

if [[ -f "${runtime_feature_summary}" ]]; then
    python3 - <<'PY' "${runtime_feature_summary}" || failures=$((failures + 1))
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    summary = json.load(handle)

errors = []
if summary.get("schemaVersion") != 1:
    errors.append("schemaVersion must be 1")

evidence_sources = set(summary.get("evidenceSources") or [])
for required in ("component-presence", "configure-token"):
    if required not in evidence_sources:
        errors.append(f"missing evidence source: {required}")

if summary.get("capabilityFeatureSource") != "component-presence":
    errors.append("capabilityFeatureSource must stay component-presence until decoder/demuxer lists exist")

if summary.get("decoderList") is not None:
    errors.append("decoderList must be null for the current --disable-programs win64 artifact")

if summary.get("demuxerList") is not None:
    errors.append("demuxerList must be null for the current --disable-programs win64 artifact")

if errors:
    for error in errors:
        print(f"FAIL runtime-feature-summary: {error}", file=sys.stderr)
    sys.exit(1)

print("OK   runtime-feature-summary.json")
PY
fi

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
    echo "Runtime artifact verification failed: ${failures} failure(s)" >&2
    exit 1
fi

echo "Runtime artifact verification passed."
