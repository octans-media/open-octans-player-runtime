#!/usr/bin/env bash
# Prune stale CI run directories under the player-runtime shared cache.
#
# Historical Docker builds wrote root-owned files into run dirs. Host-side
# `rm -rf` as the runner user then fails with Permission denied. This helper:
#   1. Tries a normal host delete first
#   2. Falls back to a root Docker container when host delete fails
#
# Usage:
#   scripts/ci-prune-stale-run-cache.sh <run_root> [max_age_days]
#
# Defaults:
#   max_age_days = 7
set -euo pipefail

run_root="${1:?run root required}"
max_age_days="${2:-7}"

if [[ ! "${max_age_days}" =~ ^[0-9]+$ ]]; then
    echo "max_age_days must be a non-negative integer: ${max_age_days}" >&2
    exit 2
fi

if [[ ! -d "${run_root}" ]]; then
    exit 0
fi

# Resolve absolute path for reliable docker bind mounts.
run_root="$(cd "${run_root}" && pwd)"

prune_one() {
    local stale_dir="$1"
    local base_name

    if [[ ! -e "${stale_dir}" ]]; then
        return 0
    fi

    if rm -rf "${stale_dir}" 2>/dev/null; then
        printf 'pruned stale CI run: %s\n' "${stale_dir}"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "failed to remove stale CI run (permission denied, docker unavailable): ${stale_dir}" >&2
        return 1
    fi

    base_name="$(basename "${stale_dir}")"
    printf 'host rm failed (likely root-owned), pruning via docker: %s\n' "${stale_dir}" >&2

    docker run --rm --user 0:0 \
        -v "${run_root}:/runs" \
        --entrypoint bash \
        ubuntu:26.04 \
        -c "rm -rf '/runs/${base_name}'"

    if [[ -e "${stale_dir}" ]]; then
        echo "failed to prune stale CI run via docker: ${stale_dir}" >&2
        return 1
    fi

    printf 'pruned stale CI run via docker: %s\n' "${stale_dir}"
}

fail_count=0
while IFS= read -r -d '' stale_run_dir; do
    if ! prune_one "${stale_run_dir}"; then
        fail_count=$((fail_count + 1))
    fi
done < <(
    find "${run_root}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -mtime "+${max_age_days}" \
        -print0
)

if [[ "${fail_count}" -gt 0 ]]; then
    echo "failed to prune ${fail_count} stale CI run director(ies) under ${run_root}" >&2
    exit 1
fi
