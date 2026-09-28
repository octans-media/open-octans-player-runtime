#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

artifact_root=""
release_version=""
release_channel="rc"
release_dir=""

runtime_id_expected="octans-player-runtime-lgpl-media3-ffmpeg-decoder-android"
artifact_kind_expected="media3-ffmpeg-decoder"
target_expected="android-media3-ffmpeg-decoder"

usage() {
    cat <<EOF
Usage: $(basename "$0") --artifact-root PATH --version VERSION [options]

Generates Gitea Release assets for the Android Media3 FFmpeg decoder artifact.

Options:
  --artifact-root PATH  Artifact root, e.g. dist/octans-player-runtime-lgpl-media3-ffmpeg-decoder-android.
  --version VERSION     Release version, e.g. 0.2.0-rc.1 or 0.2.0.
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
        android_validation="Android restore plus APK build and device playback smoke before stable adoption"
        validation_text="- Android restore, APK build, APK entry check and playback smoke must pass before stable adoption."
        ;;
    stable)
        if [[ ! "${release_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            fail "invalid stable release version: ${release_version}"
        fi
        prerelease=false
        release_kind="stable release artifact"
        android_validation="Android restore plus APK build and device playback smoke completed before stable publication"
        validation_text="- Android restore, APK build, APK entry check and playback smoke evidence should be retained from the stable promotion gate."
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
aar_path="${artifact_root}/aar/media3-decoder-ffmpeg-release.aar"
[[ -f "${manifest_path}" ]] || fail "missing runtime manifest: ${manifest_path}"
[[ -f "${sha256_manifest_path}" ]] || fail "missing artifact sha256 manifest: ${sha256_manifest_path}"
[[ -f "${aar_path}" ]] || fail "missing release AAR: ${aar_path}"

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
media3_version="$(jq -r '.media3.dependencyVersion // empty' "${manifest_path}")"
media3_commit="$(jq -r '.media3.sourceCommit // empty' "${manifest_path}")"
ffmpeg_branch="$(jq -r '.ffmpeg.branch // empty' "${manifest_path}")"
ffmpeg_commit="$(jq -r '.ffmpeg.commit // empty' "${manifest_path}")"
enabled_decoders="$(jq -r '.ffmpeg.enabledDecoders | join(",")' "${manifest_path}")"
enabled_filters="$(jq -r '.ffmpeg.enabledFilters // [] | join(",")' "${manifest_path}")"
abis="$(jq -r '.abis | sort | join(",")' "${manifest_path}")"
enabled_gpl="$(jq -r '.ffmpeg.configurePolicy.enabledGpl | tostring' "${manifest_path}")"
enabled_nonfree="$(jq -r '.ffmpeg.configurePolicy.enabledNonfree | tostring' "${manifest_path}")"

[[ "${runtime_id}" == "${runtime_id_expected}" ]] || fail "unexpected runtimeId: ${runtime_id}"
[[ "${artifact_kind}" == "${artifact_kind_expected}" ]] || fail "unexpected artifactKind: ${artifact_kind}"
[[ "${runtime_target}" == "${target_expected}" ]] || fail "unexpected target: ${runtime_target}"
[[ "${abis}" == "arm64-v8a,armeabi-v7a" ]] || fail "unexpected ABI set: ${abis}"
[[ "${license_flavor}" == "LGPL" ]] || fail "unexpected licenseFlavor: ${license_flavor}"
[[ "${runtime_version}" == "${release_version}" ]] || fail "runtime manifest version does not match release version: ${runtime_version} != ${release_version}"
[[ -n "${ndk_version}" ]] || fail "runtime manifest is missing toolchain.androidNdk.version"
[[ -n "${cmake_version}" ]] || fail "runtime manifest is missing toolchain.cmake.version"
[[ "${enabled_gpl}" == "false" ]] || fail "FFmpeg GPL configure policy must be false"
[[ "${enabled_nonfree}" == "false" ]] || fail "FFmpeg nonfree configure policy must be false"

if [[ -z "${release_dir}" ]]; then
    release_dir="${repo_root}/dist/release-m3ff"
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
aar_sha256="$(sha256sum "${aar_path}" | awk '{print $1}')"
aar_bytes="$(stat -c '%s' "${aar_path}")"

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
    printf 'media3_version=%s\n' "${media3_version}"
    printf 'media3_commit=%s\n' "${media3_commit}"
    printf 'ffmpeg_branch=%s\n' "${ffmpeg_branch}"
    printf 'ffmpeg_commit=%s\n' "${ffmpeg_commit}"
    printf 'enabled_decoders=%s\n' "${enabled_decoders}"
    printf 'enabled_filters=%s\n' "${enabled_filters}"
    printf 'license_flavor=%s\n' "${license_flavor}"
    printf 'source_remote=%s\n' "${source_remote}"
    printf 'source_branch=%s\n' "${source_branch}"
    printf 'source_commit=%s\n' "${source_commit}"
    printf 'source_short_commit=%s\n' "${source_short_commit}"
    printf 'published_at=%s\n' "${published_at}"
} > "${source_refs_path}"

cat > "${notes_path}" <<EOF
# ${runtime_id} ${release_version}

Android Media3 FFmpeg decoder AAR for Octans Android. This is a ${release_kind}.

## Scope

- Artifact kind: \`${artifact_kind}\`.
- Android AAR with ABI entries \`${abis}\`.
- Media3 \`${media3_version}\`, source commit \`${media3_commit}\`.
- FFmpeg \`${ffmpeg_branch}\`, commit \`${ffmpeg_commit}\`.
- Android API \`${android_api}\`, minSdk \`${min_sdk}\`, compileSdk \`${compile_sdk}\`.
- NDK \`${ndk_version}\`, CMake \`${cmake_version}\`.
- Enabled decoders: \`${enabled_decoders}\`.
- Enabled filters: \`${enabled_filters}\`.
- License flavor: \`${license_flavor}\`; GPL and nonfree configure policies are false.

## Validation

- Ubuntu artifact gate: \`scripts/verify-media3-ffmpeg-decoder-artifact.sh\`.
- Runtime checksum gate: \`sha256sum -c build/sha256sums.txt\`.
- Octans graph smoke: synthetic 5.1(side) and 7.1 PCM to \`stereo / 48000Hz\`.
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
    --arg media3_version "${media3_version}" \
    --arg media3_commit "${media3_commit}" \
    --arg ffmpeg_branch "${ffmpeg_branch}" \
    --arg ffmpeg_commit "${ffmpeg_commit}" \
    --arg enabled_decoders "${enabled_decoders}" \
    --arg enabled_filters "${enabled_filters}" \
    --arg abis "${abis}" \
    --arg zip_file "${zip_name}" \
    --arg zip_sha256 "${zip_sha256}" \
    --argjson zip_bytes "${zip_bytes}" \
    --arg aar_sha256 "${aar_sha256}" \
    --argjson aar_bytes "${aar_bytes}" \
    --arg runtime_manifest_sha256 "${runtime_manifest_sha256}" \
    --arg runtime_sha256_manifest_sha256 "${runtime_sha256_manifest_sha256}" \
    --arg verifier "scripts/verify-media3-ffmpeg-decoder-artifact.sh" \
    --arg android_validation "${android_validation}" \
    '{
      schemaVersion: 1,
      kind: "octans-player-runtime-m3ff-release",
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
          cmakeVersion: $cmake_version
        },
        media3: {
          dependencyVersion: $media3_version,
          sourceCommit: $media3_commit
        },
        ffmpeg: {
          branch: $ffmpeg_branch,
          commit: $ffmpeg_commit,
          enabledDecoders: ($enabled_decoders | split(",")),
          enabledFilters: (if $enabled_filters == "" then [] else ($enabled_filters | split(",")) end)
        },
        archive: {
          file: $zip_file,
          sha256: $zip_sha256,
          bytes: $zip_bytes
        },
        aar: {
          file: "aar/media3-decoder-ffmpeg-release.aar",
          sha256: $aar_sha256,
          bytes: $aar_bytes
        },
        manifests: {
          runtimeManifestSha256: $runtime_manifest_sha256,
          runtimeSha256ManifestSha256: $runtime_sha256_manifest_sha256
        }
      },
      verification: [
        $verifier,
        "sha256sum -c build/sha256sums.txt",
        "synthetic 5.1(side) and 7.1 graph smoke to stereo/48000",
        $android_validation
      ],
      artifacts: .
    }' "${artifact_json}" > "${release_manifest_path}"

(
    cd "${release_dir}"
    find . -maxdepth 1 -type f ! -name 'sha256sums.txt' \
        -printf '%P\0' | sort -z | xargs -0 sha256sum > sha256sums.txt
)

printf 'm3ff release assets generated:\n'
printf '  channel: %s\n' "${release_channel}"
printf '  version: %s\n' "${release_version}"
printf '  release_dir: %s\n' "${release_dir}"
printf '  runtime_id: %s\n' "${runtime_id}"
printf '  abis: %s\n' "${abis}"
printf '  zip_sha256: %s\n' "${zip_sha256}"
find "${release_dir}" -maxdepth 1 -type f -printf '  - %f\n' | sort
