#!/usr/bin/env bash
# Wait for CodeRabbit's next verdict (APPROVED or CHANGES_REQUESTED) on any of
# the given PRs, then print "#<pr> <STATE> <sha8>" lines and exit 0.
# A COMMENTED review is not a verdict: read it with pr-gate.sh. A clean full
# review can end COMMENTED with no approval; that prints "#<pr> FULL_REVIEW_DONE".
# usage: cr-watch.sh [--since <utc-iso>] <pr> [<pr>...]
# Run it in the background; it exits on the first verdict, or prints "timeout" after ~12 h.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
crq_require_config
R=$(crq_repo); BOT=$(crq_bot_re)
SINCE=$(crq_utc_now)
if [ "${1:-}" = --since ]; then SINCE=$2; shift 2; fi
INTERVAL=$(crq_get watch_interval_seconds 240)
for _ in $(seq 1 $((43200 / INTERVAL))); do
  found=0
  for p in "$@"; do
    r=$(gh api "repos/$R/pulls/$p/reviews" --paginate \
      -q "[.[]|select((.user.login|test(\"$BOT\")) and .submitted_at>\"$SINCE\" and (.state==\"APPROVED\" or .state==\"CHANGES_REQUESTED\"))]|last|select(.)|.state+\" \"+.commit_id[0:8]" 2>/dev/null)
    [ -n "$r" ] && { echo "#$p $r"; found=1; }
    d=$(gh api "repos/$R/issues/$p/comments" --paginate \
      -q "[.[]|select((.user.login|test(\"$BOT\")) and .updated_at>\"$SINCE\" and (.body|test(\"Full review finished\")))]|length" 2>/dev/null)
    [ "${d:-0}" -gt 0 ] 2>/dev/null && [ -z "$r" ] && { echo "#$p FULL_REVIEW_DONE"; found=1; }
  done
  [ "$found" = 1 ] && exit 0
  sleep "$INTERVAL"
done
echo timeout
