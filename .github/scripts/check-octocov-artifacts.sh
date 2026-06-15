#!/usr/bin/env bash
set -euo pipefail

config_file="${1:-.octocov.yml}"

if [[ ! -f "$config_file" ]]; then
  echo "::error file=${config_file}::octocov config not found"
  exit 1
fi

datastores=()
while IFS= read -r datastore; do
  datastores+=("$datastore")
done < <(
  sed -n 's/^[[:space:]]*-[[:space:]]*artifact:\/\/\([^[:space:]#][^#]*\).*$/\1/p' "$config_file" |
    sed 's/[[:space:]]*$//' |
    sort -u
)

if ((${#datastores[@]} == 0)); then
  echo "::error file=${config_file}::no artifact datastores found"
  exit 1
fi

error_log="$(mktemp)"
trap 'rm -f "$error_log"' EXIT

missing=0

for datastore in "${datastores[@]}"; do
  IFS=/ read -r owner repo artifact extra <<<"$datastore"

  if [[ -z "${owner:-}" || -z "${repo:-}" || -n "${extra:-}" ]]; then
    echo "::error file=${config_file}::unsupported artifact datastore: artifact://${datastore}"
    missing=1
    continue
  fi

  artifact="${artifact:-octocov-report}"
  : >"$error_log"

  if ! artifact_json="$(
    gh api --paginate --slurp -X GET "repos/${owner}/${repo}/actions/artifacts" \
      -f "name=${artifact}" \
      -f "per_page=100" \
      2>"$error_log"
  )"; then
    details="$(tr '\n' ' ' <"$error_log" | sed 's/[[:space:]]\+/ /g')"
    echo "::error title=Cannot query octocov artifact::artifact://${owner}/${repo}/${artifact}: ${details}"
    missing=1
    continue
  fi

  status="$(
    ARTIFACT_JSON="$artifact_json" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["ARTIFACT_JSON"])

pages = data if isinstance(data, list) else [data]
for page in pages:
    for artifact in page.get("artifacts", []):
        if not artifact.get("expired", False):
            print("ok")
            raise SystemExit

print("missing")
PY
  )"

  if [[ "$status" == "ok" ]]; then
    echo "found artifact://${owner}/${repo}/${artifact}"
  else
    echo "::error title=Missing octocov artifact::artifact://${owner}/${repo}/${artifact} is not available or all matching artifacts are expired"
    missing=1
  fi
done

if ((missing != 0)); then
  echo "::error::One or more octocov report artifacts are unavailable. Refusing to run octocov with a partial input set."
  exit 1
fi
