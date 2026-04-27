#!/usr/bin/env bash
# build-fleet.sh -- builds fleet.json by querying the GitHub Check Runs API for
# each tracked repo+branch pair defined in config/repos.json.
#
# For each repo+branch:
#   1. Finds the most recently updated open PR targeting that branch.
#   2. Falls back to the branch HEAD commit if no open PR exists.
#   3. Fetches all completed check runs for that commit SHA.
#   4. Derives pill keys dynamically from check run names (job part after " / ").
#      Check runs sharing the same pill key are merged (worst status wins).
#   5. Emits one fleet entry per repo+branch.
#
# Maturity is read from the GitHub org custom property named "maturity".
#
# Requires: GH_TOKEN with checks:read, pull_requests:read on all tracked repos,
#           and org custom properties read access (for maturity lookup).
#
# Input:  source/config/repos.json
# Output: gh-pages/public/fleet.json
#         gh-pages/public/repos/{name}@{branch}.json

set -euo pipefail

GENERATED_AT="${GENERATED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
REPOS_CONFIG="source/config/repos.json"
ORG="BuroHappoldEngineeringSandbox"

mkdir -p gh-pages/public/repos

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Map a GitHub check run conclusion to a dashboard status string.
conclusion_to_status() {
  case "$1" in
    success)                                          echo "success" ;;
    failure|timed_out|action_required|stale)          echo "failure" ;;
    cancelled)                                        echo "cancelled" ;;
    skipped|neutral)                                  echo "skipped" ;;
    *)                                                echo "unknown" ;;
  esac
}

# Return the worse of two status strings.
# Precedence: failure > cancelled > skipped > success > unknown
worse_status() {
  local a="$1" b="$2"
  for s in failure cancelled skipped success; do
    [[ "$a" == "$s" || "$b" == "$s" ]] && echo "$s" && return
  done
  echo "${a:-unknown}"
}

# Derive overall status from a jobs JSON object (values are {status,...} objects).
derive_overall() {
  local jobs_json="$1" s overall="unknown"
  while IFS= read -r s; do
    case "$s" in
      failure|cancelled) echo "failure"; return ;;
      success)           overall="success" ;;
    esac
  done < <(echo "$jobs_json" | jq -r '[to_entries[] | .value.status] | .[]')
  echo "$overall"
}

# Bulk-fetch org custom properties and build MATURITY_MAP: {"org/repo": "tier"}.
load_maturity_map() {
  MATURITY_MAP='{}'
  if [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning::GH_TOKEN not set -- maturity will default to 'prototype'."
    return
  fi
  local page=1 batch
  while true; do
    batch=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${ORG}/properties/values?per_page=100&page=${page}" \
      2>/dev/null || echo '[]')
    [ "$(echo "$batch" | jq 'length')" -eq 0 ] && break
    MATURITY_MAP=$(printf '%s\n%s' "$MATURITY_MAP" "$batch" | jq -s '
        .[0] as $map | .[1]
        | map({
            key:   .repository_full_name,
            value: (
              (.properties[] | select(.property_name == "maturity") | .value)
              // empty
            )
          })
        | from_entries
        | $map + .')
    (( page++ ))
  done
}

get_maturity() {
  echo "$MATURITY_MAP" | jq -r --arg r "$1" '.[$r] // "prototype"'
}

# Fetch the most recently updated open PR targeting $2 in repo $1.
# Outputs compact JSON {number, sha} or nothing if no open PR found.
get_latest_pr() {
  local repo="$1" branch="$2"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${repo}/pulls?state=open&base=${branch}&sort=updated&direction=desc&per_page=1" \
    2>/dev/null \
    | jq -c 'if length > 0 then .[0] | {number: .number, sha: .head.sha} else empty end' \
    || true
}

# Fetch the latest commit SHA on branch $2 in repo $1 (fallback, no open PR).
get_branch_sha() {
  local repo="$1" branch="$2"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${repo}/commits/${branch}?per_page=1" \
    2>/dev/null | jq -r '.sha // empty' || true
}

# Fetch all completed check runs for commit $2 in repo $1 (paginated).
get_check_runs() {
  local repo="$1" sha="$2" page=1 all='[]' batch
  while true; do
    batch=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${repo}/commits/${sha}/check-runs?per_page=100&page=${page}" \
      2>/dev/null \
      | jq '[.check_runs[] | select(.status == "completed")]' \
      || echo '[]')
    [ "$(echo "$batch" | jq 'length')" -eq 0 ] && break
    all=$(printf '%s\n%s' "$all" "$batch" | jq -s '.[0] + .[1]')
    (( page++ ))
  done
  echo "$all"
}

# Derive a short, stable pill key from a check run name.
# "CI Build / build"  -> "build"
# "some-check"        -> "some-check"
pill_key() {
  local name="$1"
  if [[ "$name" == *" / "* ]]; then
    echo "${name##* / }" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
  else
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//'
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

load_maturity_map

BRANCHES=$(jq -r '.branches[]' "$REPOS_CONFIG")
REPOS=$(jq -r '.repos[]'       "$REPOS_CONFIG")

FLEET_ENTRIES=()

for REPO in $REPOS; do
  for BRANCH in $BRANCHES; do
    echo "Processing ${REPO}@${BRANCH}..."

    # Prefer the latest open PR targeting this branch; fall back to branch HEAD.
    PR_INFO=$(get_latest_pr "$REPO" "$BRANCH")
    if [ -n "$PR_INFO" ]; then
      SHA=$(echo "$PR_INFO"       | jq -r '.sha')
      PR_NUMBER=$(echo "$PR_INFO" | jq -r '.number | tostring')
    else
      SHA=$(get_branch_sha "$REPO" "$BRANCH")
      PR_NUMBER=""
    fi

    if [ -z "${SHA:-}" ]; then
      echo "::warning::Cannot resolve SHA for ${REPO}@${BRANCH} -- skipping."
      continue
    fi

    CHECK_RUNS=$(get_check_runs "$REPO" "$SHA")

    if [ "$(echo "$CHECK_RUNS" | jq 'length')" -eq 0 ]; then
      echo "::notice::No completed check runs for ${REPO}@${BRANCH} (${SHA:0:7})."
    fi

    jobs_json='{}'

    while IFS= read -r run; do
      name=$(echo "$run"       | jq -r '.name        // ""')
      conclusion=$(echo "$run" | jq -r '.conclusion  // ""')
      completed=$(echo "$run"  | jq -r '.completed_at // ""')
      html_url=$(echo "$run"   | jq -r '.html_url    // ""')

      [ -z "$name" ] && continue

      pill=$(pill_key "$name")
      [ -z "$pill" ] && continue

      status=$(conclusion_to_status "$conclusion")

      existing_status=$(echo "$jobs_json" | jq -r --arg k "$pill" '.[$k].status    // "unknown"')
      existing_ts=$(echo "$jobs_json"     | jq -r --arg k "$pill" '.[$k].timestamp // ""')
      merged_status=$(worse_status "$existing_status" "$status")

      if [[ "$completed" > "$existing_ts" ]]; then
        merged_ts="$completed"
        merged_url="$html_url"
      else
        merged_ts="$existing_ts"
        merged_url=$(echo "$jobs_json" | jq -r --arg k "$pill" '.[$k].run_url // ""')
      fi

      jobs_json=$(echo "$jobs_json" | jq \
        --arg k "$pill" --arg s "$merged_status" --arg t "$merged_ts" --arg u "$merged_url" \
        '.[$k] = {status: $s, timestamp: $t, run_url: $u}')

    done < <(echo "$CHECK_RUNS" | jq -c '.[]')

    latest_ts=$(echo "$CHECK_RUNS" | jq -r '[.[].completed_at | select(. != null)] | sort | last // ""')
    overall=$(derive_overall "$jobs_json")
    maturity=$(get_maturity "$REPO")

    pr_url=""
    [ -n "$PR_NUMBER" ] && pr_url="https://github.com/${REPO}/pull/${PR_NUMBER}"

    FLEET_ENTRIES+=("$(jq -n \
      --arg  repository "$REPO" \
      --arg  ref        "$BRANCH" \
      --arg  sha        "$SHA" \
      --arg  pr_number  "$PR_NUMBER" \
      --arg  run_url    "$pr_url" \
      --arg  timestamp  "$latest_ts" \
      --arg  overall    "$overall" \
      --arg  maturity   "$maturity" \
      --argjson jobs    "$jobs_json" \
      '{
        repository: $repository,
        ref:        $ref,
        sha:        $sha,
        pr_number:  $pr_number,
        run_url:    $run_url,
        timestamp:  $timestamp,
        overall:    $overall,
        maturity:   $maturity,
        jobs:       $jobs
      }')")
  done
done

REPOS_JSON=$(printf '%s\n' "${FLEET_ENTRIES[@]}" | jq -s 'sort_by(.repository, .ref)')

jq -n \
  --arg    generated_at "$GENERATED_AT" \
  --argjson repos        "$REPOS_JSON" \
  '{generated_at: $generated_at, repos: $repos}' \
  > gh-pages/public/fleet.json

echo "::notice::Fleet snapshot: ${#FLEET_ENTRIES[@]} entries built."

# ---------------------------------------------------------------------------
# Per-repo summaries
# ---------------------------------------------------------------------------

for REPO in $REPOS; do
  REPO_NAME="${REPO##*/}"
  for BRANCH in $BRANCHES; do
    ENTRY=$(echo "$REPOS_JSON" | jq -c \
      --arg r "$REPO" --arg b "$BRANCH" \
      '.[] | select(.repository == $r and .ref == $b)')
    [ -z "$ENTRY" ] && continue
    jq -n \
      --arg    generated_at "$GENERATED_AT" \
      --argjson entry        "$ENTRY" \
      '{generated_at: $generated_at, latest: $entry}' \
      > "gh-pages/public/repos/${REPO_NAME}@${BRANCH}.json"
  done
done
