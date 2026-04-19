#!/usr/bin/env bash
# build-fleet.sh — builds public/fleet.json and per-repo summaries from dashboard-data.
#
# Expected working directory layout (set by dashboard-snapshot.yml before calling):
#   dashboard-data/   — checkout of the dashboard-data orphan branch
#   gh-pages/         — checkout of the gh-pages branch (output target)
#
# Outputs written:
#   gh-pages/public/fleet.json          — fleet-wide latest status, all repos
#   gh-pages/public/repos/{repo}.json   — per-repo summary + last 30 run records
#
# Usage:
#   bash source/src/snapshot/build-fleet.sh
#   (The GENERATED_AT env var may be pre-set to override the timestamp.)

set -euo pipefail

GENERATED_AT="${GENERATED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
mkdir -p gh-pages/public/repos

BRANCH_DIR="dashboard-data/data/branch"
PR_DIR="dashboard-data/data/pr"
RUNS_BASE="dashboard-data/data/runs"

# ── Fleet overview ──────────────────────────────────────────────────────────
# Build a de-duplicated set of all known repos (union of branch + pr dirs).
ALL_REPOS=$(
  {
    [ -d "$BRANCH_DIR" ] && find "$BRANCH_DIR" -name '*.json' -type f \
      | xargs -r basename -s .json || true
    [ -d "$PR_DIR"     ] && find "$PR_DIR"     -name '*.json' -type f \
      | xargs -r basename -s .json || true
  } | sort -u
)

REPOS_JSON='[]'

if [ -n "$ALL_REPOS" ]; then
  FLEET_ENTRIES=()
  while IFS= read -r REPO; do
    [ -z "$REPO" ] && continue
    BRANCH_FILE="${BRANCH_DIR}/${REPO}.json"
    PR_FILE="${PR_DIR}/${REPO}.json"

    # Branch (pr-to-branch or push) is authoritative; fall back to PR-time if absent.
    if [ -f "$BRANCH_FILE" ]; then
      ENTRY=$(jq -c '. + {"_source":"branch"}' "$BRANCH_FILE")
    elif [ -f "$PR_FILE" ]; then
      ENTRY=$(jq -c '. + {"_source":"pr"}' "$PR_FILE")
    else
      continue
    fi

    FLEET_ENTRIES+=("$ENTRY")
  done <<< "$ALL_REPOS"

  if [ ${#FLEET_ENTRIES[@]} -gt 0 ]; then
    REPOS_JSON=$(printf '%s\n' "${FLEET_ENTRIES[@]}" | jq -s 'sort_by(.repository)')
  fi
fi

jq -n \
  --arg generated_at "$GENERATED_AT" \
  --argjson repos     "$REPOS_JSON" \
  '{generated_at: $generated_at, repos: $repos}' \
  > gh-pages/public/fleet.json

REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length')
echo "::notice::Fleet snapshot: ${REPO_COUNT} repo(s) included."

# ── Per-repo summaries ──────────────────────────────────────────────────────
# Combine branch + PR latest records with the last 30 run records.
if [ -n "$ALL_REPOS" ]; then
  while IFS= read -r REPO; do
    [ -z "$REPO" ] && continue
    BRANCH_FILE="${BRANCH_DIR}/${REPO}.json"
    PR_FILE="${PR_DIR}/${REPO}.json"

    BRANCH_DATA="null"
    PR_DATA="null"
    [ -f "$BRANCH_FILE" ] && BRANCH_DATA=$(jq '.' "$BRANCH_FILE")
    [ -f "$PR_FILE"     ] && PR_DATA=$(jq '.'     "$PR_FILE")

    # Collect the last 30 run records for this repo, most-recent first.
    RECENT_RUNS='[]'
    if [ -d "${RUNS_BASE}/${REPO}" ]; then
      RECENT_RUNS=$(find "${RUNS_BASE}/${REPO}" -name '*.json' -type f | \
        sort -r | head -30 | xargs cat | jq -s 'sort_by(.timestamp) | reverse')
    fi

    jq -n \
      --arg generated_at "$GENERATED_AT" \
      --argjson branch   "$BRANCH_DATA" \
      --argjson pr       "$PR_DATA" \
      --argjson recent   "$RECENT_RUNS" \
      '{generated_at: $generated_at, branch: $branch, pr: $pr, recent_runs: $recent}' \
      > "gh-pages/public/repos/${REPO}.json"
  done <<< "$ALL_REPOS"
fi
