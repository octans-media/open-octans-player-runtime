#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

artifact_root=""
release_version=""
release_channel="rc"
release_dir=""

runtime_id_expected="octans-player-runtime-lgpl-media3-libass-renderer-android"
artifact_kind_expected="media3-libass-renderer"
target_expected="android-media3-libass-renderer"
libass_android_commit_expected="07b447fabceee6a0811e58652a468bb4b5429163"
renderer_library_expected="liboctans_ass_renderer.so"
jni_library_expected="liboctans_ass_renderer_jni.so"

usage() {
    cat <<EOF
Usage: $(basename "$0") --artifact-root PATH --version VERSION [options]

Generates Gitea Release assets for the Android Media3 libass renderer artifact.

Options:
  --artifact-root PATH  Artifact root, e.g. dist/octans-player-runtime-lgpl-media3-libass-renderer-android.
  --version VERSION     Release version, e.g. 0.1.0-rc.1 or 0.1.0.
  --channel NAME        Release channel: rc or stable. Defaults to rc.
  --release-dir PATH    Output directory for release assets.
  -h, --help            Show this help.
EOF
}

fail() {
    printf 'fail - %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact-root)
            artifact_root="$2"
            shift 2
            ;;
        --version)
            release_version="$2"
            shift 2
            ;;
        --channel)
            release_channel="$2"
            shift 2
            ;;
        --release-dir)
            release_dir="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "${artifact_root}" ]] || fail "--artifact-root is required"
[[ -n "${release_version}" ]] || fail "--version is required"
[[ -d "${artifact_root}" ]] || fail "artifact root does not exist: ${artifact_root}"

case "${release_channel}" in
    rc)
        if [[ ! "${release_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-rc\.([1-9][0-9]*)$ ]]; then
            fail "invalid rc release version: ${release_version}"
        fi
        prerelease=true
        release_kind="prerelease artifact"
        android_validation="Android restore plus APK build, APK native ownership check and ASS playback smoke before stable adoption"
        validation_text="- Android restore, APK build, APK native ownership check and ASS playback smoke must pass before stable adoption."
        ;;
    stable)
        if [[ ! "${release_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            fail "invalid stable release version: ${release_version}"
        fi
        prerelease=false
        release_kind="stable release artifact"
        android_validation="Android restore plus APK build, APK native ownership check and ASS playback smoke completed before stable publication"
        validation_text="- Android restore, APK build, APK native ownership check and ASS playback smoke evidence should be retained from the stable promotion gate."
        ;;
    *)
        fail "--channel must be rc or stable: ${release_channel}"
        ;;
esac

command -v git >/dev/null || fail "git is required"
command -v jq >/dev/null || fail "jq is required"
command -v sha256sum >/dev/null || fail "sha256sum is required"
command -v stat >/dev/null || fail "stat is required"
command -v zip >/dev/null || fail "zip is required"

artifact_root="$(cd "${artifact_root}" && pwd)"
manifest_path="${artifact_root}/runtime-manifest.json"
sha256_manifest_path="${artifact_root}/build/sha256sums.txt"
ass_kt_aar_path="${artifact_root}/aar/lib_ass_kt-release.aar"
ass_media_aar_path="${artifact_root}/aar/lib_ass_media-release.aar"
native_inventory_path="${artifact_root}/build/native-inventory.txt"
patches_applied_path="${artifact_root}/build/patches-applied.txt"
javap_ass_path="${artifact_root}/build/javap-Ass.txt"

[[ -f "${manifest_path}" ]] || fail "missing runtime manifest: ${manifest_path}"
[[ -f "${sha256_manifest_path}" ]] || fail "missing artifact sha256 manifest: ${sha256_manifest_path}"
[[ -f "${ass_kt_aar_path}" ]] || fail "missing lib_ass_kt AAR: ${ass_kt_aar_path}"
[[ -f "${ass_media_aar_path}" ]] || fail "missing lib_ass_media AAR: ${ass_media_aar_path}"
[[ -f "${native_inventory_path}" ]] || fail "missing native inventory: ${native_inventory_path}"
[[ -f "${patches_applied_path}" ]] || fail "missing patch evidence: ${patches_applied_path}"
[[ -f "${javap_ass_path}" ]] || fail "missing javap evidence: ${javap_ass_path}"

runtime_id="$(jq -r '.runtimeId // empty' "${manifest_path}")"
artifact_kind="$(jq -r '.artifactKind // empty' "${manifest_path}")"
runtime_target="$(jq -r '.target // empty' "${manifest_path}")"
license_flavor="$(jq -r '.licenseFlavor // empty' "${manifest_path}")"
runtime_version="$(jq -r '.version // empty' "${manifest_path}")"
android_api="$(jq -r '.androidApi // empty' "${manifest_path}")"
min_sdk="$(jq -r '.minSdk // empty' "${manifest_path}")"
compile_sdk="$(jq -r '.compileSdk // empty' "${manifest_path}")"
ndk_version="$(jq -r '.toolchain.androidNdk.version // empty' "${manifest_path}")"
cmake_version="$(jq -r '.toolchain.cmake.version // empty' "${manifest_path}")"
gradle_version="$(jq -r '.toolchain.gradleWrapper.version // empty' "${manifest_path}")"
agp_version="$(jq -r '.toolchain.androidGradlePlugin.version // empty' "${manifest_path}")"
kotlin_version="$(jq -r '.toolchain.kotlin.version // empty' "${manifest_path}")"
media3_version="$(jq -r '.media3.dependencyVersion // empty' "${manifest_path}")"
libass_android_tag="$(jq -r '.libassAndroid.tag // empty' "${manifest_path}")"
libass_android_commit="$(jq -r '.libassAndroid.commit // .libassAndroid.sourceCommit // empty' "${manifest_path}")"
renderer_library="$(jq -r '.libassAndroid.ownershipPolicy.rendererSharedLibrary // empty' "${manifest_path}")"
jni_library="$(jq -r '.libassAndroid.ownershipPolicy.jniSharedLibrary // empty' "${manifest_path}")"
font_strategy="$(jq -r '.libassAndroid.ownershipPolicy.fontStrategy // empty' "${manifest_path}")"
abis="$(jq -r '.abis | sort | join(",")' "${manifest_path}")"
forbidden_libraries="$(jq -r '.libassAndroid.ownershipPolicy.forbiddenSharedLibraries | sort | join(",")' "${manifest_path}")"
native_components="$(jq -c '.nativeComponents // []' "${manifest_path}")"
ownership_policy="$(jq -c '.libassAndroid.ownershipPolicy // {}' "${manifest_path}")"
patch_set="$(jq -c '.libassAndroid.patchSet // []' "${manifest_path}")"

[[ "${runtime_id}" == "${runtime_id_expected}" ]] || fail "unexpected runtimeId: ${runtime_id}"
[[ "${artifact_kind}" == "${artifact_kind_expected}" ]] || fail "unexpected artifactKind: ${artifact_kind}"
[[ "${runtime_target}" == "${target_expected}" ]] || fail "unexpected target: ${runtime_target}"
[[ "${abis}" == "arm64-v8a,armeabi-v7a" ]] || fail "unexpected ABI set: ${abis}"
[[ "${license_flavor}" == "LGPL" ]] || fail "unexpected licenseFlavor: ${license_flavor}"
[[ "${runtime_version}" == "${release_version}" ]] || fail "runtime manifest version does not match release version: ${runtime_version} != ${release_version}"
[[ "${libass_android_commit}" == "${libass_android_commit_expected}" ]] || fail "unexpected libass-android commit: ${libass_android_commit}"
[[ "${renderer_library}" == "${renderer_library_expected}" ]] || fail "unexpected renderer shared library: ${renderer_library}"
[[ "${jni_library}" == "${jni_library_expected}" ]] || fail "unexpected JNI shared library: ${jni_library}"
[[ "${forbidden_libraries}" == "libass.so,libasskt.so,libc++_shared.so" ]] || fail "unexpected forbidden shared libraries: ${forbidden_libraries}"
[[ -n "${ndk_version}" ]] || fail "runtime manifest is missing toolchain.androidNdk.version"
[[ -n "${cmake_version}" ]] || fail "runtime manifest is missing toolchain.cmake.version"
[[ -n "${media3_version}" ]] || fail "runtime manifest is missing media3.dependencyVersion"
[[ -n "${font_strategy}" ]] || fail "runtime manifest is missing font strategy"

if ! grep -Fq "configureFonts(" "${javap_ass_path}" \
    || ! grep -Fq "nativeAssConfigureFonts(" "${javap_ass_path}"; then
    fail "javap evidence does not include configureFonts/nativeAssConfigureFonts"
fi

if [[ -z "${release_dir}" ]]; then
    release_dir="${repo_root}/dist/release-m3ass"
fi
if [[ "${release_dir}" != /* ]]; then
    release_dir="${repo_root}/${release_dir}"
fi
[[ "${release_dir}" != "/" ]] || fail "refusing to use / as release directory"

release_tag="${runtime_id}-${release_version}"
zip_name="${release_tag}.zip"
zip_sha_name="${zip_name}.sha256"
manifest_name="${release_tag}-manifest.json"
notes_name="${release_tag}.md"
zip_path="${release_dir}/${zip_name}"
zip_sha_path="${release_dir}/${zip_sha_name}"
published_manifest_path="${release_dir}/${manifest_name}"
notes_path="${release_dir}/${notes_name}"
source_refs_path="${release_dir}/source-refs.txt"
release_manifest_path="${release_dir}/release-manifest.json"

rm -rf "${release_dir}"
mkdir -p "${release_dir}"

artifact_parent="$(dirname "${artifact_root}")"
artifact_dir_name="$(basename "${artifact_root}")"
(
    cd "${artifact_parent}"
    zip -qr "${zip_path}" "${artifact_dir_name}"
)

zip_sha256="$(sha256sum "${zip_path}" | awk '{print $1}')"
zip_bytes="$(stat -c '%s' "${zip_path}")"
printf '%s  %s\n' "${zip_sha256}" "${zip_name}" > "${zip_sha_path}"
cp "${manifest_path}" "${published_manifest_path}"

runtime_manifest_sha256="$(sha256sum "${manifest_path}" | awk '{print $1}')"
runtime_sha256_manifest_sha256="$(sha256sum "${sha256_manifest_path}" | awk '{print $1}')"
ass_kt_aar_sha256="$(sha256sum "${ass_kt_aar_path}" | awk '{print $1}')"
ass_kt_aar_bytes="$(stat -c '%s' "${ass_kt_aar_path}")"
ass_media_aar_sha256="$(sha256sum "${ass_media_aar_path}" | awk '{print $1}')"
ass_media_aar_bytes="$(stat -c '%s' "${ass_media_aar_path}")"

published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
source_commit="$(git -C "${repo_root}" rev-parse HEAD)"
source_short_commit="$(git -C "${repo_root}" rev-parse --short=8 HEAD)"
source_branch="${GITHUB_REF_NAME:-$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD)}"
source_remote="$(git -C "${repo_root}" config --get remote.origin.url || true)"

{
    printf 'release_tag=%s\n' "${release_tag}"
    printf 'release_channel=%s\n' "${release_channel}"
    printf 'release_version=%s\n' "${release_version}"
    printf 'prerelease=%s\n' "${prerelease}"
    printf 'runtime_id=%s\n' "${runtime_id}"
    printf 'artifact_kind=%s\n' "${artifact_kind}"
    printf 'runtime_target=%s\n' "${runtime_target}"
    printf 'abis=%s\n' "${abis}"
    printf 'android_api=%s\n' "${android_api}"
    printf 'min_sdk=%s\n' "${min_sdk}"
    printf 'compile_sdk=%s\n' "${compile_sdk}"
    printf 'ndk_version=%s\n' "${ndk_version}"
    printf 'cmake_version=%s\n' "${cmake_version}"
    printf 'gradle_version=%s\n' "${gradle_version}"
    printf 'agp_version=%s\n' "${agp_version}"
    printf 'kotlin_version=%s\n' "${kotlin_version}"
    printf 'media3_version=%s\n' "${media3_version}"
    printf 'libass_android_tag=%s\n' "${libass_android_tag}"
    printf 'libass_android_commit=%s\n' "${libass_android_commit}"
    printf 'renderer_library=%s\n' "${renderer_library}"
    printf 'jni_library=%s\n' "${jni_library}"
    printf 'forbidden_libraries=%s\n' "${forbidden_libraries}"
    printf 'license_flavor=%s\n' "${license_flavor}"
    printf 'source_remote=%s\n' "${source_remote}"
    printf 'source_branch=%s\n' "${source_branch}"
    printf 'source_commit=%s\n' "${source_commit}"
    printf 'source_short_commit=%s\n' "${source_short_commit}"
    printf 'published_at=%s\n' "${published_at}"
} > "${source_refs_path}"

cat > "${notes_path}" <<EOF
# ${runtime_id} ${release_version}

Android Media3 libass renderer AARs for Octans Android. This is a ${release_kind}.

## Scope

- Artifact kind: \`${artifact_kind}\`.
- Android AARs with ABI entries \`${abis}\`.
- Output AARs: \`aar/lib_ass_kt-release.aar\` and \`aar/lib_ass_media-release.aar\`.
- Media3 \`${media3_version}\`.
- libass-android \`${libass_android_tag}\`, commit \`${libass_android_commit}\`.
- Android API \`${android_api}\`, minSdk \`${min_sdk}\`, compileSdk \`${compile_sdk}\`.
- NDK \`${ndk_version}\`, CMake \`${cmake_version}\`.
- Gradle \`${gradle_version}\`, AGP \`${agp_version}\`, Kotlin \`${kotlin_version}\`.
- Renderer native libraries: \`${renderer_library}\` and \`${jni_library}\`.
- Forbidden native libraries: \`${forbidden_libraries}\`.
- Font strategy: \`${font_strategy}\`.
- License flavor: \`${license_flavor}\`.

## Validation

- Ubuntu artifact gate: \`scripts/verify-media3-libass-renderer-artifact.sh\`.
- Runtime checksum gate: \`sha256sum -c build/sha256sums.txt\`.
- Native ownership gate: no \`libass.so\`, \`libasskt.so\`, \`libc++_shared.so\`, x86 or x86_64 entries in the libass renderer AAR.
- Font API gate: \`Ass.configureFonts(...)\` and native fontconfig hooks are present.
${validation_text}

## Checksums

- \`${zip_name}\`
- sha256: \`${zip_sha256}\`

## Source

- Runtime repository commit: \`${source_commit}\`.
- Release tag: \`${release_tag}\`.
EOF

artifact_json="$(mktemp)"
trap 'rm -f "${artifact_json}"' EXIT
: > "${artifact_json}"

while IFS= read -r -d '' file_path; do
    file_name="$(basename "${file_path}")"
    file_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
    file_size="$(stat -c '%s' "${file_path}")"
    jq -n \
        --arg file "${file_name}" \
        --arg sha256 "${file_sha}" \
        --argjson bytes "${file_size}" \
        '{file: $file, sha256: $sha256, bytes: $bytes}' \
        >> "${artifact_json}"
done < <(
    find "${release_dir}" -maxdepth 1 -type f \
        ! -name 'release-manifest.json' \
        ! -name 'sha256sums.txt' \
        -print0 | sort -z
)

jq -s \
    --arg published_at "${published_at}" \
    --arg release_tag "${release_tag}" \
    --arg release_channel "${release_channel}" \
    --arg release_version "${release_version}" \
    --argjson prerelease "${prerelease}" \
    --arg source_remote "${source_remote}" \
    --arg source_branch "${source_branch}" \
    --arg source_commit "${source_commit}" \
    --arg source_short_commit "${source_short_commit}" \
    --arg runtime_id "${runtime_id}" \
    --arg artifact_kind "${artifact_kind}" \
    --arg runtime_target "${runtime_target}" \
    --arg license_flavor "${license_flavor}" \
    --arg android_api "${android_api}" \
    --arg min_sdk "${min_sdk}" \
    --arg compile_sdk "${compile_sdk}" \
    --arg ndk_version "${ndk_version}" \
    --arg cmake_version "${cmake_version}" \
    --arg gradle_version "${gradle_version}" \
    --arg agp_version "${agp_version}" \
    --arg kotlin_version "${kotlin_version}" \
    --arg media3_version "${media3_version}" \
    --arg libass_android_tag "${libass_android_tag}" \
    --arg libass_android_commit "${libass_android_commit}" \
    --arg renderer_library "${renderer_library}" \
    --arg jni_library "${jni_library}" \
    --arg forbidden_libraries "${forbidden_libraries}" \
    --arg font_strategy "${font_strategy}" \
    --arg abis "${abis}" \
    --argjson ownership_policy "${ownership_policy}" \
    --argjson patch_set "${patch_set}" \
    --argjson native_components "${native_components}" \
    --arg zip_file "${zip_name}" \
    --arg zip_sha256 "${zip_sha256}" \
    --argjson zip_bytes "${zip_bytes}" \
    --arg ass_kt_aar_sha256 "${ass_kt_aar_sha256}" \
    --argjson ass_kt_aar_bytes "${ass_kt_aar_bytes}" \
    --arg ass_media_aar_sha256 "${ass_media_aar_sha256}" \
    --argjson ass_media_aar_bytes "${ass_media_aar_bytes}" \
    --arg runtime_manifest_sha256 "${runtime_manifest_sha256}" \
    --arg runtime_sha256_manifest_sha256 "${runtime_sha256_manifest_sha256}" \
    --arg verifier "scripts/verify-media3-libass-renderer-artifact.sh" \
    --arg android_validation "${android_validation}" \
    '{
      schemaVersion: 1,
      kind: "octans-player-runtime-m3ass-release",
      publishedAt: $published_at,
      release: {
        tag: $release_tag,
        channel: $release_channel,
        version: $release_version,
        prerelease: $prerelease
      },
      source: {
        remote: $source_remote,
        branch: $source_branch,
        commit: $source_commit,
        shortCommit: $source_short_commit
      },
      runtime: {
        id: $runtime_id,
        artifactKind: $artifact_kind,
        target: $runtime_target,
        licenseFlavor: $license_flavor,
        android: {
          abis: ($abis | split(",")),
          androidApi: ($android_api | tonumber),
          minSdk: ($min_sdk | tonumber),
          compileSdk: ($compile_sdk | tonumber),
          ndkVersion: $ndk_version,
          cmakeVersion: $cmake_version,
          gradleVersion: $gradle_version,
          androidGradlePluginVersion: $agp_version,
          kotlinVersion: $kotlin_version
        },
        media3: {
          dependencyVersion: $media3_version
        },
        libassAndroid: {
          tag: $libass_android_tag,
          commit: $libass_android_commit,
          ownershipPolicy: $ownership_policy,
          patchSet: $patch_set,
          nativeComponents: $native_components,
          fontStrategy: $font_strategy
        },
        archive: {
          file: $zip_file,
          sha256: $zip_sha256,
          bytes: $zip_bytes
        },
        aars: [
          {
            file: "aar/lib_ass_kt-release.aar",
            sha256: $ass_kt_aar_sha256,
            bytes: $ass_kt_aar_bytes
          },
          {
            file: "aar/lib_ass_media-release.aar",
            sha256: $ass_media_aar_sha256,
            bytes: $ass_media_aar_bytes
          }
        ],
        nativeLibraries: {
          rendererSharedLibrary: $renderer_library,
          jniSharedLibrary: $jni_library,
          forbiddenSharedLibraries: ($forbidden_libraries | split(","))
        },
        manifests: {
          runtimeManifestSha256: $runtime_manifest_sha256,
          runtimeSha256ManifestSha256: $runtime_sha256_manifest_sha256
        }
      },
      verification: [
        $verifier,
        "sha256sum -c build/sha256sums.txt",
        "readelf native ownership checks for liboctans_ass_renderer.so and liboctans_ass_renderer_jni.so",
        "javap check for configureFonts/nativeAssConfigureFonts",
        $android_validation
      ],
      artifacts: .
    }' "${artifact_json}" > "${release_manifest_path}"

(
    cd "${release_dir}"
    find . -maxdepth 1 -type f ! -name 'sha256sums.txt' \
        -printf '%P\0' | sort -z | xargs -0 sha256sum > sha256sums.txt
)

printf 'm3ass release assets generated:\n'
printf '  channel: %s\n' "${release_channel}"
printf '  version: %s\n' "${release_version}"
printf '  release_dir: %s\n' "${release_dir}"
printf '  runtime_id: %s\n' "${runtime_id}"
printf '  abis: %s\n' "${abis}"
printf '  zip_sha256: %s\n' "${zip_sha256}"
find "${release_dir}" -maxdepth 1 -type f -printf '  - %f\n' | sort
