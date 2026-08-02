#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_script="${script_dir}/check-octocov-artifacts.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

write_fake_gh() {
  cat >"${tmpdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_path=""
artifact_name=""
while (($# > 0)); do
  case "$1" in
    repos/*/actions/artifacts)
      repo_path="${1#repos/}"
      repo_path="${repo_path%/actions/artifacts}"
      shift
      ;;
    -f)
      case "$2" in
        name=*)
          artifact_name="${2#name=}"
          ;;
      esac
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "${repo_path}:${artifact_name}" in
  kitsuyui/good:octocov-report)
    printf '%s\n' '{"artifacts":[{"expired":true},{"expired":false}]}'
    ;;
  kitsuyui/paginated:octocov-report)
    printf '%s\n' '[{"artifacts":[{"expired":true}]},{"artifacts":[{"expired":false}]}]'
    ;;
  kitsuyui/custom:custom-report)
    printf '%s\n' '{"artifacts":[{"expired":false}]}'
    ;;
  kitsuyui/expired:octocov-report)
    printf '%s\n' '{"artifacts":[{"expired":true}]}'
    ;;
  kitsuyui/fail:octocov-report)
    echo "simulated gh failure" >&2
    exit 1
    ;;
  *)
    printf '%s\n' '{"artifacts":[]}'
    ;;
esac
EOF
  chmod +x "${tmpdir}/gh"
}

assert_exit() {
  local expected="$1"
  local actual="$2"
  local context="$3"

  if [[ "${expected}" != "${actual}" ]]; then
    echo "expected exit ${expected}, got ${actual}: ${context}" >&2
    exit 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local context="$3"

  if ! grep -Fq -- "${pattern}" "${file}"; then
    echo "missing pattern '${pattern}': ${context}" >&2
    echo "--- ${file} ---" >&2
    cat "${file}" >&2
    echo "-------------" >&2
    exit 1
  fi
}

run_check() {
  local config_file="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local exit_code=0

  if PATH="${tmpdir}:$PATH" bash "${target_script}" "${config_file}" >"${stdout_file}" 2>"${stderr_file}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  return "${exit_code}"
}

write_fake_gh

cat >"${tmpdir}/valid.yml" <<'EOF'
central:
  reports:
    datastores:
      - artifact://kitsuyui/good/octocov-report
      - artifact://kitsuyui/paginated/octocov-report
      - artifact://kitsuyui/custom/custom-report
      - artifact://kitsuyui/good/octocov-report # duplicate should be ignored
EOF

stdout_file="${tmpdir}/stdout"
stderr_file="${tmpdir}/stderr"
if run_check "${tmpdir}/valid.yml" "${stdout_file}" "${stderr_file}"; then
  status=0
else
  status=$?
fi
assert_exit 0 "${status}" "valid config should succeed"
assert_contains "${stdout_file}" "found artifact://kitsuyui/good/octocov-report" "valid config reports non-expired artifacts"
assert_contains "${stdout_file}" "found artifact://kitsuyui/paginated/octocov-report" "valid config handles paginated API payloads"
assert_contains "${stdout_file}" "found artifact://kitsuyui/custom/custom-report" "valid config preserves custom artifact names"

cat >"${tmpdir}/invalid-datastore.yml" <<'EOF'
central:
  reports:
    datastores:
      - artifact://kitsuyui/good/octocov-report/extra
EOF

if run_check "${tmpdir}/invalid-datastore.yml" "${stdout_file}" "${stderr_file}"; then
  status=0
else
  status=$?
fi
assert_exit 1 "${status}" "unsupported datastore should fail"
assert_contains "${stdout_file}" "unsupported artifact datastore: artifact://kitsuyui/good/octocov-report/extra" "invalid datastore is reported"

cat >"${tmpdir}/missing-artifacts.yml" <<'EOF'
central:
  reports:
    datastores:
      - artifact://kitsuyui/expired/octocov-report
      - artifact://kitsuyui/fail/octocov-report
EOF

if run_check "${tmpdir}/missing-artifacts.yml" "${stdout_file}" "${stderr_file}"; then
  status=0
else
  status=$?
fi
assert_exit 1 "${status}" "expired or API-failed artifacts should fail"
assert_contains "${stdout_file}" "Missing octocov artifact::artifact://kitsuyui/expired/octocov-report is not available or all matching artifacts are expired" "expired artifacts are rejected"
assert_contains "${stdout_file}" "Cannot query octocov artifact::artifact://kitsuyui/fail/octocov-report: simulated gh failure" "gh API failures are surfaced"
assert_contains "${stdout_file}" "One or more octocov report artifacts are unavailable." "aggregate failure is emitted"

echo "check-octocov-artifacts smoke tests passed"
