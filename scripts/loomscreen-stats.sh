#!/usr/bin/env bash
# Quick analytics dashboard for the Loomscreen public repo.
# Usage: ./scripts/loomscreen-stats.sh
#        (or alias loomstats=./scripts/loomscreen-stats.sh)
#
# Requires: gh CLI, authenticated as the repo owner (push permission).
# Notes:
#   - Stars / forks / watchers / release download counts are real-time.
#   - Traffic (views, clones, referrers, paths) is a rolling 14-day
#     window aggregated server-side with a 12–24 h delay.
#
set -euo pipefail
REPO="${LOOMSCREEN_REPO:-Paradox07127/Loomscreen}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

bold "=== $REPO ==="

bold "⭐ Engagement (real-time)"
gh repo view "$REPO" --json stargazerCount,forkCount,watchers,hasDiscussionsEnabled \
  --jq '"  stars=\(.stargazerCount)  forks=\(.forkCount)  watchers=\(.watchers.totalCount)  discussions=\(.hasDiscussionsEnabled)"'
echo

bold "📦 Release downloads (cumulative since publish)"
gh api "repos/$REPO/releases?per_page=10" \
  --jq '.[] | "  \(.tag_name) — published \(.published_at[0:10])\n" + (.assets[] | "    \(.download_count)  \(.name)") '
echo

bold "📈 Traffic — rolling 14 days (~12–24 h delay)"
gh api "repos/$REPO/traffic/views" \
  --jq '"  views:  total=\(.count)  uniques=\(.uniques)"'
gh api "repos/$REPO/traffic/clones" \
  --jq '"  clones: total=\(.count)  uniques=\(.uniques)"'
echo

bold "🔗 Top referrers (14 d)"
gh api "repos/$REPO/traffic/popular/referrers" \
  --jq '.[] | "  \(.count) (\(.uniques) unique)  ← \(.referrer)"' || dim "  (none yet)"
echo

bold "📄 Top viewed paths (14 d)"
gh api "repos/$REPO/traffic/popular/paths" \
  --jq '.[] | "  \(.count) (\(.uniques) unique)  \(.path)"' | head -10 || dim "  (none yet)"
