#!/usr/bin/env bash
set -euo pipefail
umask 022

# Host-mounted source caches are owned by the runner user,
# while this container typically runs as root. Modern git refuses operations on
# repos whose directory owner differs from the current user unless marked safe.
# Cover bind-mounted caches, work trees, and nested submodule checkouts.
git config --global --add safe.directory '*'

runtime_id="octans-player-runtime-lgpl-media3-ffmpeg-decoder-android"
artifact_kind="media3-ffmpeg-decoder"
target="android-media3-ffmpeg-decoder"
runtime_version="${OCTANS_RUNTIME_VERSION:-0.0.0-local}"
output_root="${OCTANS_RUNTIME_OUTPUT:-/dist}"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-/cache/sources}"
android_sdk_root="${OCTANS_ANDROID_SDK_ROOT:-${ANDROID_HOME:-/cache/android-sdk}}"
gradle_user_home="${GRADLE_USER_HOME:-/cache/gradle}"
work_root="${OCTANS_RUNTIME_WORK_ROOT:-/tmp/octans-media3-ffmpeg-decoder-build}"
verify_script="${OCTANS_RUNTIME_VERIFY_SCRIPT:-/workspace/scripts/verify-media3-ffmpeg-decoder-artifact.sh}"
component_manifest="${OCTANS_RUNTIME_MANIFEST:-/workspace/build-manifests/media3-ffmpeg-decoder-android-components.json}"

media3_ref="release"
media3_commit="5fb306449733dd71595700c1227ad6087578c559"
media3_version="1.10.1"
media3_source_url="https://github.com/androidx/media.git"

ffmpeg_ref="release/6.0"
ffmpeg_commit="32291d4ac3fae922591cee11b82318d8d3857be2"
ffmpeg_source_url="https://git.ffmpeg.org/ffmpeg.git"
ffmpeg_fallback_url="https://github.com/FFmpeg/FFmpeg.git"

gradle_version="9.4.1"
gradle_sha256="2ab2958f2a1e51120c326cad6f385153bb11ee93b3c216c5fccebfdfbb7ec6cb"
commandline_tools_version="13114758"
commandline_tools_sha256="7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee"
android_ndk_version="29.0.14206865"
android_ndk_ref="r29"
android_ndk_sha1="87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b"
android_api="28"
compile_sdk="36"
min_sdk="28"
cmake_version="3.22.1"
android_build_tools_version="36.0.0"

enabled_decoders=(
    aac
    ac3
    eac3
    dca
    truehd
    flac
    opus
    vorbis
    mp3
)

enabled_filters=(
    abuffer
    abuffersink
    aformat
    pan
    dynaudnorm
    aresample
)

configure_enabled_filters=(
    aformat
    pan
    dynaudnorm
    aresample
)

dialogue_stereo_graph_profile="dynaudnorm-low-window"
dialogue_stereo_filter_chain="aformat=sample_fmts=fltp,pan=stereo|FL=1.00*FL+1.05*FC+0.35*SL+0.35*BL+0.25*BC+0.15*TFL+0.10*TBL+0.05*LFE|FR=1.00*FR+1.05*FC+0.35*SR+0.35*BR+0.25*BC+0.15*TFR+0.10*TBR+0.05*LFE,dynaudnorm=framelen=100:gausssize=3:maxgain=10,aresample=48000"

artifact_root="${output_root}/${runtime_id}"
source_root="${work_root}/sources"
build_root="${work_root}/build"
toolchain_root="${work_root}/toolchains"
project_root="${work_root}/gradle-project"
module_dir="${project_root}/media3-decoder-ffmpeg"
gradle_home="${toolchain_root}/gradle-${gradle_version}"
overlay_dir="${OCTANS_RUNTIME_OVERLAY_DIR:-/workspace/scripts/overlays/media3-ffmpeg-decoder}"

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

verify_sha1() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(sha1sum "${path}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "SHA1 mismatch for ${path}: expected ${expected}, got ${actual}" >&2
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

git_clone_once() {
    local url="$1"
    local ref="$2"
    local destination="$3"

    git clone --depth 1 --branch "${ref}" "${url}" "${destination}"
}

clone_cached_project() {
    local name="$1"
    local ref="$2"
    local expected_commit="$3"
    local primary_url="$4"
    local fallback_url="$5"
    local destination="$6"

    local cache_dir="${source_cache}/${name}-${expected_commit}"
    local temp_dir="${cache_dir}.tmp"

    if [[ ! -d "${cache_dir}/.git" ]]; then
        rm -rf "${temp_dir}"
        if ! retry "Clone ${name} from primary source" \
            git_clone_once "${primary_url}" "${ref}" "${temp_dir}"; then
            rm -rf "${temp_dir}"
            if [[ -z "${fallback_url}" ]]; then
                return 1
            fi
            retry "Clone ${name} from fallback source" \
                git_clone_once "${fallback_url}" "${ref}" "${temp_dir}"
        fi
        rm -rf "${cache_dir}"
        mv "${temp_dir}" "${cache_dir}"
    fi

    local actual_commit
    actual_commit="$(git -C "${cache_dir}" rev-parse HEAD)"
    if [[ "${actual_commit}" != "${expected_commit}" ]]; then
        echo "Git commit mismatch for ${name}: expected ${expected_commit}, got ${actual_commit}" >&2
        exit 1
    fi

    rm -rf "${destination}"
    cp -a "${cache_dir}" "${destination}"
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

    tar -C "$(dirname "${source_dir}")" \
        --exclude="$(basename "${source_dir}")/.git" \
        -czf "${artifact_root}/sources/${archive_name}.tar.gz" \
        "$(basename "${source_dir}")"
}

record_command() {
    local output_file="$1"
    shift

    printf '%q ' "$@" >"${output_file}"
    printf '\n' >>"${output_file}"
}

install_gradle() {
    local gradle_zip="${source_cache}/gradle-${gradle_version}-bin.zip"
    download "https://services.gradle.org/distributions/gradle-${gradle_version}-bin.zip" "${gradle_zip}"
    verify_sha256 "${gradle_sha256}" "${gradle_zip}"

    if [[ ! -x "${gradle_home}/bin/gradle" ]]; then
        rm -rf "${gradle_home}"
        mkdir -p "${toolchain_root}"
        unzip -q "${gradle_zip}" -d "${toolchain_root}"
    fi
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

    local ndk_zip="${source_cache}/android-ndk-${android_ndk_ref}-linux.zip"
    if [[ ! -f "${ndk_zip}" ]]; then
        download "https://dl.google.com/android/repository/android-ndk-${android_ndk_ref}-linux.zip" "${ndk_zip}"
    fi
    verify_sha1 "${android_ndk_sha1}" "${ndk_zip}"
}

prepare_project() {
    local media3_source="$1"
    local ffmpeg_source="$2"

    rm -rf "${project_root}"
    mkdir -p "${module_dir}/src/main/jni"

    cp -a "${media3_source}/libraries/decoder_ffmpeg/src/main/java" "${module_dir}/src/main/"
    rm -f "${module_dir}/src/main/java/androidx/media3/decoder/ffmpeg/ExperimentalFfmpegVideoRenderer.java"
    cp "${media3_source}/libraries/decoder_ffmpeg/src/main/AndroidManifest.xml" "${module_dir}/src/main/AndroidManifest.xml"
    cp "${media3_source}/libraries/decoder_ffmpeg/src/main/jni/CMakeLists.txt" "${module_dir}/src/main/jni/CMakeLists.txt"
    cp "${media3_source}/libraries/decoder_ffmpeg/src/main/jni/ffmpeg_jni.cc" "${module_dir}/src/main/jni/ffmpeg_jni.cc"
    cp "${media3_source}/libraries/decoder_ffmpeg/proguard-rules.txt" "${module_dir}/proguard-rules.txt"
    cp -a "${ffmpeg_source}" "${module_dir}/src/main/jni/ffmpeg"

    if [[ ! -d "${overlay_dir}" ]]; then
        echo "Media3 FFmpeg decoder overlay not found: ${overlay_dir}" >&2
        exit 1
    fi
    cp -a "${overlay_dir}/src/main/java/." "${module_dir}/src/main/java/"
    cp "${overlay_dir}/src/main/jni/ffmpeg_jni.cc" "${module_dir}/src/main/jni/ffmpeg_jni.cc"

    sed -i \
        's|include_directories(${ffmpeg_location})|include_directories("${ffmpeg_binaries}/include" "${ffmpeg_location}")|' \
        "${module_dir}/src/main/jni/CMakeLists.txt"
    sed -i \
        's|foreach(ffmpeg_lib avutil swresample avcodec)|foreach(ffmpeg_lib avutil swresample avfilter avcodec)|' \
        "${module_dir}/src/main/jni/CMakeLists.txt"
    sed -i \
        's|PRIVATE swresample|PRIVATE avfilter\n                      PRIVATE swresample|' \
        "${module_dir}/src/main/jni/CMakeLists.txt"

    cat >"${project_root}/settings.gradle.kts" <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "OctansMedia3FfmpegDecoder"
include(":media3-decoder-ffmpeg")
EOF

    cat >"${project_root}/build.gradle.kts" <<'EOF'
plugins {
    id("com.android.library") version "9.2.0" apply false
}
EOF

    cat >"${module_dir}/build.gradle.kts" <<EOF
plugins {
    id("com.android.library")
}

private val media3Version = "${media3_version}"

android {
    namespace = "androidx.media3.decoder.ffmpeg"
    compileSdk = ${compile_sdk}
    ndkVersion = "${android_ndk_version}"

    defaultConfig {
        minSdk = ${min_sdk}
        consumerProguardFiles("proguard-rules.txt")

        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/jni/CMakeLists.txt")
            version = "${cmake_version}"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api("androidx.media3:media3-decoder:\$media3Version")
    implementation("androidx.media3:media3-exoplayer:\$media3Version")
    implementation("androidx.annotation:annotation:1.6.0")
    implementation("com.google.guava:guava:33.3.1-android")
    compileOnly("org.checkerframework:checker-qual:3.13.0")
    compileOnly("org.jetbrains.kotlin:kotlin-annotations-jvm:1.9.0")
}
EOF

    cat >"${project_root}/local.properties" <<EOF
sdk.dir=${android_sdk_root}
EOF
}

build_ffmpeg_static_libs() {
    local ffmpeg_build_dir="${module_dir}/src/main/jni/ffmpeg"
    local toolchain_prefix="${android_sdk_root}/ndk/${android_ndk_version}/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local jobs
    jobs="$(nproc 2>/dev/null || echo 4)"

    if [[ ! -d "${toolchain_prefix}" ]]; then
        echo "Android NDK toolchain not found: ${toolchain_prefix}" >&2
        exit 1
    fi

    local common_options=(
        --target-os=android
        --enable-static
        --disable-shared
        --disable-doc
        --disable-programs
        --disable-everything
        --disable-avdevice
        --disable-avformat
        --disable-swscale
        --disable-postproc
        --disable-filters
        --enable-avfilter
        --disable-symver
        --enable-swresample
        --extra-ldexeflags=-pie
        --disable-v4l2-m2m
        --disable-vulkan
    )

    local decoder
    for decoder in "${enabled_decoders[@]}"; do
        common_options+=("--enable-decoder=${decoder}")
    done
    local filter
    for filter in "${configure_enabled_filters[@]}"; do
        common_options+=("--enable-filter=${filter}")
    done

    build_abi() {
        local abi="$1"
        shift

        local configure_log="${artifact_root}/build/ffmpeg-configure-${abi}.txt"
        (
            cd "${ffmpeg_build_dir}"
            make distclean >/dev/null 2>&1 || true
            record_command "${configure_log}" ./configure --libdir="android-libs/${abi}" --incdir="android-libs/${abi}/include" "$@" "${common_options[@]}"
            ./configure --libdir="android-libs/${abi}" --incdir="android-libs/${abi}/include" "$@" "${common_options[@]}" 2>&1 | tee -a "${configure_log}"
            make -j"${jobs}"
            make install-libs
            make install-headers
            make distclean >/dev/null 2>&1 || true
        )
    }

    local armv7_clang="${toolchain_prefix}/armv7a-linux-androideabi${android_api}-clang"
    if [[ ! -x "${armv7_clang}" ]]; then
        echo "Android armv7 clang compiler not found: ${armv7_clang}" >&2
        exit 1
    fi

    build_abi "armeabi-v7a" \
        --arch=arm \
        --cpu=armv7-a \
        --cross-prefix="${toolchain_prefix}/armv7a-linux-androideabi${android_api}-" \
        --nm="${toolchain_prefix}/llvm-nm" \
        --ar="${toolchain_prefix}/llvm-ar" \
        --ranlib="${toolchain_prefix}/llvm-ranlib" \
        --strip="${toolchain_prefix}/llvm-strip" \
        --extra-cflags="-march=armv7-a -mfloat-abi=softfp" \
        --extra-ldflags="-Wl,--fix-cortex-a8"

    build_abi "arm64-v8a" \
        --arch=aarch64 \
        --cpu=armv8-a \
        --cross-prefix="${toolchain_prefix}/aarch64-linux-android${android_api}-" \
        --nm="${toolchain_prefix}/llvm-nm" \
        --ar="${toolchain_prefix}/llvm-ar" \
        --ranlib="${toolchain_prefix}/llvm-ranlib" \
        --strip="${toolchain_prefix}/llvm-strip"
}

build_aar() {
    export ANDROID_HOME="${android_sdk_root}"
    export ANDROID_SDK_ROOT="${android_sdk_root}"
    export GRADLE_USER_HOME="${gradle_user_home}"

    local attempt
    local sleep_seconds
    for attempt in 1 2 3; do
        if "${gradle_home}/bin/gradle" \
            --no-daemon \
            --console=plain \
            -p "${project_root}" \
            :media3-decoder-ffmpeg:assembleRelease; then
            break
        fi

        if [[ "${attempt}" == "3" ]]; then
            printf 'Gradle Media3 FFmpeg decoder build failed after %s attempts\n' "${attempt}" >&2
            exit 1
        fi

        sleep_seconds=$((attempt * 20))
        printf 'Gradle Media3 FFmpeg decoder build failed on attempt %s, retrying in %s seconds\n' \
            "${attempt}" "${sleep_seconds}" >&2
        sleep "${sleep_seconds}"
    done

    cp \
        "${module_dir}/build/outputs/aar/media3-decoder-ffmpeg-release.aar" \
        "${artifact_root}/aar/media3-decoder-ffmpeg-release.aar"

    unzip -l "${artifact_root}/aar/media3-decoder-ffmpeg-release.aar" >"${artifact_root}/build/aar-contents.txt"
    cp "${module_dir}/src/main/jni/CMakeLists.txt" "${artifact_root}/build/CMakeLists.txt"
}

write_enabled_decoders() {
    printf '%s\n' "${enabled_decoders[@]}" >"${artifact_root}/build/enabled-decoders.txt"
}

write_enabled_filters() {
    printf '%s\n' "${enabled_filters[@]}" >"${artifact_root}/build/enabled-filters.txt"
}

run_graph_smoke() {
    require_command ffmpeg
    require_command awk

    local smoke_root="${build_root}/graph-smoke"
    mkdir -p "${smoke_root}"

    local expected_bytes=$((48000 * 2 * 4 / 4))
    local profile="${dialogue_stereo_graph_profile}"
    local filter_chain="${dialogue_stereo_filter_chain}"
    local output_5_1="${smoke_root}/synthetic-${profile}-5point1-side-fc.f32"
    local output_7_1="${smoke_root}/synthetic-${profile}-7point1-fc.f32"
    local astats_5_1="${artifact_root}/build/graph-smoke-${profile}-5point1-astats.txt"
    local astats_7_1="${artifact_root}/build/graph-smoke-${profile}-7point1-astats.txt"

    cat >"${artifact_root}/build/graph-smoke-summary.txt" <<EOF
octans media3 ffmpeg decoder graph smoke
EOF

    ffmpeg -hide_banner -loglevel error \
        -f lavfi \
        -i "aevalsrc=0|0|0.5*sin(2*PI*1000*t)|0|0|0:s=48000:d=0.25:channel_layout=5.1(side)" \
        -af "${filter_chain}" \
        -f f32le \
        "${output_5_1}"
    ffmpeg -hide_banner -loglevel error \
        -f lavfi \
        -i "aevalsrc=0|0|0.5*sin(2*PI*1000*t)|0|0|0|0|0:s=48000:d=0.25:channel_layout=7.1" \
        -af "${filter_chain}" \
        -f f32le \
        "${output_7_1}"

    local size_5_1
    local size_7_1
    size_5_1="$(stat -c '%s' "${output_5_1}")"
    size_7_1="$(stat -c '%s' "${output_7_1}")"
    if [[ "${size_5_1}" != "${expected_bytes}" || "${size_7_1}" != "${expected_bytes}" ]]; then
        echo "Unexpected graph smoke output size for ${profile}: 5.1=${size_5_1}, 7.1=${size_7_1}, expected=${expected_bytes}" >&2
        exit 1
    fi

    ffmpeg -hide_banner -nostats \
        -f f32le -ar 48000 -ac 2 -i "${output_5_1}" \
        -af astats=metadata=1:reset=0 \
        -f null - >"${astats_5_1}" 2>&1
    ffmpeg -hide_banner -nostats \
        -f f32le -ar 48000 -ac 2 -i "${output_7_1}" \
        -af astats=metadata=1:reset=0 \
        -f null - >"${astats_7_1}" 2>&1

    if ! awk '/RMS level dB:/ && $NF != "-inf" { count++ } END { exit(count >= 2 ? 0 : 1) }' "${astats_5_1}"; then
        echo "5.1 graph smoke did not produce non-zero stereo energy for ${profile}." >&2
        exit 1
    fi
    if ! awk '/RMS level dB:/ && $NF != "-inf" { count++ } END { exit(count >= 2 ? 0 : 1) }' "${astats_7_1}"; then
        echo "7.1 graph smoke did not produce non-zero stereo energy for ${profile}." >&2
        exit 1
    fi

    cat >>"${artifact_root}/build/graph-smoke-summary.txt" <<EOF
profile=${profile}
filter_chain=${filter_chain}
synthetic_5point1_layout=5.1(side)
synthetic_5point1_output=stereo/48000/f32le
synthetic_5point1_bytes=${size_5_1}
synthetic_7point1_layout=7.1
synthetic_7point1_output=stereo/48000/f32le
synthetic_7point1_bytes=${size_7_1}
profile_${profile}_result=passed
EOF

    cat >>"${artifact_root}/build/graph-smoke-summary.txt" <<EOF
result=passed
EOF
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
      "SPDXID": "SPDXRef-Media3",
      "name": "androidx-media decoder_ffmpeg",
      "versionInfo": "${media3_version}",
      "downloadLocation": "${media3_source_url}"
    },
    {
      "SPDXID": "SPDXRef-FFmpeg",
      "name": "FFmpeg",
      "versionInfo": "${ffmpeg_ref}",
      "downloadLocation": "${ffmpeg_source_url}"
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
            ! -path "${artifact_root}/build/android-media3-ffmpeg-decoder-manifest.json" \
            ! -path "${artifact_root}/build/sha256sums.txt" \
            -print0 | sort -z
    )

    local files_json
    files_json="$(jq -s '.' "${files_jsonl}")"

    jq -n \
        --slurpfile component "${component_manifest}" \
        --arg version "${runtime_version}" \
        --arg createdAtUtc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg media3SourceCommit "${media3_commit}" \
        --arg ffmpegCommit "${ffmpeg_commit}" \
        --arg sha256sums "build/sha256sums.txt" \
        --arg sbom "build/sbom.spdx.json" \
        --argjson files "${files_json}" \
        '
        $component[0] + {
          schemaVersion: 1,
          createdAtUtc: $createdAtUtc,
          version: $version,
          media3: ($component[0].media3 + {
            sourceCommit: $media3SourceCommit
          }),
          ffmpeg: ($component[0].ffmpeg + {
            commit: $ffmpegCommit,
            configureFiles: {
              "arm64-v8a": "build/ffmpeg-configure-arm64-v8a.txt",
              "armeabi-v7a": "build/ffmpeg-configure-armeabi-v7a.txt"
            },
            enabledDecodersFile: "build/enabled-decoders.txt",
            enabledFiltersFile: "build/enabled-filters.txt",
            dialogueStereoGraphSmoke: "build/graph-smoke-summary.txt",
            licenseEvidence: "build/ffmpeg-configure-arm64-v8a.txt and build/ffmpeg-configure-armeabi-v7a.txt report LGPL, with GPL and nonfree configure flags absent."
          }),
          files: $files,
          sha256sums: $sha256sums,
          sbom: $sbom
        }' >"${artifact_root}/runtime-manifest.json"

    cp "${artifact_root}/runtime-manifest.json" "${artifact_root}/build/android-media3-ffmpeg-decoder-manifest.json"
}

write_sha256sums() {
    (
        cd "${artifact_root}"
        find . -type f ! -path './build/sha256sums.txt' -print0 \
            | sort -z \
            | xargs -0 sha256sum > build/sha256sums.txt
    )
}

require_command curl
require_command git
require_command jq
require_command make
require_command sha1sum
require_command sha256sum
require_command stat
require_command unzip
require_command zip

if [[ ! -x "${verify_script}" ]]; then
    echo "Media3 FFmpeg decoder verification script is not executable: ${verify_script}" >&2
    exit 1
fi

if [[ ! -f "${component_manifest}" ]]; then
    echo "Component manifest not found: ${component_manifest}" >&2
    exit 1
fi

rm -rf "${work_root}" "${artifact_root}"
mkdir -p \
    "${artifact_root}/aar" \
    "${artifact_root}/licenses" \
    "${artifact_root}/sources" \
    "${artifact_root}/build" \
    "${source_root}" \
    "${build_root}" \
    "${toolchain_root}" \
    "${source_cache}" \
    "${android_sdk_root}" \
    "${gradle_user_home}"

install_gradle
install_android_sdk

media3_source="${source_root}/androidx-media"
ffmpeg_source="${source_root}/ffmpeg"
clone_cached_project "androidx-media" "${media3_ref}" "${media3_commit}" "${media3_source_url}" "" "${media3_source}"
clone_cached_project "ffmpeg" "${ffmpeg_ref}" "${ffmpeg_commit}" "${ffmpeg_source_url}" "${ffmpeg_fallback_url}" "${ffmpeg_source}"

prepare_project "${media3_source}" "${ffmpeg_source}"
build_ffmpeg_static_libs
run_graph_smoke
build_aar

copy_if_exists "${media3_source}/LICENSE" "${artifact_root}/licenses/media3-LICENSE"
copy_if_exists "${ffmpeg_source}/COPYING.LGPLv2.1" "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv2.1"
copy_if_exists "${ffmpeg_source}/COPYING.LGPLv3" "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv3"
copy_if_exists "${ffmpeg_source}/LICENSE.md" "${artifact_root}/licenses/ffmpeg-LICENSE.md"

archive_source_tree "androidx-media-decoder-ffmpeg-${media3_commit}" "${media3_source}/libraries/decoder_ffmpeg"
archive_source_tree "ffmpeg-release-6.0-${ffmpeg_commit}" "${ffmpeg_source}"

write_enabled_decoders
write_enabled_filters
write_sbom
write_manifests
write_sha256sums
normalize_artifact_permissions

"${verify_script}" "${artifact_root}"

echo "Media3 FFmpeg decoder artifact created: ${artifact_root}"
