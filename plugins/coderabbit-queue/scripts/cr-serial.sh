#!/usr/bin/env bash
# Queue CodeRabbit full reviews one PR at a time, in order, across every
# caller on this machine (a per-repo flock). Parallel requests all hit the
# per-developer rate limit together and waste attempts.
# usage: cr-serial.sh <pr> [<pr>...]
#
# - a PR merged or closed while it waited is skipped (no slot spent)
# - a PR that conflicts with its base is held and skipped, so it never blocks the queue
#
# Update this file only by writing a temp file and `mv` over it: a running bash
# reads its script lazily, so editing in place corrupts queues already running.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
crq_require_config
R=$(crq_repo)
exec 9>"$CRQ_HOME/$(echo "$R" | sed 's#/#__#').lock"
flock 9
# A failed gh call is not "closed": retry, and only MERGED/CLOSED counts as not open.
is_open() {
  local s i
  for i in 1 2 3 4 5; do
    s=$(gh pr view "$1" -R "$R" --json state -q .state 2>/dev/null)
    [ -n "$s" ] && break
    sleep 15
  done
  [ "$s" != MERGED ] && [ "$s" != CLOSED ]
}
for p in "$@"; do
  rc=1
  until ! is_open "$p"; do
    bash "$HERE/cr-post.sh" "$p"; rc=$?
    { [ "$rc" = 0 ] || [ "$rc" = 3 ]; } && break
    sleep "$(crq_get slot_seconds 3630)"
  done
  is_open "$p" || crq_log "SKIP #$p (not open)"
  [ "$rc" = 3 ] && crq_log "SKIP #$p (held: conflicts; re-queue after resolving)"
done
crq_log "SERIAL DONE $*"
