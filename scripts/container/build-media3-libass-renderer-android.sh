#!/usr/bin/env bash
set -euo pipefail
umask 022

# Host-mounted source caches are owned by the runner user,
# while this container typically runs as root. Modern git refuses operations on
# repos whose directory owner differs from the current user unless marked safe.
# Cover bind-mounted caches, work trees, and nested submodule checkouts.
git config --global --add safe.directory '*'

runtime_id="octans-player-runtime-lgpl-media3-libass-renderer-android"
artifact_kind="media3-libass-renderer"
target="android-media3-libass-renderer"
runtime_version="${OCTANS_RUNTIME_VERSION:-0.0.0-local}"
output_root="${OCTANS_RUNTIME_OUTPUT:-/dist}"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-/cache/sources}"
android_sdk_root="${OCTANS_ANDROID_SDK_ROOT:-${ANDROID_HOME:-/cache/android-sdk}}"
gradle_user_home="${GRADLE_USER_HOME:-/cache/gradle}"
work_root="${OCTANS_RUNTIME_WORK_ROOT:-/tmp/octans-media3-libass-renderer-build}"
verify_script="${OCTANS_RUNTIME_VERIFY_SCRIPT:-/workspace/scripts/verify-media3-libass-renderer-artifact.sh}"
component_manifest="${OCTANS_RUNTIME_MANIFEST:-/workspace/build-manifests/media3-libass-renderer-android-components.json}"
patch_dir="${OCTANS_RUNTIME_PATCH_DIR:-/workspace/scripts/patches/libass-android}"

libass_android_ref="v0.5.0-beta01"
libass_android_tag_object="629a7c75a9be925c30c4b4b760f95eb7e3481964"
libass_android_commit="07b447fabceee6a0811e58652a468bb4b5429163"
libass_android_source_url="https://github.com/peerless2012/libass-android.git"

commandline_tools_version="13114758"
commandline_tools_sha256="7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee"
android_ndk_version="28.1.13356709"
compile_sdk="36"
min_sdk="21"
cmake_version="3.22.1"
android_build_tools_version="36.0.0"

artifact_root="${output_root}/${runtime_id}"
source_root="${work_root}/sources"
toolchain_root="${work_root}/toolchains"
libass_source="${source_root}/libass-android"

patches=(
    0001-rename-native-libraries.patch
    0002-limit-packaged-abis.patch
    0003-remove-duplicate-cxx-runtime.patch
    0004-record-octans-artifact-metadata.patch
    0005-fix-android-cross-configure-env.patch
    0006-configure-android-system-fontconfig.patch
    0007-align-mkv-font-attachment-detection.patch
)

require_command() {
    local name="$1"
    if ! command -v "${name}" >/dev/null 2>&1; then
        echo "Required command not found: ${name}" >&2
        exit 127
    fi
}

download() {
    local url="$1"
    local output="$2"

    if [[ -f "${output}" ]]; then
        return
    fi

    mkdir -p "$(dirname "${output}")"
    curl \
        -fL \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --continue-at - \
        "${url}" \
        -o "${output}.part"
    mv "${output}.part" "${output}"
}

verify_sha256() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "SHA256 mismatch for ${path}: expected ${expected}, got ${actual}" >&2
        exit 1
    fi
}

retry() {
    local description="$1"
    shift

    local attempt
    for attempt in 1 2 3 4 5; do
        if "$@"; then
            return 0
        fi

        echo "${description} failed on attempt ${attempt}" >&2
        sleep "$((attempt * 3))"
    done

    echo "${description} failed after retries" >&2
    return 1
}

git_clone_libass_android() {
    local destination="$1"

    git clone \
        --depth 1 \
        --branch "${libass_android_ref}" \
        --recurse-submodules \
        --shallow-submodules \
        "${libass_android_source_url}" \
        "${destination}"

    git -C "${destination}" submodule update --init --recursive --depth 1
}

verify_git_commit() {
    local repo="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(git -C "${repo}" rev-parse HEAD)"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "Git commit mismatch for ${label}: expected ${expected}, got ${actual}" >&2
        exit 1
    fi
}

verify_submodule_commit() {
    local relative_path="$1"
    local expected="$2"
    verify_git_commit "${libass_source}/${relative_path}" "${expected}" "${relative_path}"
}

clone_cached_libass_android() {
    local cache_dir="${source_cache}/libass-android-${libass_android_commit}"
    local temp_dir="${cache_dir}.tmp"

    if [[ ! -d "${cache_dir}/.git" ]]; then
        rm -rf "${temp_dir}"
        retry "Clone libass-android" git_clone_libass_android "${temp_dir}"
        rm -rf "${cache_dir}"
        mv "${temp_dir}" "${cache_dir}"
    fi

    verify_git_commit "${cache_dir}" "${libass_android_commit}" "libass-android"

    rm -rf "${libass_source}"
    cp -a "${cache_dir}" "${libass_source}"
    git -C "${libass_source}" submodule update --init --recursive --depth 1

    verify_git_commit "${libass_source}" "${libass_android_commit}" "libass-android"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake" "d3f00a43ca66e42a2c34de964b1a7dbbfa9dbc8b"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/ass" "bbb3c7f1570a4a021e52683f3fbdf74fe492ae84"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/expat" "f9a3eeb3e09fbea04b1c451ffc422ab2f1e45744"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/fontconfig" "daa175d234b8a362eedd4c18c33537cc2d19cd98"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/freetype" "42608f77f20749dd6ddc9e0536788eaad70ea4b5"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/freetype/subprojects/dlg" "72dfcc858c040c54a6a0b88fcb7e70ee186d3167"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/fribidi" "68162babff4f39c4e2dc164a5e825af93bda9983"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/harfbuzz" "c3fcbffa651cea70400552f2a8bd695ad11023c1"
    verify_submodule_commit "lib_ass/src/main/cpp/libass-cmake/src/unibreak" "304585d8e2d63187507368d612c3d5fff1486368"

    git -C "${libass_source}" submodule status --recursive >"${artifact_root}/build/upstream-submodules.txt"
}

copy_if_exists() {
    local source="$1"
    local destination="$2"

    if [[ -f "${source}" ]]; then
        cp "${source}" "${destination}"
    fi
}

normalize_artifact_permissions() {
    find "${artifact_root}" -type d -exec chmod 0755 {} +
    find "${artifact_root}" -type f -exec chmod 0644 {} +
}

archive_source_tree() {
    local archive_name="$1"
    local source_dir="$2"
    local base_name
    base_name="$(basename "${source_dir}")"

    tar -C "$(dirname "${source_dir}")" \
        --exclude="${base_name}/.git" \
        --exclude="${base_name}/.gradle" \
        --exclude="${base_name}/**/.git" \
        --exclude="${base_name}/**/.cxx" \
        --exclude="${base_name}/**/build" \
        -czf "${artifact_root}/sources/${archive_name}.tar.gz" \
        "${base_name}"
}

install_android_sdk() {
    local sdkmanager="${android_sdk_root}/cmdline-tools/latest/bin/sdkmanager"

    if [[ ! -x "${sdkmanager}" ]]; then
        local cmdline_zip="${source_cache}/commandlinetools-linux-${commandline_tools_version}_latest.zip"
        local cmdline_temp="${toolchain_root}/android-cmdline-tools"
        download "https://dl.google.com/android/repository/commandlinetools-linux-${commandline_tools_version}_latest.zip" "${cmdline_zip}"
        verify_sha256 "${commandline_tools_sha256}" "${cmdline_zip}"

        rm -rf "${cmdline_temp}" "${android_sdk_root}/cmdline-tools/latest"
        mkdir -p "${cmdline_temp}" "${android_sdk_root}/cmdline-tools"
        unzip -q "${cmdline_zip}" -d "${cmdline_temp}"
        mv "${cmdline_temp}/cmdline-tools" "${android_sdk_root}/cmdline-tools/latest"
    fi

    yes | "${sdkmanager}" --sdk_root="${android_sdk_root}" --licenses >/dev/null || true
    "${sdkmanager}" --sdk_root="${android_sdk_root}" \
        "platforms;android-${compile_sdk}" \
        "build-tools;${android_build_tools_version}" \
        "cmake;${cmake_version}" \
        "ndk;${android_ndk_version}" >/dev/null
}

apply_octans_patches() {
    mkdir -p "${artifact_root}/build/patches"
    : >"${artifact_root}/build/patches-applied.txt"

    local patch_name
    for patch_name in "${patches[@]}"; do
        local patch_file="${patch_dir}/${patch_name}"
        if [[ ! -f "${patch_file}" ]]; then
            echo "Missing libass-android patch: ${patch_file}" >&2
            exit 1
        fi

        cp "${patch_file}" "${artifact_root}/build/patches/${patch_name}"
        (
            cd "${libass_source}"
            patch -p1 --forward <"${patch_file}"
        )
        printf '%s\n' "${patch_name}" >>"${artifact_root}/build/patches-applied.txt"
    done
}

normalize_upstream_patch_targets() {
    local target
    local targets=(
        OCTANS_ARTIFACT.md
        lib_ass/build.gradle.kts
        lib_ass/src/main/cpp/CMakeLists.txt
        lib_ass/src/main/cpp/libass-cmake/cmake/ass.cmake
        lib_ass/src/main/cpp/libass-cmake/cmake/fontconfig.cmake
        lib_ass_kt/build.gradle.kts
        lib_ass_kt/src/main/cpp/AssKt.c
        lib_ass_kt/src/main/cpp/CMakeLists.txt
        lib_ass_kt/src/main/java/io/github/peerless2012/ass/Ass.kt
        lib_ass_kt/src/main/java/io/github/peerless2012/ass/AssRender.kt
        lib_ass_media/src/main/java/io/github/peerless2012/ass/media/extractor/AssMatroskaExtractor.kt
    )

    for target in "${targets[@]}"; do
        if [[ -f "${libass_source}/${target}" ]]; then
            perl -0pi -e 's/\r\n/\n/g' "${libass_source}/${target}"
        fi
    done
}

run_autoreconf() {
    local log_file="${artifact_root}/build/autoreconf.log"
    local directories=(
        "lib_ass/src/main/cpp/libass-cmake/src/ass"
        "lib_ass/src/main/cpp/libass-cmake/src/expat/expat"
        "lib_ass/src/main/cpp/libass-cmake/src/fontconfig"
        "lib_ass/src/main/cpp/libass-cmake/src/fribidi"
        "lib_ass/src/main/cpp/libass-cmake/src/unibreak"
    )

    : >"${log_file}"

    local relative_dir
    for relative_dir in "${directories[@]}"; do
        {
            printf '== autoreconf %s ==\n' "${relative_dir}"
            (
                cd "${libass_source}/${relative_dir}"
                autoreconf -fiv
            )
        } 2>&1 | tee -a "${log_file}"
    done
}

build_aars() {
    export ANDROID_HOME="${android_sdk_root}"
    export ANDROID_SDK_ROOT="${android_sdk_root}"
    export GRADLE_USER_HOME="${gradle_user_home}"

    chmod +x "${libass_source}/gradlew"

    local attempt
    local sleep_seconds
    for attempt in 1 2 3; do
        if "${libass_source}/gradlew" \
            --no-daemon \
            --console=plain \
            -p "${libass_source}" \
            :lib_ass_kt:assembleRelease \
            :lib_ass_media:assembleRelease; then
            break
        fi

        if [[ "${attempt}" == "3" ]]; then
            printf 'Gradle libass renderer build failed after %s attempts\n' "${attempt}" >&2
            exit 1
        fi

        sleep_seconds=$((attempt * 20))
        printf 'Gradle libass renderer build failed on attempt %s, retrying in %s seconds\n' \
            "${attempt}" "${sleep_seconds}" >&2
        sleep "${sleep_seconds}"
    done

    cp \
        "${libass_source}/lib_ass_kt/build/outputs/aar/lib_ass_kt-release.aar" \
        "${artifact_root}/aar/lib_ass_kt-release.aar"
    cp \
        "${libass_source}/lib_ass_media/build/outputs/aar/lib_ass_media-release.aar" \
        "${artifact_root}/aar/lib_ass_media-release.aar"

    unzip -l "${artifact_root}/aar/lib_ass_kt-release.aar" >"${artifact_root}/build/lib_ass_kt-aar-contents.txt"
    unzip -l "${artifact_root}/aar/lib_ass_media-release.aar" >"${artifact_root}/build/lib_ass_media-aar-contents.txt"
}

write_native_inventory() {
    local temp_dir
    temp_dir="$(mktemp -d)"

    unzip -q "${artifact_root}/aar/lib_ass_kt-release.aar" -d "${temp_dir}"
    {
        find "${temp_dir}/jni" -type f -name '*.so' | sort | while read -r so_file; do
            local relative_path="${so_file#${temp_dir}/}"
            printf '## %s\n' "${relative_path}"
            readelf -d "${so_file}"
            printf '\n'
        done
    } >"${artifact_root}/build/native-inventory.txt"

    rm -rf "${temp_dir}"
}

write_javap_inventory() {
    local temp_dir
    temp_dir="$(mktemp -d)"

    unzip -q "${artifact_root}/aar/lib_ass_kt-release.aar" classes.jar -d "${temp_dir}"
    javap \
        -classpath "${temp_dir}/classes.jar" \
        io.github.peerless2012.ass.Ass \
        io.github.peerless2012.ass.AssRender \
        >"${artifact_root}/build/javap-Ass.txt"
    jar tf "${temp_dir}/classes.jar" >"${artifact_root}/build/lib_ass_kt-classes.txt"
    rm -rf "${temp_dir}"

    temp_dir="$(mktemp -d)"
    unzip -q "${artifact_root}/aar/lib_ass_media-release.aar" classes.jar -d "${temp_dir}"
    jar tf "${temp_dir}/classes.jar" >"${artifact_root}/build/lib_ass_media-classes.txt"
    rm -rf "${temp_dir}"
}

copy_license_evidence() {
    copy_if_exists "${libass_source}/LICENSE" "${artifact_root}/licenses/libass-android-LICENSE"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/ass/COPYING" "${artifact_root}/licenses/libass-COPYING"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/expat/COPYING" "${artifact_root}/licenses/expat-COPYING"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/fontconfig/COPYING" "${artifact_root}/licenses/fontconfig-COPYING"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/freetype/LICENSE.TXT" "${artifact_root}/licenses/freetype-LICENSE.TXT"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/fribidi/COPYING" "${artifact_root}/licenses/fribidi-COPYING"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/harfbuzz/COPYING" "${artifact_root}/licenses/harfbuzz-COPYING"
    copy_if_exists "${libass_source}/lib_ass/src/main/cpp/libass-cmake/src/unibreak/LICENCE" "${artifact_root}/licenses/libunibreak-LICENCE"
}

write_sbom() {
    cat >"${artifact_root}/build/sbom.spdx.json" <<EOF
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "${runtime_id}-${runtime_version}",
  "documentNamespace": "https://octans.local/sbom/${runtime_id}/${runtime_version}",
  "creationInfo": {
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "creators": [
      "Tool: octans-player-runtime"
    ]
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-libass-android",
      "name": "libass-android",
      "versionInfo": "${libass_android_ref}",
      "downloadLocation": "${libass_android_source_url}",
      "licenseDeclared": "MIT"
    },
    {
      "SPDXID": "SPDXRef-libass",
      "name": "libass",
      "versionInfo": "bbb3c7f1570a4a021e52683f3fbdf74fe492ae84",
      "downloadLocation": "https://github.com/libass/libass.git",
      "licenseDeclared": "ISC"
    },
    {
      "SPDXID": "SPDXRef-expat",
      "name": "expat",
      "versionInfo": "f9a3eeb3e09fbea04b1c451ffc422ab2f1e45744",
      "downloadLocation": "https://github.com/libexpat/libexpat.git",
      "licenseDeclared": "MIT"
    },
    {
      "SPDXID": "SPDXRef-fontconfig",
      "name": "fontconfig",
      "versionInfo": "daa175d234b8a362eedd4c18c33537cc2d19cd98",
      "downloadLocation": "https://gitlab.freedesktop.org/fontconfig/fontconfig",
      "licenseDeclared": "MIT"
    },
    {
      "SPDXID": "SPDXRef-freetype",
      "name": "freetype",
      "versionInfo": "42608f77f20749dd6ddc9e0536788eaad70ea4b5",
      "downloadLocation": "https://gitlab.freedesktop.org/freetype/freetype.git"
    },
    {
      "SPDXID": "SPDXRef-fribidi",
      "name": "fribidi",
      "versionInfo": "68162babff4f39c4e2dc164a5e825af93bda9983",
      "downloadLocation": "https://github.com/fribidi/fribidi.git",
      "licenseDeclared": "LGPL-2.1-or-later"
    },
    {
      "SPDXID": "SPDXRef-harfbuzz",
      "name": "harfbuzz",
      "versionInfo": "c3fcbffa651cea70400552f2a8bd695ad11023c1",
      "downloadLocation": "https://github.com/harfbuzz/harfbuzz.git",
      "licenseDeclared": "MIT"
    },
    {
      "SPDXID": "SPDXRef-libunibreak",
      "name": "libunibreak",
      "versionInfo": "304585d8e2d63187507368d612c3d5fff1486368",
      "downloadLocation": "https://github.com/adah1972/libunibreak.git",
      "licenseDeclared": "Zlib"
    }
  ]
}
EOF
}

file_kind_for_path() {
    local relative_path="$1"

    case "${relative_path}" in
        aar/*)
            printf 'aar'
            ;;
        licenses/*)
            printf 'license'
            ;;
        sources/*)
            printf 'source'
            ;;
        build/patches/*)
            printf 'source-patch'
            ;;
        build/*)
            printf 'build-evidence'
            ;;
        runtime-manifest.json)
            printf 'manifest'
            ;;
        *)
            printf 'artifact'
            ;;
    esac
}

write_manifests() {
    local files_jsonl
    files_jsonl="$(mktemp)"
    trap 'rm -f "${files_jsonl}"' RETURN

    while IFS= read -r -d '' file_path; do
        local relative_path="${file_path#${artifact_root}/}"
        local file_sha
        local file_size
        local file_kind
        file_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
        file_size="$(stat -c '%s' "${file_path}")"
        file_kind="$(file_kind_for_path "${relative_path}")"
        jq -n \
            --arg kind "${file_kind}" \
            --arg path "${relative_path}" \
            --arg sha256 "${file_sha}" \
            --argjson sizeBytes "${file_size}" \
            '{kind: $kind, path: $path, sha256: $sha256, sizeBytes: $sizeBytes}' \
            >>"${files_jsonl}"
    done < <(
        find "${artifact_root}" -type f \
            ! -path "${artifact_root}/runtime-manifest.json" \
            ! -path "${artifact_root}/build/android-media3-libass-renderer-manifest.json" \
            ! -path "${artifact_root}/build/sha256sums.txt" \
            -print0 | sort -z
    )

    local files_json
    files_json="$(jq -s '.' "${files_jsonl}")"

    jq -n \
        --slurpfile component "${component_manifest}" \
        --arg version "${runtime_version}" \
        --arg createdAtUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg libassAndroidCommit "${libass_android_commit}" \
        --arg libassAndroidTagObject "${libass_android_tag_object}" \
        --arg patchSetFile "build/patches-applied.txt" \
        --arg submoduleStatusFile "build/upstream-submodules.txt" \
        --arg sha256sums "build/sha256sums.txt" \
        --arg sbom "build/sbom.spdx.json" \
        --argjson files "${files_json}" \
        '
        $component[0] + {
          schemaVersion: 1,
          createdAtUtc: $createdAtUtc,
          version: $version,
          libassAndroid: ($component[0].libassAndroid + {
            sourceCommit: $libassAndroidCommit,
            sourceTagObject: $libassAndroidTagObject,
            patchSetFile: $patchSetFile,
            submoduleStatusFile: $submoduleStatusFile
          }),
          files: $files,
          sha256sums: $sha256sums,
          sbom: $sbom
        }' >"${artifact_root}/runtime-manifest.json"

    cp "${artifact_root}/runtime-manifest.json" "${artifact_root}/build/android-media3-libass-renderer-manifest.json"
}

write_sha256sums() {
    (
        cd "${artifact_root}"
        find . -type f ! -path './build/sha256sums.txt' -print0 \
            | sort -z \
            | xargs -0 sha256sum > build/sha256sums.txt
    )
}

require_command autoreconf
require_command curl
require_command git
require_command jar
require_command javap
require_command jq
require_command make
require_command patch
require_command perl
require_command readelf
require_command sha256sum
require_command stat
require_command tar
require_command unzip

if [[ ! -x "${verify_script}" ]]; then
    echo "Media3 libass renderer verification script is not executable: ${verify_script}" >&2
    exit 1
fi

if [[ ! -f "${component_manifest}" ]]; then
    echo "Component manifest not found: ${component_manifest}" >&2
    exit 1
fi

if [[ ! -d "${patch_dir}" ]]; then
    echo "Patch directory not found: ${patch_dir}" >&2
    exit 1
fi

rm -rf "${work_root}" "${artifact_root}"
mkdir -p \
    "${artifact_root}/aar" \
    "${artifact_root}/licenses" \
    "${artifact_root}/sources" \
    "${artifact_root}/build" \
    "${source_root}" \
    "${toolchain_root}" \
    "${source_cache}" \
    "${android_sdk_root}" \
    "${gradle_user_home}"

install_android_sdk
clone_cached_libass_android
normalize_upstream_patch_targets
apply_octans_patches
run_autoreconf
copy_license_evidence
archive_source_tree "libass-android-${libass_android_ref}-${libass_android_commit}" "${libass_source}"
build_aars
write_native_inventory
write_javap_inventory
write_sbom
write_manifests
write_sha256sums
normalize_artifact_permissions

"${verify_script}" "${artifact_root}"

echo "Media3 libass renderer artifact created: ${artifact_root}"
