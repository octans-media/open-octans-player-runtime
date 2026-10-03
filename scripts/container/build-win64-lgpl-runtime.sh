#!/usr/bin/env bash
set -euo pipefail
umask 022

# Host-mounted source caches are owned by the runner user,
# while this container typically runs as root. Modern git refuses operations on
# repos whose directory owner differs from the current user unless marked safe.
# Cover bind-mounted caches, work trees, and nested submodule checkouts.
git config --global --add safe.directory '*'

runtime_id="octans-player-runtime-lgpl-win64"
runtime_version="${OCTANS_RUNTIME_VERSION:-0.0.0-local}"
output_root="${OCTANS_RUNTIME_OUTPUT:-/dist}"
source_cache="${OCTANS_RUNTIME_SOURCE_CACHE:-/cache/sources}"
work_root="${OCTANS_RUNTIME_WORK_ROOT:-/tmp/octans-player-runtime-build}"
verify_script="${OCTANS_RUNTIME_VERIFY_SCRIPT:-/workspace/scripts/verify-runtime-artifact.sh}"

ffmpeg_version="9.0.2"
ffmpeg_sha256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
mpv_commit="413ff0b1cd4585294803308a1a14be2fad30cede"
mpv_version="v0.41.0-g${mpv_commit:0:8}"
libplacebo_commit="92b5ac6db79f4d680eb656692f7bf51e9606f42a"
libplacebo_ref="${libplacebo_commit}"
libass_ref="0.17.4"
freetype2_version="2.14.3"
fribidi_version="1.0.16"
harfbuzz_version="13.0.1"
libpng_version="1.6.58"
zlib_version="1.3.2"
dav1d_ref="1.5.3"
zimg_ref="release-3.0.6"
zimg_version="3.0.6"
lcms2_ref="lcms2.19.1"
lcms2_version="2.19.1"
vulkan_headers_ref="v1.4.352"
vulkan_headers_version="1.4.352"
vulkan_loader_ref="v1.4.352"
vulkan_loader_version="1.4.352"
spirv_cross_ref="vulkan-sdk-1.4.350.0"
spirv_cross_version="1.4.350.0"
shaderc_ref="v2026.2"
shaderc_version="2026.2"
mingw_runtime_source_url="https://gcc.gnu.org/git/?p=gcc.git"

libplacebo_source_url="https://github.com/haasn/libplacebo.git"
libplacebo_fallback_url="https://code.videolan.org/videolan/libplacebo.git"
libass_source_url="https://github.com/libass/libass.git"
dav1d_source_url="https://code.videolan.org/videolan/dav1d.git"
zimg_source_url="https://github.com/sekrit-twc/zimg.git"
lcms2_source_url="https://github.com/mm2/Little-CMS.git"
vulkan_headers_source_url="https://github.com/KhronosGroup/Vulkan-Headers.git"
vulkan_loader_source_url="https://github.com/KhronosGroup/Vulkan-Loader.git"
spirv_cross_source_url="https://github.com/KhronosGroup/SPIRV-Cross.git"
shaderc_source_url="https://github.com/google/shaderc.git"

target="x86_64-w64-mingw32"
cross_prefix="${target}-"
deps_prefix="${work_root}/deps"
artifact_root="${output_root}/${runtime_id}"
source_root="${work_root}/sources"
build_root="${work_root}/build"

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
    curl -fL --retry 5 --retry-delay 2 "${url}" -o "${output}"
}

verify_sha256() {
    local expected="$1"
    local file="$2"
    local actual

    actual="$(sha256sum "${file}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "sha256 mismatch for ${file}" >&2
        echo "expected ${expected}" >&2
        echo "actual   ${actual}" >&2
        return 1
    fi
}

download_verified() {
    local url="$1"
    local output="$2"
    local expected="$3"

    if [[ -f "${output}" ]] && ! verify_sha256 "${expected}" "${output}"; then
        rm -f "${output}"
    fi
    download "${url}" "${output}"
    verify_sha256 "${expected}" "${output}"
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
    local primary_url="$3"
    local fallback_url="$4"
    local destination="$5"
    local recurse="${6:-0}"

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

    rm -rf "${destination}"
    cp -a "${cache_dir}" "${destination}"
}

git_clone_commit_once() {
    local url="$1"
    local commit="$2"
    local destination="$3"
    local recurse="${4:-0}"
    local actual

    if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Expected a 40-character commit, got: ${commit}" >&2
        return 1
    fi

    rm -rf "${destination}"
    mkdir -p "${destination}"
    git -C "${destination}" init
    git -C "${destination}" remote add origin "${url}"
    git -C "${destination}" fetch --depth 1 origin "${commit}"
    git -C "${destination}" checkout --detach FETCH_HEAD
    actual="$(git -C "${destination}" rev-parse HEAD)"
    if [[ "${actual}" != "${commit}" ]]; then
        echo "Checked out ${actual}, expected ${commit}" >&2
        return 1
    fi
    if [[ "${recurse}" == "1" ]]; then
        git -C "${destination}" submodule update --init --recursive --depth 1
    fi
}

clone_cached_commit() {
    local name="$1"
    local commit="$2"
    local primary_url="$3"
    local fallback_url="$4"
    local destination="$5"
    local recurse="${6:-0}"

    local cache_dir="${source_cache}/${name}-${commit}"
    local temp_dir="${cache_dir}.tmp"
    local actual

    if [[ ! -d "${cache_dir}/.git" ]]; then
        rm -rf "${temp_dir}"
        if ! retry "Clone ${name} commit from primary source" \
            git_clone_commit_once "${primary_url}" "${commit}" "${temp_dir}" "${recurse}"; then
            rm -rf "${temp_dir}"
            if [[ -z "${fallback_url}" ]]; then
                return 1
            fi
            retry "Clone ${name} commit from fallback source" \
                git_clone_commit_once "${fallback_url}" "${commit}" "${temp_dir}" "${recurse}"
        fi
        rm -rf "${cache_dir}"
        mv "${temp_dir}" "${cache_dir}"
    fi

    actual="$(git -C "${cache_dir}" rev-parse HEAD)"
    if [[ "${actual}" != "${commit}" ]]; then
        echo "Cached ${name} is ${actual}, expected ${commit}" >&2
        return 1
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
c = '${target}-gcc'
cpp = '${target}-g++'
ar = '${target}-ar'
strip = '${target}-strip'
windres = '${target}-windres'
dlltool = '${target}-dlltool'
pkg-config = 'pkg-config'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '${deps_prefix}/lib/pkgconfig:${deps_prefix}/share/pkgconfig'
c_link_args = ['-static-libgcc']
cpp_link_args = ['-static-libgcc', '-static-libstdc++']

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

write_cmake_toolchain_file() {
    local path="$1"

    cat >"${path}" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${target}-gcc)
set(CMAKE_CXX_COMPILER ${target}-g++)
set(CMAKE_RC_COMPILER ${target}-windres)
set(CMAKE_AR ${target}-ar)
set(CMAKE_RANLIB ${target}-ranlib)
set(CMAKE_FIND_ROOT_PATH ${deps_prefix})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")
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

copy_dlls_from_dir() {
    local source_dir="$1"
    local destination_dir="$2"

    if [[ -d "${source_dir}" ]] && compgen -G "${source_dir}/*.dll" >/dev/null; then
        cp -f "${source_dir}"/*.dll "${destination_dir}/"
    fi
}

copy_mingw_runtime_dll() {
    local dll_name="$1"
    local source_path
    source_path="$("${target}-g++" -print-file-name="${dll_name}")"

    if [[ ! -f "${source_path}" ]]; then
        echo "Required MinGW runtime DLL not found: ${dll_name}" >&2
        exit 1
    fi

    cp -f "${source_path}" "${artifact_root}/bin/"
}

copy_mingw_runtime_dlls() {
    copy_mingw_runtime_dll "libgcc_s_seh-1.dll"
    copy_mingw_runtime_dll "libstdc++-6.dll"
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

make_install() {
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
require_command "${target}-gcc"
require_command "${target}-g++"
require_command "${target}-dlltool"

mingw_runtime_version="$("${target}-g++" -dumpfullversion)"

if [[ ! -x "${verify_script}" ]]; then
    echo "Runtime verification script is not executable: ${verify_script}" >&2
    exit 1
fi

rm -rf "${work_root}" "${artifact_root}"
mkdir -p \
    "${source_cache}" \
    "${source_root}" \
    "${build_root}" \
    "${deps_prefix}" \
    "${artifact_root}/bin" \
    "${artifact_root}/licenses" \
    "${artifact_root}/sources" \
    "${artifact_root}/build/dependency-build-options"

tool_shim_dir="${build_root}/tool-shims"
mkdir -p "${tool_shim_dir}"
ln -sf "$(command -v "${target}-dlltool")" "${tool_shim_dir}/dlltool"
export PATH="${tool_shim_dir}:${PATH}"
export PKG_CONFIG_LIBDIR="${deps_prefix}/lib/pkgconfig:${deps_prefix}/share/pkgconfig"
export PKG_CONFIG_PATH="${PKG_CONFIG_LIBDIR}"
export PKG_CONFIG_SYSROOT_DIR=
export CPPFLAGS="-I${deps_prefix}/include"
export LDFLAGS="-L${deps_prefix}/lib -static-libgcc -static-libstdc++"

cross_file="${build_root}/cross-win64.ini"
cmake_toolchain_file="${build_root}/cmake-win64.cmake"
write_cross_file "${cross_file}"
write_cmake_toolchain_file "${cmake_toolchain_file}"

ffmpeg_tarball="${source_cache}/ffmpeg-${ffmpeg_version}.tar.xz"
mpv_tarball="${source_cache}/mpv-${mpv_commit}.tar.gz"
zlib_tarball="${source_cache}/zlib-${zlib_version}.tar.xz"
libpng_tarball="${source_cache}/libpng-${libpng_version}.tar.gz"
freetype_tarball="${source_cache}/freetype-${freetype2_version}.tar.xz"
fribidi_tarball="${source_cache}/fribidi-${fribidi_version}.tar.xz"
harfbuzz_tarball="${source_cache}/harfbuzz-${harfbuzz_version}.tar.xz"

download_verified "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz" "${ffmpeg_tarball}" "${ffmpeg_sha256}"
download "https://github.com/mpv-player/mpv/archive/${mpv_commit}.tar.gz" "${mpv_tarball}"
download "https://zlib.net/zlib-${zlib_version}.tar.xz" "${zlib_tarball}"
download "https://github.com/pnggroup/libpng/archive/v${libpng_version}.tar.gz" "${libpng_tarball}"
download "https://download.savannah.gnu.org/releases/freetype/freetype-${freetype2_version}.tar.xz" "${freetype_tarball}"
download "https://github.com/fribidi/fribidi/releases/download/v${fribidi_version}/fribidi-${fribidi_version}.tar.xz" "${fribidi_tarball}"
download "https://github.com/harfbuzz/harfbuzz/releases/download/${harfbuzz_version}/harfbuzz-${harfbuzz_version}.tar.xz" "${harfbuzz_tarball}"

cp "${ffmpeg_tarball}" "${artifact_root}/sources/"
cp "${mpv_tarball}" "${artifact_root}/sources/"
cp "${zlib_tarball}" "${artifact_root}/sources/"
cp "${libpng_tarball}" "${artifact_root}/sources/"
cp "${freetype_tarball}" "${artifact_root}/sources/"
cp "${fribidi_tarball}" "${artifact_root}/sources/"
cp "${harfbuzz_tarball}" "${artifact_root}/sources/"

ffmpeg_source="${source_root}/ffmpeg-${ffmpeg_version}"
mpv_source="${source_root}/mpv-${mpv_commit}"
zlib_source="${source_root}/zlib-${zlib_version}"
libpng_source="${source_root}/libpng-${libpng_version}"
freetype_source="${source_root}/freetype-${freetype2_version}"
fribidi_source="${source_root}/fribidi-${fribidi_version}"
harfbuzz_source="${source_root}/harfbuzz-${harfbuzz_version}"

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

libplacebo_source="${source_root}/libplacebo-${libplacebo_ref}"
libass_source="${source_root}/libass-${libass_ref}"
dav1d_source="${source_root}/dav1d-${dav1d_ref}"
zimg_source="${source_root}/zimg-${zimg_ref}"
lcms2_source="${source_root}/lcms2-${lcms2_ref}"
vulkan_headers_source="${source_root}/vulkan-headers-${vulkan_headers_ref}"
vulkan_loader_source="${source_root}/vulkan-loader-${vulkan_loader_ref}"
spirv_cross_source="${source_root}/spirv-cross-${spirv_cross_ref}"
shaderc_source="${source_root}/shaderc-${shaderc_ref}"

clone_cached_commit \
    libplacebo \
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
    "${libass_source_url}" \
    "" \
    "${libass_source}" \
    0
clone_cached_project \
    dav1d \
    "${dav1d_ref}" \
    "${dav1d_source_url}" \
    "" \
    "${dav1d_source}" \
    0
clone_cached_project \
    zimg \
    "${zimg_ref}" \
    "${zimg_source_url}" \
    "" \
    "${zimg_source}" \
    0
clone_cached_project \
    lcms2 \
    "${lcms2_ref}" \
    "${lcms2_source_url}" \
    "" \
    "${lcms2_source}" \
    0
clone_cached_project \
    vulkan-headers \
    "${vulkan_headers_ref}" \
    "${vulkan_headers_source_url}" \
    "" \
    "${vulkan_headers_source}" \
    0
clone_cached_project \
    vulkan-loader \
    "${vulkan_loader_ref}" \
    "${vulkan_loader_source_url}" \
    "" \
    "${vulkan_loader_source}" \
    0
clone_cached_project \
    spirv-cross \
    "${spirv_cross_ref}" \
    "${spirv_cross_source_url}" \
    "" \
    "${spirv_cross_source}" \
    0
clone_cached_project \
    shaderc \
    "${shaderc_ref}" \
    "${shaderc_source_url}" \
    "" \
    "${shaderc_source}" \
    0

(
    cd "${shaderc_source}"
    ./utils/git-sync-deps
)

archive_source_tree "libplacebo-${libplacebo_ref}" "${libplacebo_source}"
archive_source_tree "libass-${libass_ref}" "${libass_source}"
archive_source_tree "dav1d-${dav1d_ref}" "${dav1d_source}"
archive_source_tree "zimg-${zimg_ref}" "${zimg_source}"
archive_source_tree "lcms2-${lcms2_ref}" "${lcms2_source}"
archive_source_tree "vulkan-headers-${vulkan_headers_ref}" "${vulkan_headers_source}"
archive_source_tree "vulkan-loader-${vulkan_loader_ref}" "${vulkan_loader_source}"
archive_source_tree "spirv-cross-${spirv_cross_ref}" "${spirv_cross_source}"
archive_source_tree "shaderc-${shaderc_ref}" "${shaderc_source}"

make_install \
    zlib \
    "${zlib_source}" \
    env \
    CHOST="${target}" \
    CC="${target}-gcc" \
    AR="${target}-ar" \
    RANLIB="${target}-ranlib" \
    ./configure \
    --prefix="${deps_prefix}" \
    --shared
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

cmake_configure_build_install \
    libpng \
    "${libpng_source}" \
    -DCMAKE_TOOLCHAIN_FILE="${cmake_toolchain_file}" \
    -DCMAKE_INSTALL_PREFIX="${deps_prefix}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DPNG_SHARED=ON \
    -DPNG_STATIC=OFF \
    -DPNG_TESTS=OFF
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

meson_setup_compile_install \
    libass \
    "${libass_source}" \
    --cross-file "${cross_file}" \
    --prefix "${deps_prefix}" \
    --buildtype release \
    --default-library shared \
    --wrap-mode nodownload \
    -Dfontconfig=disabled \
    -Ddirectwrite=enabled \
    -Dtest=disabled \
    -Dcompare=disabled \
    -Dprofile=disabled \
    -Dfuzz=disabled \
    -Dcheckasm=disabled
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

record_command \
    "${artifact_root}/build/dependency-build-options/zimg-autogen.txt" \
    env \
    CC="${target}-gcc" \
    CXX="${target}-g++" \
    AR="${target}-ar" \
    RANLIB="${target}-ranlib" \
    ./autogen.sh
(
    cd "${zimg_source}"
    env \
        CC="${target}-gcc" \
        CXX="${target}-g++" \
        AR="${target}-ar" \
        RANLIB="${target}-ranlib" \
        ./autogen.sh
    make distclean >/dev/null 2>&1 || true
)
record_command \
    "${artifact_root}/build/dependency-build-options/zimg-configure.txt" \
    ./configure \
    --host="${target}" \
    --prefix="${deps_prefix}" \
    --enable-shared \
    --disable-static
(
    cd "${zimg_source}"
    ./configure \
        --host="${target}" \
        --prefix="${deps_prefix}" \
        --enable-shared \
        --disable-static
    make -j"$(nproc)"
    make install
)
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

cmake_configure_build_install \
    vulkan-headers \
    "${vulkan_headers_source}" \
    -DCMAKE_TOOLCHAIN_FILE="${cmake_toolchain_file}" \
    -DCMAKE_INSTALL_PREFIX="${deps_prefix}" \
    -DCMAKE_BUILD_TYPE=Release

cmake_configure_build_install \
    vulkan-loader \
    "${vulkan_loader_source}" \
    -DCMAKE_TOOLCHAIN_FILE="${cmake_toolchain_file}" \
    -DCMAKE_INSTALL_PREFIX="${deps_prefix}" \
    -DCMAKE_PREFIX_PATH="${deps_prefix}" \
    -DVULKAN_HEADERS_INSTALL_DIR="${deps_prefix}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTS=OFF \
    -DLOADER_CODEGEN=OFF \
    -DUSE_GAS=ON
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

cmake_configure_build_install \
    spirv-cross \
    "${spirv_cross_source}" \
    -DCMAKE_TOOLCHAIN_FILE="${cmake_toolchain_file}" \
    -DCMAKE_INSTALL_PREFIX="${deps_prefix}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DSPIRV_CROSS_SHARED=ON \
    -DSPIRV_CROSS_STATIC=OFF \
    -DSPIRV_CROSS_CLI=OFF \
    -DSPIRV_CROSS_ENABLE_TESTS=OFF
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

cmake_configure_build_install \
    shaderc \
    "${shaderc_source}" \
    -DCMAKE_TOOLCHAIN_FILE="${cmake_toolchain_file}" \
    -DCMAKE_INSTALL_PREFIX="${deps_prefix}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition -static-libgcc -static-libstdc++" \
    -DBUILD_SHARED_LIBS=ON \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSHADERC_ENABLE_WGSL_OUTPUT=OFF \
    -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV_TOOLS_BUILD_STATIC=OFF
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
    -Dvulkan=enabled \
    -Dvk-proc-addr=enabled \
    -Dd3d11=enabled \
    -Dshaderc=enabled \
    -Dglslang=disabled \
    -Dlcms=enabled \
    -Ddovi=enabled \
    -Dlibdovi=disabled \
    -Dopengl=disabled
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

ffmpeg_configure_flags=(
    "--prefix=${deps_prefix}"
    "--arch=x86_64"
    "--target-os=mingw32"
    "--cross-prefix=${cross_prefix}"
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
    "--disable-openssl"
    "--enable-schannel"
    "--enable-w32threads"
    "--enable-d3d11va"
    "--enable-dxva2"
    "--enable-vulkan"
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
    "--disable-ffnvcodec"
    "--disable-nvdec"
    "--disable-nvenc"
    "--disable-amf"
    "--extra-ldflags=-static-libgcc -static-libstdc++"
)

record_command "${artifact_root}/build/ffmpeg-configure.txt" ./configure "${ffmpeg_configure_flags[@]}"

(
    cd "${ffmpeg_source}"
    ./configure "${ffmpeg_configure_flags[@]}"
    make -j"$(nproc)"
    make install
)
copy_dlls_from_dir "${deps_prefix}/bin" "${artifact_root}/bin"

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
    -Dwasapi=enabled
    -Dwin32-smtc=disabled
    -Dd3d11=enabled
    -Ddirect3d=disabled
    -Dd3d-hwaccel=enabled
    -Dd3d9-hwaccel=enabled
    -Dvulkan=enabled
    -Dshaderc=enabled
    -Dspirv-cross=enabled
    -Dgl=enabled
    -Dgl-win32=enabled
    -Dgl-dxinterop=enabled
    -Dplain-gl=enabled
    -Dcuda-hwaccel=disabled
    -Dcuda-interop=disabled
    -Dlcms2=enabled
    -Dlibarchive=disabled
    -Duchardet=disabled
    -Dzimg=enabled
    -Drubberband=disabled
)

record_command "${artifact_root}/build/mpv-meson-setup.txt" "${mpv_meson_setup[@]}"
"${mpv_meson_setup[@]}"
meson configure "${build_root}/mpv" >"${artifact_root}/build/mpv-meson-options.txt"
meson compile -C "${build_root}/mpv"
meson install -C "${build_root}/mpv"

mpv_dll="$(find "${build_root}/mpv-install" "${build_root}/mpv" -type f \( -iname 'libmpv-*.dll' -o -iname 'mpv-*.dll' \) | sort | head -n 1)"
if [[ -z "${mpv_dll}" ]]; then
    echo "mpv DLL was not produced" >&2
    exit 1
fi

cp "${mpv_dll}" "${artifact_root}/bin/mpv-2.dll"
copy_dlls_from_dir "${build_root}/mpv-install/bin" "${artifact_root}/bin"
copy_mingw_runtime_dlls

copy_if_exists "${ffmpeg_source}/COPYING.LGPLv2.1" "${artifact_root}/licenses/ffmpeg-COPYING.LGPLv2.1"
copy_if_exists "${ffmpeg_source}/LICENSE.md" "${artifact_root}/licenses/ffmpeg-LICENSE.md"
copy_if_exists "${mpv_source}/LICENSE.LGPL" "${artifact_root}/licenses/mpv-LICENSE.LGPL"
copy_if_exists "${libplacebo_source}/LICENSE" "${artifact_root}/licenses/libplacebo-LICENSE"
copy_if_exists "${libass_source}/COPYING" "${artifact_root}/licenses/libass-COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/freetype2-FTL.TXT" \
    "${freetype_source}/docs/FTL.TXT" \
    "${freetype_source}/LICENSE.TXT"
copy_first_existing_license \
    "${artifact_root}/licenses/fribidi-COPYING" \
    "${fribidi_source}/COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/harfbuzz-COPYING" \
    "${harfbuzz_source}/COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/libpng-LICENSE" \
    "${libpng_source}/LICENSE"
copy_first_existing_license \
    "${artifact_root}/licenses/zlib-LICENSE" \
    "${zlib_source}/LICENSE"
copy_first_existing_license \
    "${artifact_root}/licenses/dav1d-COPYING" \
    "${dav1d_source}/COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/zimg-COPYING" \
    "${zimg_source}/COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/lcms2-COPYING" \
    "${lcms2_source}/COPYING"
copy_first_existing_license \
    "${artifact_root}/licenses/vulkan-headers-LICENSE.md" \
    "${vulkan_headers_source}/LICENSE.md"
copy_first_existing_license \
    "${artifact_root}/licenses/vulkan-loader-LICENSE.txt" \
    "${vulkan_loader_source}/LICENSE.txt"
copy_first_existing_license \
    "${artifact_root}/licenses/spirv-cross-LICENSE" \
    "${spirv_cross_source}/LICENSE"
copy_first_existing_license \
    "${artifact_root}/licenses/shaderc-LICENSE" \
    "${shaderc_source}/LICENSE"
copy_first_existing_license \
    "${artifact_root}/licenses/mingw-w64-gcc-runtime-copyright" \
    "/usr/share/doc/gcc-mingw-w64-base/copyright"
copy_first_existing_license \
    "${artifact_root}/licenses/mingw-w64-gcc-runtime-GPL-3" \
    "/usr/share/common-licenses/GPL-3"

cat >"${artifact_root}/build/runtime-feature-summary.json" <<EOF
{
  "schemaVersion": 1,
  "evidenceSources": [
    "component-presence",
    "configure-token"
  ],
  "capabilityFeatureSource": "component-presence",
  "decoderList": null,
  "demuxerList": null,
  "note": "This summary is intentionally coarse because the win64 LGPL runtime is built with FFmpeg --disable-programs. Codec-level capability evidence requires a future decoder-list/demuxer-list artifact."
}
EOF

cat >"${artifact_root}/runtime-manifest.json" <<EOF
{
  "runtimeId": "${runtime_id}",
  "version": "${runtime_version}",
  "target": "win-x64",
  "licenseFlavor": "LGPL",
  "mpv": {
    "version": "${mpv_version}",
    "mesonOptionsFile": "build/mpv-meson-options.txt"
  },
  "ffmpeg": {
    "version": "${ffmpeg_version}",
    "configureFile": "build/ffmpeg-configure.txt"
  },
  "components": [
    {
      "name": "mpv",
      "version": "${mpv_version}",
      "license": "LGPL-2.1-or-later",
      "sourceUrl": "https://github.com/mpv-player/mpv"
    },
    {
      "name": "ffmpeg",
      "version": "${ffmpeg_version}",
      "license": "LGPL-2.1-or-later",
      "sourceUrl": "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz"
    },
    {
      "name": "libplacebo",
      "version": "${libplacebo_ref#v}",
      "license": "LGPL-2.1-or-later",
      "sourceUrl": "${libplacebo_source_url}"
    },
    {
      "name": "libass",
      "version": "${libass_ref}",
      "license": "ISC",
      "sourceUrl": "https://github.com/libass/libass"
    },
    {
      "name": "freetype2",
      "version": "${freetype2_version}",
      "license": "FTL",
      "sourceUrl": "https://download.savannah.gnu.org/releases/freetype/freetype-${freetype2_version}.tar.xz"
    },
    {
      "name": "fribidi",
      "version": "${fribidi_version}",
      "license": "LGPL-2.1-or-later",
      "sourceUrl": "https://github.com/fribidi/fribidi/releases/download/v${fribidi_version}/fribidi-${fribidi_version}.tar.xz"
    },
    {
      "name": "harfbuzz",
      "version": "${harfbuzz_version}",
      "license": "MIT",
      "sourceUrl": "https://github.com/harfbuzz/harfbuzz/releases/download/${harfbuzz_version}/harfbuzz-${harfbuzz_version}.tar.xz"
    },
    {
      "name": "libpng",
      "version": "${libpng_version}",
      "license": "libpng-2.0",
      "sourceUrl": "https://github.com/pnggroup/libpng/archive/v${libpng_version}.tar.gz"
    },
    {
      "name": "zlib",
      "version": "${zlib_version}",
      "license": "Zlib",
      "sourceUrl": "https://zlib.net/zlib-${zlib_version}.tar.xz"
    },
    {
      "name": "dav1d",
      "version": "${dav1d_ref}",
      "license": "BSD-2-Clause",
      "sourceUrl": "${dav1d_source_url}"
    },
    {
      "name": "zimg",
      "version": "${zimg_version}",
      "license": "WTFPL",
      "sourceUrl": "${zimg_source_url}"
    },
    {
      "name": "lcms2",
      "version": "${lcms2_version}",
      "license": "MIT",
      "sourceUrl": "${lcms2_source_url}"
    },
    {
      "name": "vulkan-headers",
      "version": "${vulkan_headers_version}",
      "license": "Apache-2.0",
      "sourceUrl": "${vulkan_headers_source_url}"
    },
    {
      "name": "vulkan-loader",
      "version": "${vulkan_loader_version}",
      "license": "Apache-2.0",
      "sourceUrl": "${vulkan_loader_source_url}"
    },
    {
      "name": "spirv-cross",
      "version": "${spirv_cross_version}",
      "license": "Apache-2.0",
      "sourceUrl": "${spirv_cross_source_url}"
    },
    {
      "name": "shaderc",
      "version": "${shaderc_version}",
      "license": "Apache-2.0",
      "sourceUrl": "${shaderc_source_url}"
    },
    {
      "name": "mingw-w64-gcc-runtime",
      "version": "${mingw_runtime_version}",
      "license": "GPL-3.0-or-later WITH GCC-exception-3.1",
      "sourceUrl": "${mingw_runtime_source_url}"
    }
  ],
  "featureSummary": "build/runtime-feature-summary.json",
  "sha256sums": "build/sha256sums.txt",
  "sbom": "build/sbom.spdx.json"
}
EOF

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

echo "Runtime artifact created: ${artifact_root}"
