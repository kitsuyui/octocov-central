#!/usr/bin/env bash
# Emit GitHub Actions warnings for badge directories not updated in
# THRESHOLD_DAYS days.  A stale badge indicates the source artifact has
# likely expired (GitHub Actions artifacts auto-delete after 90 days).
set -euo pipefail

config_file="${1:-.octocov.yml}"
threshold_days="${THRESHOLD_DAYS:-90}"

if [[ ! -f "${config_file}" ]]; then
  echo "::error::${config_file} not found" >&2
  exit 1
fi

cutoff_epoch=$(date -d "${threshold_days} days ago" +%s)

mapfile -t repo_paths < <(
  grep -oP 'artifact://\K[^/]+/[^/]+(?=/octocov-report)' "${config_file}" || true
)

if [[ ${#repo_paths[@]} -eq 0 ]]; then
  echo "No artifact:// references found in ${config_file}; skipping."
  exit 0
fi

for repo_path in "${repo_paths[@]}"; do
  badge_dir="badges/${repo_path}"
  if [[ ! -d "${badge_dir}" ]]; then
    continue
  fi
  last_epoch=$(git log --format="%at" -1 -- "${badge_dir}")
  if [[ -z "${last_epoch}" ]] || (( last_epoch < cutoff_epoch )); then
    echo "::warning::Badge not updated in ${threshold_days}+ days (artifact may have expired): ${repo_path}"
  fi
done
