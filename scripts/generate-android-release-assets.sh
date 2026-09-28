#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

runtime_root=""
release_version=""
release_channel="rc"
release_dir=""

usage() {
    cat <<EOF
Usage: $(basename "$0") --runtime-root PATH --version VERSION [options]

Generates Gitea Release assets for Android LGPL player runtime artifacts.

Options:
  --runtime-root PATH   Runtime artifact root, e.g. dist/octans-player-runtime-lgpl-android-arm64.
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
        --runtime-root)
            runtime_root="$2"
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

[[ -n "${runtime_root}" ]] || fail "--runtime-root is required"
[[ -n "${release_version}" ]] || fail "--version is required"
[[ -d "${runtime_root}" ]] || fail "runtime root does not exist: ${runtime_root}"

case "${release_channel}" in
    rc)
        if [[ ! "${release_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-rc\.([1-9][0-9]*)$ ]]; then
            fail "invalid rc release version: ${release_version}"
        fi
        prerelease=true
        release_kind="prerelease artifact"
        android_validation="Android universal APK build and device playback smoke before stable adoption"
        validation_text="- Android universal APK build and device playback smoke must pass before stable adoption."
        ;;
    stable)
        if [[ ! "${release_version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            fail "invalid stable release version: ${release_version}"
        fi
        prerelease=false
        release_kind="stable release artifact"
        android_validation="Android universal APK build and device playback smoke completed before stable publication"
        validation_text="- Android universal APK build and device playback smoke evidence should be retained from the stable promotion gate."
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

runtime_root="$(cd "${runtime_root}" && pwd)"
manifest_path="${runtime_root}/runtime-manifest.json"
sha256_manifest_path="${runtime_root}/build/sha256sums.txt"
[[ -f "${manifest_path}" ]] || fail "missing runtime manifest: ${manifest_path}"
[[ -f "${sha256_manifest_path}" ]] || fail "missing runtime sha256 manifest: ${sha256_manifest_path}"

runtime_id="$(jq -r '.runtimeId // empty' "${manifest_path}")"
runtime_target="$(jq -r '.target // empty' "${manifest_path}")"
runtime_abi="$(jq -r '.abi // empty' "${manifest_path}")"
android_api="$(jq -r '.androidApi // empty' "${manifest_path}")"
requires_neon="$(jq -r 'if has("requiresNeon") then (.requiresNeon | tostring) else "" end' "${manifest_path}")"
license_flavor="$(jq -r '.licenseFlavor // empty' "${manifest_path}")"
runtime_version="$(jq -r '.version // empty' "${manifest_path}")"
mpv_version="$(jq -r '.mpv.version // empty' "${manifest_path}")"
ffmpeg_version="$(jq -r '.ffmpeg.version // empty' "${manifest_path}")"

[[ -n "${runtime_id}" ]] || fail "runtime manifest is missing runtimeId"
[[ -n "${runtime_target}" ]] || fail "runtime manifest is missing target"
[[ -n "${runtime_abi}" ]] || fail "runtime manifest is missing abi"
[[ -n "${android_api}" ]] || fail "runtime manifest is missing androidApi"
[[ -n "${license_flavor}" ]] || fail "runtime manifest is missing licenseFlavor"
[[ -n "${runtime_version}" ]] || fail "runtime manifest is missing version"
[[ "${runtime_version}" == "${release_version}" ]] || fail "runtime manifest version does not match release version: ${runtime_version} != ${release_version}"

case "${runtime_id}:${runtime_target}:${runtime_abi}" in
    octans-player-runtime-lgpl-android-arm64:android-arm64:arm64-v8a)
        verifier="scripts/verify-android-runtime-artifact.sh"
        runtime_scope="Android arm64-v8a LGPL libmpv runtime for Octans Android."
        support_note="- This artifact is the Android arm64 mainline native runtime."
        ;;
    octans-player-runtime-lgpl-android-armeabi-v7a:android-armeabi-v7a:armeabi-v7a)
        verifier="scripts/verify-android-armeabi-v7a-runtime-artifact.sh"
        runtime_scope="Android armeabi-v7a LGPL libmpv runtime for Octans Android."
        support_note="- This artifact is experimental support for the verified Android 9 / armeabi-v7a + NEON device range."
        [[ "${requires_neon}" == "true" ]] || fail "armeabi-v7a runtime manifest must set requiresNeon=true"
        ;;
    *)
        fail "unsupported Android runtime manifest identity: ${runtime_id}:${runtime_target}:${runtime_abi}"
        ;;
esac

if [[ -z "${release_dir}" ]]; then
    release_dir="${repo_root}/dist/release"
fi
[[ "${release_dir}" != "/" ]] || fail "refusing to use / as release directory"

release_tag="${runtime_id}-${release_version}"
zip_name="${release_tag}.zip"
notes_name="${release_tag}.md"
zip_path="${release_dir}/${zip_name}"
notes_path="${release_dir}/${notes_name}"
source_refs_path="${release_dir}/source-refs.txt"
release_manifest_path="${release_dir}/release-manifest.json"

rm -rf "${release_dir}"
mkdir -p "${release_dir}"

runtime_parent="$(dirname "${runtime_root}")"
runtime_dir_name="$(basename "${runtime_root}")"
(
    cd "${runtime_parent}"
    zip -qr "${zip_path}" "${runtime_dir_name}"
)

zip_sha256="$(sha256sum "${zip_path}" | awk '{print $1}')"
zip_bytes="$(stat -c '%s' "${zip_path}")"
runtime_manifest_sha256="$(sha256sum "${manifest_path}" | awk '{print $1}')"
runtime_sha256_manifest_sha256="$(sha256sum "${sha256_manifest_path}" | awk '{print $1}')"

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
    printf 'runtime_target=%s\n' "${runtime_target}"
    printf 'runtime_abi=%s\n' "${runtime_abi}"
    printf 'android_api=%s\n' "${android_api}"
    printf 'requires_neon=%s\n' "${requires_neon}"
    printf 'license_flavor=%s\n' "${license_flavor}"
    printf 'source_remote=%s\n' "${source_remote}"
    printf 'source_branch=%s\n' "${source_branch}"
    printf 'source_commit=%s\n' "${source_commit}"
    printf 'source_short_commit=%s\n' "${source_short_commit}"
    printf 'published_at=%s\n' "${published_at}"
} > "${source_refs_path}"

cat > "${notes_path}" <<EOF
# ${runtime_id} ${release_version}

${runtime_scope} This is a ${release_kind}.

## Scope

- LGPL-oriented libmpv runtime for Android ABI \`${runtime_abi}\`.
- Android API \`${android_api}\`, requiresNeon \`${requires_neon:-false}\`.
- FFmpeg \`${ffmpeg_version:-unknown}\`, mpv \`${mpv_version:-unknown}\`.
- Runtime bundle includes jniLibs, mpv assets, licenses, source archives, build options, SBOM and checksum manifest.
${support_note}

## Validation

- Ubuntu artifact gate: \`${verifier}\`.
- Runtime checksum gate: \`sha256sum -c build/sha256sums.txt\`.
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
    --arg runtime_target "${runtime_target}" \
    --arg runtime_abi "${runtime_abi}" \
    --arg android_api "${android_api}" \
    --arg requires_neon "${requires_neon}" \
    --arg license_flavor "${license_flavor}" \
    --arg mpv_version "${mpv_version}" \
    --arg ffmpeg_version "${ffmpeg_version}" \
    --arg zip_file "${zip_name}" \
    --arg zip_sha256 "${zip_sha256}" \
    --argjson zip_bytes "${zip_bytes}" \
    --arg runtime_manifest_sha256 "${runtime_manifest_sha256}" \
    --arg runtime_sha256_manifest_sha256 "${runtime_sha256_manifest_sha256}" \
    --arg verifier "${verifier}" \
    --arg android_validation "${android_validation}" \
    '{
      schemaVersion: 1,
      kind: "octans-player-runtime-release",
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
        target: $runtime_target,
        licenseFlavor: $license_flavor,
        mpvVersion: $mpv_version,
        ffmpegVersion: $ffmpeg_version,
        android: {
          abi: $runtime_abi,
          androidApi: ($android_api | tonumber),
          requiresNeon: (if $requires_neon == "" then false else ($requires_neon == "true") end)
        },
        archive: {
          file: $zip_file,
          sha256: $zip_sha256,
          bytes: $zip_bytes
        },
        manifests: {
          runtimeManifestSha256: $runtime_manifest_sha256,
          runtimeSha256ManifestSha256: $runtime_sha256_manifest_sha256
        }
      },
      verification: [
        $verifier,
        "sha256sum -c build/sha256sums.txt",
        $android_validation
      ],
      artifacts: .
    }' "${artifact_json}" > "${release_manifest_path}"

(
    cd "${release_dir}"
    find . -maxdepth 1 -type f ! -name 'sha256sums.txt' \
        -printf '%P\0' | sort -z | xargs -0 sha256sum > sha256sums.txt
)

printf 'release assets generated:\n'
printf '  channel: %s\n' "${release_channel}"
printf '  version: %s\n' "${release_version}"
printf '  release_dir: %s\n' "${release_dir}"
printf '  runtime_id: %s\n' "${runtime_id}"
printf '  runtime_abi: %s\n' "${runtime_abi}"
printf '  zip_sha256: %s\n' "${zip_sha256}"
find "${release_dir}" -maxdepth 1 -type f -printf '  - %f\n' | sort
