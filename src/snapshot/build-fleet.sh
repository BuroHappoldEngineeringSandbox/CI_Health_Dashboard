#!/usr/bin/env bash
# build-fleet.sh — aggregates per-workflow health records into fleet.json and
# per-repo summaries for the CI Health Dashboard.
#
# Input (on the dashboard-data branch):
#   data/latest/{repo}/{workflow}.json  — latest per-workflow record for each repo
#   data/runs/{repo}/{YYYY}/{MM}/       — full run history per repo
#   (working dir must contain dashboard-data/ and gh-pages/ subdirs)
#
# Maturity tiers are read from GitHub Custom Properties (org-level property named
# "maturity"). Repos without the property set default to "prototype".
# Requires GH_TOKEN env var with org custom property read access.
#
# Outputs written to gh-pages/public/:
#   fleet.json              — fleet-wide aggregated status, all known repos
#   repos/{repo}.json       — per-repo summary + last 30 run records
#
# Workflow → pill mapping:
#   ci-format                                         → format
#   ci-{code,copyright,documentation,project}-compliance → compliance (worst wins)
#   ci-dataset-compliance                             → dataset
#   ci-build                                          → build
#   ci-unit-tests                                     → unit-tests
#
# Status precedence (worst wins): failure > cancelled > skipped > success > unknown

set -euo pipefail

GENERATED_AT="${GENERATED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
mkdir -p gh-pages/public/repos

LATEST_DIR="dashboard-data/data/latest"
RUNS_BASE="dashboard-data/data/runs"
ORG="BuroHappoldEngineeringSandbox"

# ── Helpers ─────────────────────────────────────────────────────────────────

# Map a workflow filename (without .json) to a pill key.
workflow_to_pill() {
  case "$1" in
    ci-format)                   echo "format" ;;
    ci-code-compliance|\
    ci-copyright-compliance|\
    ci-documentation-compliance|\
    ci-project-compliance)       echo "compliance" ;;
    ci-dataset-compliance)       echo "dataset" ;;
    ci-build)                    echo "build" ;;
    ci-unit-tests)               echo "unit-tests" ;;
    *)                           echo "" ;;
  esac
}

# Return the worse of two status strings.
# Precedence: failure > cancelled > skipped > success > (anything else = unknown)
worse_status() {
  local a="$1" b="$2"
  for s in failure cancelled skipped success; do
    if [ "$a" = "$s" ] || [ "$b" = "$s" ]; then echo "$s"; return; fi
  done
  echo "${a:-unknown}"
}

# Derive overall from a jobs JSON object (jobs values are now {status, timestamp} objects).
# failure if any job failed/cancelled; success if all are success; otherwise unknown.
derive_overall() {
  local jobs_json="$1"
  if echo "$jobs_json" | jq -e 'to_entries[] | select(.value.status == "failure")' > /dev/null 2>&1; then
    echo "failure"; return
  fi
  if echo "$jobs_json" | jq -e 'to_entries[] | select(.value.status == "cancelled")' > /dev/null 2>&1; then
    echo "failure"; return
  fi
  if echo "$jobs_json" | jq -e '[to_entries[] | .value.status] | all(. == "success")' | grep -q true; then
    echo "success"; return
  fi
  echo "unknown"
}

# Fetch all custom property values for the org in one paginated bulk call.
# Builds a JSON object: { "org/repo": "tier", ... } stored in MATURITY_MAP.
load_maturity_map() {
  MATURITY_MAP='{}'
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning::GH_TOKEN not set — maturity will default to 'prototype' for all repos."
    return
  fi

  local page=1 per_page=100 batch
  while true; do
    batch=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${ORG}/properties/values?per_page=${per_page}&page=${page}" \
      2>/dev/null || echo '[]')

    # Stop if no more results.
    [ "$(echo "$batch" | jq 'length')" -eq 0 ] && break

    # Extract repos that have a "maturity" property and merge into MATURITY_MAP.
    MATURITY_MAP=$(echo "$MATURITY_MAP" \
      "$batch" \
      | jq -s '
          .[0] as $map |
          .[1]
          | map({
              key: .repository_full_name,
              value: (.properties[] | select(.property_name == "maturity") | .value) // empty
            })
          | from_entries
          | $map + .
        ')

    (( page++ ))
  done
}

# Look up maturity for an org/repo string from the pre-loaded MATURITY_MAP.
get_maturity() {
  local repository="$1"
  echo "$MATURITY_MAP" | jq -r --arg r "$repository" '.[$r] // "prototype"'
}

# ── Discover repos ───────────────────────────────────────────────────────────

ALL_REPOS=()
if [ -d "$LATEST_DIR" ]; then
  while IFS= read -r -d '' dir; do
    ALL_REPOS+=("$(basename "$dir")")
  done < <(find "$LATEST_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

if [ ${#ALL_REPOS[@]} -eq 0 ]; then
  echo "::notice::No repos found in data/latest/ — writing empty fleet."
  jq -n --arg g "$GENERATED_AT" '{generated_at: $g, repos: []}' > gh-pages/public/fleet.json
  exit 0
fi
# Load maturity from GitHub Custom Properties (one bulk API call for the whole org).
load_maturity_map
# ── Build fleet entries ──────────────────────────────────────────────────────

FLEET_ENTRIES=()

for REPO in "${ALL_REPOS[@]}"; do
  REPO_DIR="${LATEST_DIR}/${REPO}"
  [ -d "$REPO_DIR" ] || continue

  jobs_json='{}'
  latest_timestamp=""
  latest_run_url=""
  latest_ref=""
  latest_sha=""
  latest_trigger=""
  latest_pr_number=""
  repository=""

  # Read each workflow file and accumulate job results.
  while IFS= read -r -d '' wf_file; do
    wf_name=$(basename "$wf_file" .json)
    pill=$(workflow_to_pill "$wf_name")
    [ -z "$pill" ] && continue

    record=$(jq '.' "$wf_file")
    status=$(echo "$record"  | jq -r '.status // "unknown"')
    ts=$(echo "$record"      | jq -r '.timestamp // ""')
    run_url=$(echo "$record" | jq -r '.run_url // ""')
    ref=$(echo "$record"     | jq -r '.ref // ""')
    sha=$(echo "$record"     | jq -r '.sha // ""')
    trigger=$(echo "$record" | jq -r '.trigger // ""')
    pr_num=$(echo "$record"  | jq -r '.pr_number // ""')
    repo_full=$(echo "$record" | jq -r '.repository // ""')

    # For compliance: aggregate multiple workflows into one pill (worst status wins).
    # Preserve the timestamp of the most recently run compliance workflow.
    if [ "$pill" = "compliance" ]; then
      existing_status=$(echo "$jobs_json" | jq -r '.compliance.status // "unknown"')
      existing_ts=$(echo "$jobs_json"     | jq -r '.compliance.timestamp // ""')
      merged=$(worse_status "$existing_status" "$status")
      # Keep whichever timestamp is more recent.
      if [[ "$ts" > "$existing_ts" ]]; then
        merged_ts="$ts"
      else
        merged_ts="$existing_ts"
      fi
      jobs_json=$(echo "$jobs_json" | jq \
        --arg s "$merged" --arg t "$merged_ts" \
        '.compliance = {status: $s, timestamp: $t}')
    else
      jobs_json=$(echo "$jobs_json" | jq \
        --arg k "$pill" --arg s "$status" --arg t "$ts" \
        '.[$k] = {status: $s, timestamp: $t}')
    fi

    # Track the most recent record's metadata for the card header.
    if [ -z "$latest_timestamp" ] || [[ "$ts" > "$latest_timestamp" ]]; then
      latest_timestamp="$ts"
      latest_run_url="$run_url"
      latest_ref="$ref"
      latest_sha="$sha"
      latest_trigger="$trigger"
      latest_pr_number="$pr_num"
      repository="$repo_full"
    fi
  done < <(find "$REPO_DIR" -name '*.json' -type f -print0 | sort -z)

  [ -z "$repository" ] && repository="unknown/${REPO}"

  overall=$(derive_overall "$jobs_json")
  maturity=$(get_maturity "$repository")

  FLEET_ENTRIES+=("$(jq -n \
    --arg  repository  "$repository" \
    --arg  ref         "$latest_ref" \
    --arg  sha         "$latest_sha" \
    --arg  trigger     "$latest_trigger" \
    --arg  pr_number   "$latest_pr_number" \
    --arg  run_url     "$latest_run_url" \
    --arg  timestamp   "$latest_timestamp" \
    --arg  overall     "$overall" \
    --arg  maturity    "$maturity" \
    --argjson jobs     "$jobs_json" \
    '{
      repository: $repository,
      ref:        $ref,
      sha:        $sha,
      trigger:    $trigger,
      pr_number:  $pr_number,
      run_url:    $run_url,
      timestamp:  $timestamp,
      overall:    $overall,
      maturity:   $maturity,
      jobs:       $jobs
    }')")
done

REPOS_JSON=$(printf '%s\n' "${FLEET_ENTRIES[@]}" | jq -s 'sort_by(.repository)')

jq -n \
  --arg generated_at "$GENERATED_AT" \
  --argjson repos     "$REPOS_JSON" \
  '{generated_at: $generated_at, repos: $repos}' \
  > gh-pages/public/fleet.json

echo "::notice::Fleet snapshot: ${#FLEET_ENTRIES[@]} repo(s)."

# ── Per-repo summaries ───────────────────────────────────────────────────────

for REPO in "${ALL_REPOS[@]}"; do
  REPO_DIR="${LATEST_DIR}/${REPO}"
  [ -d "$REPO_DIR" ] || continue

  # Find the fleet entry for this repo.
  REPO_ENTRY=$(echo "$REPOS_JSON" | jq --arg r "$REPO" '.[] | select(.repository | endswith("/" + $r))')

  # Last 30 run records (all workflows combined), most-recent first.
  RECENT_RUNS='[]'
  if [ -d "${RUNS_BASE}/${REPO}" ]; then
    RECENT_RUNS=$(find "${RUNS_BASE}/${REPO}" -name '*.json' -type f | \
      sort -r | head -30 | xargs cat | jq -s 'sort_by(.timestamp) | reverse')
  fi

  jq -n \
    --arg  generated_at "$GENERATED_AT" \
    --argjson entry     "${REPO_ENTRY:-null}" \
    --argjson recent    "$RECENT_RUNS" \
    '{generated_at: $generated_at, latest: $entry, recent_runs: $recent}' \
    > "gh-pages/public/repos/${REPO}.json"
done

