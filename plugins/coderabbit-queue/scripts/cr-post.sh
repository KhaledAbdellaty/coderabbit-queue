#!/usr/bin/env bash
# Ask CodeRabbit for a full review of ONE PR and confirm it really started.
# usage: cr-post.sh <pr>
# exit: 0 accepted · 3 held (conflicts with base) · 1 gave up after 3 attempts
#
# Lessons built in:
#  - never review a PR that conflicts with its base (the review is wasted once the merge changes it)
#  - CodeRabbit may post "review triggered" and later EDIT it into "rate limited"
#    or "Review failed": read the reply twice, minutes apart
#  - only read replies created after our post, across all pages
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
crq_require_config
R=$(crq_repo); N=$1; BOT=$(crq_bot_re)

for _ in 1 2 3 4 5 6; do
  S=$(gh pr view "$N" -R "$R" --json state -q .state 2>/dev/null)
  [ "$S" = MERGED ] || [ "$S" = CLOSED ] && { echo "SKIP #$N ($S)"; exit 3; }
  M=$(gh pr view "$N" -R "$R" --json mergeable -q .mergeable 2>/dev/null)
  [ -n "$M" ] && [ "$M" != UNKNOWN ] && break
  sleep 10
done
if [ "$M" = CONFLICTING ]; then
  crq_log "HELD #$N: conflicts with its base; merge the base in and resolve, then re-queue"
  exit 3
fi

# CodeRabbit already reviewed this exact commit (auto-review on open, or an earlier
# request): another full review would only spend a slot. Re-queue after the next push.
HEAD_SHA=$(gh pr view "$N" -R "$R" --json headRefOid -q .headRefOid 2>/dev/null)
if [ -n "$HEAD_SHA" ]; then
  DONE=$(gh api --paginate "repos/$R/pulls/$N/reviews" \
    -q "[.[]|select((.user.login|test(\"$BOT\")) and .commit_id==\"$HEAD_SHA\" and (.body|length)>0)]|length" 2>/dev/null \
    | awk '{s+=$1} END{print s+0}')
  if [ "${DONE:-0}" -gt 0 ]; then
    crq_log "SKIP #$N: CodeRabbit already reviewed head ${HEAD_SHA:0:8}; push a fix, then re-queue"
    exit 3
  fi
fi

replies() {
  gh api --paginate "repos/$R/issues/$N/comments?per_page=100" \
    --jq ".[]|select(.user.login|test(\"$BOT\"))|select(.created_at>\"$1\")|.body" 2>/dev/null
}

for attempt in 1 2 3; do
  S=$(crq_utc_now)
  until gh pr comment "$N" -R "$R" --body "@coderabbitai full review" >/dev/null 2>&1; do sleep 15; done
  crq_log "posted #$N (attempt $attempt)"
  until B=$(replies "$S") && [ -n "$B" ]; do sleep 15; done
  sleep 60
  for check in 1 2; do
    B=$(replies "$S")
    echo "$B" | grep -qi "rate limit\|not completed\|failed" && break
    if [ "$check" = 2 ] && echo "$B" | grep -qi "review triggered\|review finished\|Full review"; then
      crq_log "ACCEPTED #$N"
      exit 0
    fi
    sleep 120
  done
  if echo "$B" | grep -qi "failed"; then
    crq_log "#$N: CodeRabbit reported 'Review failed' (their side); retrying in 5 min"
    sleep 300
    continue
  fi
  W=$(echo "$B" | grep -o "available in [0-9]* [a-z]*" | head -1)
  n=$(echo "$W" | grep -o "[0-9]*")
  case "$W" in
    *minute*) wait=$((n * 60 + 20)) ;;
    *second*) wait=$((n + 20)) ;;
    *) wait=$(crq_get slot_seconds 3630) ;;
  esac
  next=$(date -u -d "+${wait} seconds" +%Y-%m-%dT%H:%M:%SZ)
  crq_log "#$N rate limited ($W); next try at $(crq_local "$next")"
  sleep "$wait"
done
crq_log "GAVE UP #$N"
exit 1
