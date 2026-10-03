#!/usr/bin/env bash
set -euo pipefail
umask 022

# Host-mounted source caches are owned by the runner user,
# while this container typically runs as root. Modern git refuses operations on
# repos whose directory owner differs from the current user unless marked safe.
# Cover bind-mounted caches, work trees, and nested submodule checkouts.
git config --global --add safe.directory '*'

runtime_id="octans-player-runtime-lgpl-android-arm64"
runtime_version="${OCTANS_RUNTIME_VERSION:-0.0.0-local}"
output_root="${OCTANS_RUNTIME_OUTPUT:-/dist}"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-/cache/sources}"
work_root="${OCTANS_RUNTIME_WORK_ROOT:-/tmp/octans-player-runtime-android-build}"
verify_script="${OCTANS_RUNTIME_VERIFY_SCRIPT:-/workspace/scripts/verify-android-runtime-artifact.sh}"
component_manifest="${OCTANS_RUNTIME_MANIFEST:-/workspace/build-manifests/android-arm64-lgpl-components.json}"

android_ndk_version="29.0.14206865"
android_ndk_ref="r29"
android_ndk_sha1="87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b"
android_api="26"
android_abi="arm64-v8a"
android_arch="aarch64"
android_host="aarch64-linux-android"
android_cpu="armv8-a"

ffmpeg_version="9.0.2"
ffmpeg_sha256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
mpv_commit="413ff0b1cd4585294803308a1a14be2fad30cede"
mpv_version="v0.41.0-g${mpv_commit:0:8}"
mpv_sha256="dfdb212608e0ef75f42e0867178cf29350fc25b02ace20227e546bd060d37a70"
libplacebo_commit="92b5ac6db79f4d680eb656692f7bf51e9606f42a"
libplacebo_ref="${libplacebo_commit}"
libass_ref="0.17.4"
libass_commit="bbb3c7f1570a4a021e52683f3fbdf74fe492ae84"
freetype2_version="2.14.3"
freetype2_sha256="36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f"
fribidi_version="1.0.16"
fribidi_sha256="1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c"
harfbuzz_version="13.0.1"
harfbuzz_sha256="3553d943401c34ab9b8c75f35cdb8452ca660233b0e9d4a22395ce5245484bd7"
libpng_version="1.6.58"
libpng_sha256="a9d4df463d36a6e5f9c29bd6f4967312d17e996c1854f3511f833924eb1993cf"
zlib_version="1.3.2"
zlib_sha256="d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3"
dav1d_ref="1.5.3"
dav1d_commit="b546257f770768b2c88258c533da38b91a06f737"
zimg_ref="release-3.0.6"
zimg_version="3.0.6"
zimg_commit="f819b14e8f39d1282400b0d9543e8ef73c1b2bbd"
lcms2_ref="lcms2.19.1"
lcms2_version="2.19.1"
lcms2_commit="21c582a594fe5279f90c0b93437c398f93bf62b0"
mbedtls_version="3.6.6"
mbedtls_sha256="8fb65fae8dcae5840f793c0a334860a411f884cc537ea290ce1c52bb64ca007a"
libxml2_version="2.15.3"
libxml2_md5="b7b0123654f86ebf630a5cbedaafdece"
fontconfig_version="2.17.1"
fontconfig_md5="f68f95052c7297b98eccb7709d817f6a"
libunibreak_ref="libunibreak_7_0"
libunibreak_version="7.0"
libunibreak_commit="3ce4bfa3129ff3738046a44a6db533d2ce25af2b"

libplacebo_source_url="https://github.com/haasn/libplacebo.git"
libplacebo_fallback_url="https://code.videolan.org/videolan/libplacebo.git"
libass_source_url="https://github.com/libass/libass.git"
dav1d_source_url="https://code.videolan.org/videolan/dav1d.git"
zimg_source_url="https://github.com/sekrit-twc/zimg.git"
lcms2_source_url="https://github.com/mm2/Little-CMS.git"
libunibreak_source_url="https://github.com/adah1972/libunibreak.git"

deps_prefix="${work_root}/deps"
artifact_root="${output_root}/${runtime_id}"
source_root="${work_root}/sources"
build_root="${work_root}/build"
toolchain_root="${work_root}/toolchains"

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

download_with_fallback() {
    local primary_url="$1"
    local fallback_url="$2"
    local output="$3"

    if [[ -f "${output}" ]]; then
        return
    fi

    if ! curl \
        -fL \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 20 \
        --continue-at - \
        "${primary_url}" \
        -o "${output}.part"; then
        rm -f "${output}.part"
        if [[ -z "${fallback_url}" ]]; then
            return 1
        fi
        curl \
            -fL \
            --retry 5 \
            --retry-delay 2 \
            --connect-timeout 20 \
            --continue-at - \
            "${fallback_url}" \
            -o "${output}.part"
    fi

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

verify_md5() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(md5sum "${path}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "MD5 mismatch for ${path}: expected ${expected}, got ${actual}" >&2
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
    local recurse="${4:-0}"

    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
        rm -rf "${destination}"
        mkdir -p "${destination}"
        git -C "${destination}" init
        git -C "${destination}" remote add origin "${url}"
        git -C "${destination}" fetch --depth 1 origin "${ref}"
        git -C "${destination}" checkout --detach FETCH_HEAD
        if [[ "${recurse}" == "1" ]]; then
            git -C "${destination}" submodule update --init --recursive --depth 1
        fi
        return
    fi

    local args=(
        --depth 1
        --branch "${ref}"
        "${url}"
        "${destination}"
    )

    if [[ "${recurse}" == "1" ]]; then
        git clone --recurse-submodules --shallow-submodules "${args[@]}"
    else
        git clone "${args[@]}"
    fi
}

clone_cached_project() {
    local name="$1"
    local ref="$2"
    local expected_commit="$3"
    local primary_url="$4"
    local fallback_url="$5"
    local destination="$6"
    local recurse="${7:-0}"

    local cache_dir="${source_cache}/${name}-${ref}"
    local temp_dir="${cache_dir}.tmp"

    if [[ ! -d "${cache_dir}/.git" ]]; then
        rm -rf "${temp_dir}"
        if ! retry "Clone ${name} from primary source" \
            git_clone_once "${primary_url}" "${ref}" "${temp_dir}" "${recurse}"; then
            rm -rf "${temp_dir}"
            if [[ -z "${fallback_url}" ]]; then
                return 1
            fi
            retry "Clone ${name} from fallback source" \
                git_clone_once "${fallback_url}" "${ref}" "${temp_dir}" "${recurse}"
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

extract_tarball() {
    local tarball="$1"
    local destination="$2"

    rm -rf "${destination}"
    mkdir -p "${destination}"
    tar -xf "${tarball}" -C "${destination}" --strip-components=1
}

write_cross_file() {
    local path="$1"

    cat >"${path}" <<EOF
[binaries]
c = '${cc_bin}'
cpp = '${cxx_bin}'
ar = '${ar_bin}'
strip = '${strip_bin}'
nm = '${nm_bin}'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '${deps_prefix}/lib/pkgconfig:${deps_prefix}/share/pkgconfig'

[built-in options]
c_args = ['-fPIC']
cpp_args = ['-fPIC']
c_link_args = ['-Wl,-z,relro', '-Wl,-z,now']
cpp_link_args = ['-Wl,-z,relro', '-Wl,-z,now']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
EOF
}

copy_if_exists() {
    local source="$1"
    local destination="$2"

    if [[ -f "${source}" ]]; then
        cp "${source}" "${destination}"
    fi
}

copy_first_existing_license() {
    local destination="$1"
    shift

    local candidate
    for candidate in "$@"; do
        if [[ -f "${candidate}" ]]; then
            cp "${candidate}" "${destination}"
            return
        fi
    done
}

normalize_artifact_permissions() {
    find "${artifact_root}" -type d -exec chmod 0755 {} +
    find "${artifact_root}" -type f -exec chmod 0644 {} +
}

copy_shared_objects_from_dir() {
    local source_dir="$1"
    local destination_dir="$2"

    if [[ ! -d "${source_dir}" ]]; then
        return
    fi

    while IFS= read -r -d '' so_path; do
        cp -a "${so_path}" "${destination_dir}/"
    done < <(find "${source_dir}" -maxdepth 1 \( -type f -o -type l \) -name 'lib*.so*' -print0)
}

copy_android_cxx_shared() {
    local source_path
    source_path="$(find "${android_ndk_home}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/${android_host}" -name 'libc++_shared.so' -print | head -n 1)"

    if [[ ! -f "${source_path}" ]]; then
        echo "Required Android libc++_shared.so not found" >&2
        exit 1
    fi

    cp -f "${source_path}" "${artifact_root}/jniLibs/${android_abi}/"
}

archive_source_tree() {
    local archive_name="$1"
    local source_dir="$2"

    if [[ -d "${source_dir}" ]]; then
        tar -C "$(dirname "${source_dir}")" \
            --exclude="$(basename "${source_dir}")/.git" \
            -czf "${artifact_root}/sources/${archive_name}.tar.gz" \
            "$(basename "${source_dir}")"
    fi
}

record_command() {
    local output_file="$1"
    shift

    printf '%q ' "$@" >"${output_file}"
    printf '\n' >>"${output_file}"
}

meson_setup_compile_install() {
    local name="$1"
    local source_dir="$2"
    shift 2

    local build_dir="${build_root}/${name}"
    record_command \
        "${artifact_root}/build/dependency-build-options/${name}.txt" \
        meson setup "${build_dir}" "${source_dir}" "$@"

    meson setup "${build_dir}" "${source_dir}" "$@"
    meson compile -C "${build_dir}"
    meson install -C "${build_dir}"
}

cmake_configure_build_install() {
    local name="$1"
    local source_dir="$2"
    shift 2

    local build_dir="${build_root}/${name}"
    record_command \
        "${artifact_root}/build/dependency-build-options/${name}.txt" \
        cmake -S "${source_dir}" -B "${build_dir}" "$@"

    cmake -S "${source_dir}" -B "${build_dir}" "$@"
    cmake --build "${build_dir}" --parallel "$(nproc)"
    cmake --install "${build_dir}"
}

configure_make_install() {
    local name="$1"
    local source_dir="$2"
    shift 2

    record_command \
        "${artifact_root}/build/dependency-build-options/${name}.txt" \
        "$@"

    (
        cd "${source_dir}"
        "$@"
        make -j"$(nproc)"
        make install
    )
}

require_command curl
require_command git
require_command make
require_command cmake
require_command meson
require_command ninja
require_command pkg-config
require_command python3
require_command jq
require_command unzip
require_command sha1sum
require_command sha256sum
require_command md5sum

if [[ ! -x "${verify_script}" ]]; then
    echo "Android runtime verification script is not executable: ${verify_script}" >&2
    exit 1
fi

if [[ ! -f "${component_manifest}" ]]; then
    echo "Android component manifest not found: ${component_manifest}" >&2
    exit 1
fi

rm -rf "${work_root}" "${artifact_root}"
mkdir -p \
    "${source_cache}" \
    "${source_root}" \
    "${build_root}" \
    "${deps_prefix}" \
    "${toolchain_root}" \
    "${artifact_root}/jniLibs/${android_abi}" \
    "${artifact_root}/assets/mpv" \
    "${artifact_root}/licenses" \
    "${artifact_root}/sources" \
    "${artifact_root}/build/dependency-build-options"

android_ndk_home="${OCTANS_ANDROID_NDK_HOME:-${ANDROID_NDK_HOME:-}}"
if [[ -n "${android_ndk_home}" ]]; then
    if [[ ! -d "${android_ndk_home}" ]]; then
        echo "Configured Android NDK path does not exist: ${android_ndk_home}" >&2
        exit 1
    fi
else
    android_ndk_zip="${source_cache}/android-ndk-${android_ndk_ref}-linux.zip"
    download "https://dl.google.com/android/repository/android-ndk-${android_ndk_ref}-linux.zip" "${android_ndk_zip}"
    verify_sha1 "${android_ndk_sha1}" "${android_ndk_zip}"
    unzip -q "${android_ndk_zip}" -d "${toolchain_root}"
    android_ndk_home="${toolchain_root}/android-ndk-${android_ndk_ref}"
fi
android_sysroot="${android_ndk_home}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
toolchain_bin="${android_ndk_home}/toolchains/llvm/prebuilt/linux-x86_64/bin"
cc_bin="${toolchain_bin}/${android_host}${android_api}-clang"
cxx_bin="${toolchain_bin}/${android_host}${android_api}-clang++"
ar_bin="${toolchain_bin}/llvm-ar"
ranlib_bin="${toolchain_bin}/llvm-ranlib"
strip_bin="${toolchain_bin}/llvm-strip"
nm_bin="${toolchain_bin}/llvm-nm"
compiler_rt_builtins="$(
    find "${android_ndk_home}/toolchains/llvm/prebuilt/linux-x86_64/lib/clang" \
        -path '*/lib/linux/libclang_rt.builtins-aarch64-android.a' \
        -print \
        | sort -V \
        | tail -n 1
)"

require_command "${cc_bin}"
require_command "${cxx_bin}"
require_command "${ar_bin}"
require_command "${ranlib_bin}"
require_command "${strip_bin}"
require_command "${nm_bin}"

if [[ ! -f "${compiler_rt_builtins}" ]]; then
    echo "Android compiler-rt builtins archive not found" >&2
    exit 1
fi

export PATH="${toolchain_bin}:${PATH}"
export CC="${cc_bin}"
export CXX="${cxx_bin}"
export AR="${ar_bin}"
export RANLIB="${ranlib_bin}"
export STRIP="${strip_bin}"
export NM="${nm_bin}"
export PKG_CONFIG_LIBDIR="${deps_prefix}/lib/pkgconfig:${deps_prefix}/share/pkgconfig"
export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"
export PKG_CONFIG_SYSROOT_DIR=
export CPPFLAGS="-I${deps_prefix}/include"
export CFLAGS="-I${deps_prefix}/include -fPIC"
export CXXFLAGS="-I${deps_prefix}/include -fPIC"
export LDFLAGS="-L${deps_prefix}/lib"

cross_file="${build_root}/android-aarch64.ini"
write_cross_file "${cross_file}"
cp "${cross_file}" "${artifact_root}/build/android-aarch64.ini"
cp "${component_manifest}" "${artifact_root}/build/android-arm64-lgpl-components.json"

cmake_android_common=(
    -DCMAKE_TOOLCHAIN_FILE="${android_ndk_home}/build/cmake/android.toolchain.cmake"
    -DANDROID_ABI="${android_abi}"
    -DANDROID_PLATFORM="android-${android_api}"
    -DANDROID_STL=c++_shared
    -DCMAKE_INSTALL_PREFIX="${deps_prefix}"
    -DCMAKE_BUILD_TYPE=Release
)

ffmpeg_tarball="${source_cache}/ffmpeg-${ffmpeg_version}.tar.xz"
mpv_tarball="${source_cache}/mpv-${mpv_commit}.tar.gz"
zlib_tarball="${source_cache}/zlib-${zlib_version}.tar.xz"
libpng_tarball="${source_cache}/libpng-${libpng_version}.tar.gz"
freetype_tarball="${source_cache}/freetype-${freetype2_version}.tar.xz"
fribidi_tarball="${source_cache}/fribidi-${fribidi_version}.tar.xz"
harfbuzz_tarball="${source_cache}/harfbuzz-${harfbuzz_version}.tar.xz"
mbedtls_tarball="${source_cache}/mbedtls-${mbedtls_version}.tar.bz2"
libxml2_tarball="${source_cache}/libxml2-${libxml2_version}.tar.xz"
fontconfig_tarball="${source_cache}/fontconfig-${fontconfig_version}.tar.xz"

download "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz" "${ffmpeg_tarball}"
download "https://github.com/mpv-player/mpv/archive/${mpv_commit}.tar.gz" "${mpv_tarball}"
download "https://zlib.net/zlib-${zlib_version}.tar.xz" "${zlib_tarball}"
download "https://github.com/pnggroup/libpng/archive/v${libpng_version}.tar.gz" "${libpng_tarball}"
download "https://download.savannah.gnu.org/releases/freetype/freetype-${freetype2_version}.tar.xz" "${freetype_tarball}"
download "https://github.com/fribidi/fribidi/releases/download/v${fribidi_version}/fribidi-${fribidi_version}.tar.xz" "${fribidi_tarball}"
download "https://github.com/harfbuzz/harfbuzz/releases/download/${harfbuzz_version}/harfbuzz-${harfbuzz_version}.tar.xz" "${harfbuzz_tarball}"
download "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${mbedtls_version}/mbedtls-${mbedtls_version}.tar.bz2" "${mbedtls_tarball}"
download_with_fallback \
    "https://download.gnome.org/sources/libxml2/2.15/libxml2-${libxml2_version}.tar.xz" \
    "https://mirrors.slackware.com/slackware/slackware64-current/source/l/libxml2/libxml2-${libxml2_version}.tar.xz" \
    "${libxml2_tarball}"
download_with_fallback \
    "https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/${fontconfig_version}/fontconfig-${fontconfig_version}.tar.xz" \
    "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${fontconfig_version}.tar.xz" \
    "${fontconfig_tarball}"

verify_sha256 "${ffmpeg_sha256}" "${ffmpeg_tarball}"
verify_sha256 "${mpv_sha256}" "${mpv_tarball}"
verify_sha256 "${zlib_sha256}" "${zlib_tarball}"
verify_sha256 "${libpng_sha256}" "${libpng_tarball}"
verify_sha256 "${freetype2_sha256}" "${freetype_tarball}"
verify_sha256 "${fribidi_sha256}" "${fribidi_tarball}"
verify_sha256 "${harfbuzz_sha256}" "${harfbuzz_tarball}"
verify_sha256 "${mbedtls_sha256}" "${mbedtls_tarball}"
verify_md5 "${libxml2_md5}" "${libxml2_tarball}"
verify_md5 "${fontconfig_md5}" "${fontconfig_tarball}"

cp "${ffmpeg_tarball}" "${artifact_root}/sources/"
cp "${mpv_tarball}" "${artifact_root}/sources/"
cp "${zlib_tarball}" "${artifact_root}/sources/"
cp "${libpng_tarball}" "${artifact_root}/sources/"
cp "${freetype_tarball}" "${artifact_root}/sources/"
cp "${fribidi_tarball}" "${artifact_root}/sources/"
cp "${harfbuzz_tarball}" "${artifact_root}/sources/"
cp "${mbedtls_tarball}" "${artifact_root}/sources/"
cp "${libxml2_tarball}" "${artifact_root}/sources/"
cp "${fontconfig_tarball}" "${artifact_root}/sources/"

ffmpeg_source="${source_root}/ffmpeg-${ffmpeg_version}"
mpv_source="${source_root}/mpv-${mpv_commit}"
zlib_source="${source_root}/zlib-${zlib_version}"
libpng_source="${source_root}/libpng-${libpng_version}"
freetype_source="${source_root}/freetype-${freetype2_version}"
fribidi_source="${source_root}/fribidi-${fribidi_version}"
harfbuzz_source="${source_root}/harfbuzz-${harfbuzz_version}"
mbedtls_source="${source_root}/mbedtls-${mbedtls_version}"
libxml2_source="${source_root}/libxml2-${libxml2_version}"
fontconfig_source="${source_root}/fontconfig-${fontconfig_version}"

extract_tarball "${ffmpeg_tarball}" "${ffmpeg_source}"
extract_tarball "${mpv_tarball}" "${mpv_source}"
if [[ ! -f "${mpv_source}/demux/dovi_split.c" || ! -f "${mpv_source}/filters/f_enhancement_pair.c" ]]; then
    echo "mpv ${mpv_commit} is missing the Profile 7 FEL sources" >&2
    exit 1
fi
# The GitHub archive has no .git, so mpv's vcs_tag falls back to
# v${MPV_VERSION}. Drop UNKNOWN so that fallback is v0.41.0-g<commit>.
printf '%s\n' "${mpv_version#v}" >"${mpv_source}/MPV_VERSION"
extract_tarball "${zlib_tarball}" "${zlib_source}"
extract_tarball "${libpng_tarball}" "${libpng_source}"
extract_tarball "${freetype_tarball}" "${freetype_source}"
extract_tarball "${fribidi_tarball}" "${fribidi_source}"
extract_tarball "${harfbuzz_tarball}" "${harfbuzz_source}"
extract_tarball "${mbedtls_tarball}" "${mbedtls_source}"
extract_tarball "${libxml2_tarball}" "${libxml2_source}"
extract_tarball "${fontconfig_tarball}" "${fontconfig_source}"

libplacebo_source="${source_root}/libplacebo-${libplacebo_ref}"
libass_source="${source_root}/libass-${libass_ref}"
dav1d_source="${source_root}/dav1d-${dav1d_ref}"
zimg_source="${source_root}/zimg-${zimg_ref}"
lcms2_source="${source_root}/lcms2-${lcms2_ref}"
libunibreak_source="${source_root}/libunibreak-${libunibreak_ref}"

clone_cached_project \
    libplacebo \
    "${libplacebo_ref}" \
    "${libplacebo_commit}" \
    "${libplacebo_source_url}" \
    "${libplacebo_fallback_url}" \
    "${libplacebo_source}" \
    1
if ! grep -q "enhancement_layer" "${libplacebo_source}/src/include/libplacebo/renderer.h"; then
    echo "libplacebo ${libplacebo_commit} has no pl_frame.enhancement_layer" >&2
    exit 1
fi
clone_cached_project \
    libass \
    "${libass_ref}" \
    "${libass_commit}" \
    "${libass_source_url}" \
    "" \
    "${libass_source}" \
    0
clone_cached_project \
    dav1d \
    "${dav1d_ref}" \
    "${dav1d_commit}" \
    "${dav1d_source_url}" \
    "" \
    "${dav1d_source}" \
    0
clone_cached_project \
    zimg \
    "${zimg_ref}" \
    "${zimg_commit}" \
    "${zimg_source_url}" \
    "" \
    "${zimg_source}" \
    0
clone_cached_project \
    lcms2 \
    "${lcms2_ref}" \
    "${lcms2_commit}" \
    "${lcms2_source_url}" \
    "" \
    "${lcms2_source}" \
    0
clone_cached_project \
    libunibreak \
    "${libunibreak_ref}" \
    "${libunibreak_commit}" \
    "${libunibreak_source_url}" \
    "" \
    "${libunibreak_source}" \
    0

archive_source_tree "libplacebo-${libplacebo_ref}" "${libplacebo_source}"
archive_source_tree "libass-${libass_ref}" "${libass_source}"
archive_source_tree "dav1d-${dav1d_ref}" "${dav1d_source}"
archive_source_tree "zimg-${zimg_ref}" "${zimg_source}"
archive_source_tree "lcms2-${lcms2_ref}" "${lcms2_source}"
archive_source_tree "libunibreak-${libunibreak_ref}" "${libunibreak_source}"

cmake_configure_build_install \
    zlib \
    "${zlib_source}" \
    "${cmake_android_common[@]}" \
    -DBUILD_SHARED_LIBS=ON \
    -DZLIB_BUILD_EXAMPLES=OFF \
    -DZLIB_BUILD_TESTING=OFF
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

cmake_configure_build_install \
    libpng \
    "${libpng_source}" \
    "${cmake_android_common[@]}" \
    -DPNG_SHARED=ON \
    -DPNG_STATIC=OFF \
    -DPNG_TESTS=OFF
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    freetype2 \
    "${freetype_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dzlib=enabled \
    -Dpng=enabled \
    -Dbzip2=disabled \
    -Dbrotli=disabled \
    -Dharfbuzz=disabled \
    -Dtests=disabled
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    fribidi \
    "${fribidi_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Ddocs=false \
    -Dtests=false \
    -Dbin=false
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    harfbuzz \
    "${harfbuzz_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dchafa=disabled \
    -Dicu=disabled \
    -Dfreetype=enabled \
    -Dtests=disabled \
    -Ddocs=disabled \
    -Dutilities=disabled
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

cmake_configure_build_install \
    mbedtls \
    "${mbedtls_source}" \
    "${cmake_android_common[@]}" \
    -DUSE_SHARED_MBEDTLS_LIBRARY=ON \
    -DUSE_STATIC_MBEDTLS_LIBRARY=OFF \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

configure_make_install \
    libxml2 \
    "${libxml2_source}" \
    env \
    CC="${CC}" \
    CXX="${CXX}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    STRIP="${STRIP}" \
    CFLAGS="${CFLAGS}" \
    CPPFLAGS="${CPPFLAGS}" \
    LDFLAGS="${LDFLAGS}" \
    ./configure \
    --host="${android_host}" \
    --prefix="${deps_prefix}" \
    --enable-shared \
    --disable-static \
    --without-python \
    --without-lzma \
    --with-zlib="${deps_prefix}" \
    --without-iconv \
    --without-icu
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    fontconfig \
    "${fontconfig_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Ddoc=disabled \
    -Dtests=disabled \
    -Dtools=disabled \
    -Dcache-build=disabled \
    -Diconv=disabled \
    -Dnls=disabled \
    -Dxml-backend=libxml2
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

record_command \
    "${artifact_root}/build/dependency-build-options/libunibreak-autogen.txt" \
    env \
    NOCONFIGURE=1 \
    ./autogen.sh
(
    cd "${libunibreak_source}"
    env NOCONFIGURE=1 ./autogen.sh
    make distclean >/dev/null 2>&1 || true
)
configure_make_install \
    libunibreak \
    "${libunibreak_source}" \
    env \
    CC="${CC}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    STRIP="${STRIP}" \
    CFLAGS="${CFLAGS}" \
    CPPFLAGS="${CPPFLAGS}" \
    LDFLAGS="${LDFLAGS}" \
    ./configure \
    --host="${android_host}" \
    --prefix="${deps_prefix}" \
    --enable-shared \
    --disable-static
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    libass \
    "${libass_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dfontconfig=enabled \
    -Ddirectwrite=disabled \
    -Dcoretext=disabled \
    -Dlibunibreak=enabled \
    -Drequire-system-font-provider=true \
    -Dtest=disabled \
    -Dcompare=disabled \
    -Dprofile=disabled \
    -Dfuzz=disabled \
    -Dcheckasm=disabled
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

record_command \
    "${artifact_root}/build/dependency-build-options/zimg-autogen.txt" \
    env \
    CC="${CC}" \
    CXX="${CXX}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    ./autogen.sh
(
    cd "${zimg_source}"
    env \
        CC="${CC}" \
        CXX="${CXX}" \
        AR="${AR}" \
        RANLIB="${RANLIB}" \
        ./autogen.sh
    make distclean >/dev/null 2>&1 || true
)
configure_make_install \
    zimg \
    "${zimg_source}" \
    env \
    CC="${CC}" \
    CXX="${CXX}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    STRIP="${STRIP}" \
    CFLAGS="${CFLAGS}" \
    CXXFLAGS="${CXXFLAGS}" \
    CPPFLAGS="${CPPFLAGS}" \
    LDFLAGS="${LDFLAGS}" \
    LIBS="${compiler_rt_builtins}" \
    ./configure \
    --host="${android_host}" \
    --prefix="${deps_prefix}" \
    --enable-shared \
    --disable-static
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    lcms2 \
    "${lcms2_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dtests=disabled \
    -Djpeg=disabled \
    -Dtiff=disabled \
    -Dutils=false \
    -Dfastfloat=false \
    -Dthreaded=false
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    dav1d \
    "${dav1d_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Denable_tools=false \
    -Denable_tests=false
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

meson_setup_compile_install \
    libplacebo \
    "${libplacebo_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Ddemos=false \
    -Dtests=false \
    -Dvulkan=disabled \
    -Dopengl=enabled \
    -Dgl-proc-addr=enabled \
    -Dshaderc=disabled \
    -Dglslang=disabled \
    -Dlcms=enabled \
    -Ddovi=enabled \
    -Dlibdovi=disabled
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

ffmpeg_configure_flags=(
    "--prefix=${deps_prefix}"
    "--arch=${android_arch}"
    "--cpu=${android_cpu}"
    "--target-os=android"
    "--cc=${CC}"
    "--cxx=${CXX}"
    "--ar=${AR}"
    "--ranlib=${RANLIB}"
    "--strip=${STRIP}"
    "--nm=${NM}"
    "--enable-cross-compile"
    "--pkg-config=pkg-config"
    "--enable-shared"
    "--disable-static"
    "--disable-programs"
    "--disable-doc"
    "--disable-debug"
    "--disable-avdevice"
    "--disable-gpl"
    "--disable-nonfree"
    "--enable-version3"
    "--disable-openssl"
    "--enable-jni"
    "--enable-mediacodec"
    "--enable-mbedtls"
    "--enable-libdav1d"
    "--enable-libass"
    "--enable-libfreetype"
    "--enable-libfribidi"
    "--enable-libharfbuzz"
    "--enable-libzimg"
    "--enable-lcms2"
    "--enable-zlib"
    "--disable-bzlib"
    "--disable-lzma"
    "--disable-vulkan"
    "--extra-cflags=-I${deps_prefix}/include -fPIC"
    "--extra-ldflags=-L${deps_prefix}/lib -landroid -llog"
)

record_command "${artifact_root}/build/ffmpeg-configure.txt" ./configure "${ffmpeg_configure_flags[@]}"

(
    cd "${ffmpeg_source}"
    ./configure "${ffmpeg_configure_flags[@]}"
    make -j"$(nproc)"
    make install
)
copy_shared_objects_from_dir "${deps_prefix}/lib" "${artifact_root}/jniLibs/${android_abi}"

mpv_meson_setup=(
    meson setup "${build_root}/mpv" "${mpv_source}"
    --cross-file "${cross_file}"
    --prefix "${build_root}/mpv-install"
    --buildtype release
    --default-library shared
    --wrap-mode nodownload
    -Dgpl=false
    -Dcplayer=false
    -Dlibmpv=true
    -Dlibavdevice=disabled
    -Dlua=disabled
    -Djavascript=disabled
    -Daudiotrack=enabled
    -Daaudio=enabled
    -Dopensles=enabled
    -Degl-android=enabled
    -Dandroid-media-ndk=enabled
    -Dgl=enabled
    -Dplain-gl=enabled
    -Dvulkan=disabled
    -Dshaderc=disabled
    -Dspirv-cross=disabled
    -Dlcms2=enabled
    -Dlibarchive=disabled
    -Duchardet=disabled
    -Dzimg=enabled
    -Drubberband=disabled
    -Diconv=disabled
    -Dmanpage-build=disabled
    -Dhtml-build=disabled
    -Dpdf-build=disabled
)

record_command "${artifact_root}/build/mpv-meson-setup.txt" "${mpv_meson_setup[@]}"
"${mpv_meson_setup[@]}"
meson configure "${build_root}/mpv" >"${artifact_root}/build/mpv-meson-options.txt"
meson compile -C "${build_root}/mpv"
meson install -C "${build_root}/mpv"

copy_shared_objects_from_dir "${build_root}/mpv-install/lib" "${artifact_root}/jniLibs/${android_abi}"
copy_shared_objects_from_dir "${build_root}/mpv-install/bin" "${artifact_root}/jniLibs/${android_abi}"
if [[ ! -f "${artifact_root}/jniLibs/${android_abi}/libmpv.so" ]]; then
    mpv_so="$(find "${build_root}/mpv-install" "${build_root}/mpv" -type f -name 'libmpv.so*' | sort | head -n 1)"
    if [[ -z "${mpv_so}" ]]; then
        echo "libmpv.so was not produced" >&2
        exit 1
    fi
    cp -a "${mpv_so}" "${artifact_root}/jniLibs/${android_abi}/libmpv.so"
fi
copy_android_cxx_shared

cat >"${artifact_root}/assets/mpv/mpv.conf" <<'EOF'
# Octans Android libmpv baseline.
# DV P5 color fix is an app-selected profile and must set hwdec=no explicitly.
vo=gpu-next
gpu-context=android
profile=fast
EOF

cat >"${artifact_root}/assets/mpv/input.conf" <<'EOF'
# Intentionally empty for the runtime artifact baseline.
EOF

cat >"${artifact_root}/assets/mpv/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/system/fonts</dir>
  <dir>/system/font</dir>
  <dir>/data/fonts</dir>
  <dir prefix="xdg">fonts</dir>
</fontconfig>
EOF

copy_if_exists "${ffmpeg_source}/COPYING.LGPLv2.1" "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv2.1"
copy_if_exists "${ffmpeg_source}/COPYING.LGPLv3" "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv3"
copy_if_exists "${ffmpeg_source}/LICENSE.md" "${artifact_root}/licenses/ffmpeg-LICENSE.md"
copy_if_exists "${mpv_source}/LICENSE.LGPL" "${artifact_root}/licenses/mpv-LICENSE.LGPL"
copy_if_exists "${libplacebo_source}/LICENSE" "${artifact_root}/licenses/libplacebo-LICENSE"
copy_if_exists "${libass_source}/COPYING" "${artifact_root}/licenses/libass-COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/freetype2-FTL.TXT" \
    "${freetype_source}/docs/FTL.TXT" \
    "${freetype_source}/LICENSE.TXT"
copy_first_existing_license "${artifact_root}/licenses/fribidi-COPYING" "${fribidi_source}/COPYING"
copy_first_existing_license "${artifact_root}/licenses/harfbuzz-COPYING" "${harfbuzz_source}/COPYING"
copy_first_existing_license "${artifact_root}/licenses/libpng-LICENSE" "${libpng_source}/LICENSE"
copy_first_existing_license "${artifact_root}/licenses/zlib-LICENSE" "${zlib_source}/LICENSE"
copy_first_existing_license "${artifact_root}/licenses/dav1d-COPYING" "${dav1d_source}/COPYING"
copy_first_existing_license "${artifact_root}/licenses/zimg-COPYING" "${zimg_source}/COPYING"
copy_first_existing_license "${artifact_root}/licenses/lcms2-COPYING" "${lcms2_source}/COPYING"
copy_first_existing_license "${artifact_root}/licenses/mbedtls-LICENSE" "${mbedtls_source}/LICENSE"
copy_first_existing_license "${artifact_root}/licenses/libxml2-Copyright" "${libxml2_source}/Copyright"
copy_first_existing_license "${artifact_root}/licenses/fontconfig-COPYING" "${fontconfig_source}/COPYING"
copy_first_existing_license "${artifact_root}/licenses/libunibreak-LICENCE" "${libunibreak_source}/LICENCE"

jq \
    --arg version "${runtime_version}" \
    --arg ffmpegConfigure "build/ffmpeg-configure.txt" \
    --arg mpvMesonOptions "build/mpv-meson-options.txt" \
    '. + {
        version: $version,
        ffmpeg: {
          version: (.components[] | select(.name == "ffmpeg") | .version),
          configureFile: $ffmpegConfigure
        },
        mpv: {
          version: (.components[] | select(.name == "mpv") | .version),
          mesonOptionsFile: $mpvMesonOptions
        },
        sha256sums: "build/sha256sums.txt",
        sbom: "build/sbom.spdx.json"
      }' \
    "${component_manifest}" >"${artifact_root}/runtime-manifest.json"

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
  "packages": []
}
EOF

normalize_artifact_permissions

(
    cd "${artifact_root}"
    find . -type f ! -path './build/sha256sums.txt' -print0 \
        | sort -z \
        | xargs -0 sha256sum > build/sha256sums.txt
)

normalize_artifact_permissions

"${verify_script}" "${artifact_root}"

echo "Android runtime artifact created: ${artifact_root}"
