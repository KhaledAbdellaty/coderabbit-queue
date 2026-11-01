#!/usr/bin/env bash
# Pre-merge gate: is this PR really clean to merge on CodeRabbit's approval?
# usage: pr-gate.sh <pr>
# exit 0 = CLEAN (merge on the printed head sha) · 1 = BLOCKED (reasons printed)
#
# An APPROVED review alone is not enough. Checked on the CURRENT head:
#  1. CodeRabbit's latest verdict on this head is APPROVED
#  2. no review on this head carries actionable comments, nitpicks or
#     "Follow-up Comments" (a COMMENTED review can land seconds before the approval)
#  3. no unresolved CodeRabbit review thread
#  4. no CodeRabbit comment after the approval saying a review failed or more is coming
#  5. the PR merges cleanly into its base
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
crq_require_config
R=$(crq_repo); N=$1; BOT=$(crq_bot_re)
OWNER=${R%/*}; NAME=${R#*/}
blocked=()
# Fail closed: a GitHub call that still fails after retries must never read as
# "nothing found". Calls run in $(...) subshells, so the failure is a flag file.
GH_FAILED=$(mktemp); trap 'rm -f "$GH_FAILED"' EXIT
gh() {
  local out i
  for i in 1 2 3 4; do
    if out=$(command gh "$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
    sleep 10
  done
  echo "gh $1 $2" >> "$GH_FAILED"; return 1
}

HEAD=$(gh pr view "$N" -R "$R" --json headRefOid -q .headRefOid)
STATE=$(gh pr view "$N" -R "$R" --json state -q .state)
echo "PR #$N head $HEAD ($STATE)"
[ "$STATE" = OPEN ] || blocked+=("PR is $STATE, nothing to merge")

REVIEWS=$(gh api "repos/$R/pulls/$N/reviews" --paginate \
  -q ".[]|select((.user.login|test(\"$BOT\")) and .commit_id==\"$HEAD\")|[.submitted_at,.state,(.body|gsub(\"\\n\";\" \"))]|@tsv")
VERDICT=$(printf '%s\n' "$REVIEWS" | awk -F'\t' '$2=="APPROVED"||$2=="CHANGES_REQUESTED"' | sort | tail -1)
APPROVED_AT=$(printf '%s' "$VERDICT" | cut -f1)
case "$(printf '%s' "$VERDICT" | cut -f2)" in
  APPROVED) echo "  verdict: APPROVED at $(crq_local "$APPROVED_AT")" ;;
  CHANGES_REQUESTED) blocked+=("latest verdict on this head is CHANGES_REQUESTED") ;;
  *) blocked+=("no APPROVED/CHANGES_REQUESTED verdict on this head yet") ;;
esac

while IFS=$'\t' read -r at state body; do
  [ -n "$at" ] || continue
  notes=$(printf '%s' "$body" | grep -oE "Actionable comments posted: [1-9][0-9]*|Nitpick comments:? \(?[1-9][0-9]*\)?|Follow-up Comments|Outside diff range comments:? \(?[1-9][0-9]*\)?" | sort -u | paste -sd ',' -)
  echo "  review $(crq_local "$at") $state ${notes:-(no notes)}"
  [ -n "$notes" ] && blocked+=("$state review at $(crq_local "$at") has: $notes")
done <<<"$REVIEWS"

UNRESOLVED=$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F n="$N" -f query='
  query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){
    reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{path author{login}}}}}}}}' \
  -q ".data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false and (.comments.nodes[0].author.login|test(\"$BOT\")))|.comments.nodes[0].path")
[ -n "$UNRESOLVED" ] && blocked+=("unresolved CodeRabbit threads: $(echo "$UNRESOLVED" | sort -u | paste -sd ',' -)")

if [ -n "$APPROVED_AT" ]; then
  LATE=$(gh api --paginate "repos/$R/issues/$N/comments?per_page=100" \
    -q ".[]|select((.user.login|test(\"$BOT\")) and .created_at>\"$APPROVED_AT\")|.body" |
    grep -iE "review failed|follow-up|actionable" | head -3)
  [ -n "$LATE" ] && blocked+=("CodeRabbit commented after the approval: ${LATE:0:160}")
fi

for _ in 1 2 3 4 5 6; do
  M=$(gh pr view "$N" -R "$R" --json mergeable -q .mergeable)
  [ "$M" != UNKNOWN ] && break
  sleep 5
done
[ "$STATE" != OPEN ] || [ "$M" = MERGEABLE ] || blocked+=("mergeable=$M (resolve conflicts with the base first)")

[ -s "$GH_FAILED" ] && blocked+=("GitHub calls failed after retries ($(paste -sd ', ' "$GH_FAILED")): re-run the gate")
if [ ${#blocked[@]} -eq 0 ]; then
  echo "CLEAN: merge with"
  echo "  gh api -X PUT repos/$R/pulls/$N/merge -f merge_method=squash -f sha=$HEAD"
  exit 0
fi
echo "BLOCKED:"
printf '  - %s\n' "${blocked[@]}"
exit 1
