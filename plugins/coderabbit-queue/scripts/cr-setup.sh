#!/usr/bin/env bash
# Detect who you are, the repo, CodeRabbit's plan and review allowance, seat
# problems and the machine timezone; write ~/.config/coderabbit-queue/<owner>__<repo>.json.
# usage: cr-setup.sh [--probe <pr>] [--rph N] [--base BRANCH] [--tz Area/City]
#   --probe <pr>  post "@coderabbitai rate limit" on that PR to read the live allowance
#                 (this writes one PR comment; off by default)
#   --rph N       force reviews-per-hour (overrides detection)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

PROBE="" RPH="" BASE="" TZ_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --probe) PROBE=$2; shift 2 ;;
    --rph) RPH=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --tz) TZ_OVERRIDE=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: run 'gh auth login'" >&2; exit 2; }
REPO=$(crq_repo)
[ -n "$REPO" ] || { echo "Not in a GitHub repo; set CRQ_REPO=owner/repo" >&2; exit 2; }
USER_LOGIN=$(gh api user -q .login)
[ -n "$BASE" ] || BASE=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)

TZONE=$TZ_OVERRIDE
[ -n "$TZONE" ] || TZONE=$(timedatectl show -p Timezone --value 2>/dev/null || true)
[ -n "$TZONE" ] || TZONE=$(cat /etc/timezone 2>/dev/null || true)
[ -n "$TZONE" ] || TZONE=${TZ:-UTC}

CLI="not installed"
if command -v coderabbit >/dev/null; then
  CLI="$(coderabbit --version 2>/dev/null | head -1)"
  coderabbit auth status >/dev/null 2>&1 || CLI="$CLI (not authenticated: run 'coderabbit auth login')"
fi

if [ -n "$PROBE" ]; then
  gh pr comment "$PROBE" -R "$REPO" --body "@coderabbitai rate limit" >/dev/null && sleep 60
fi

# CodeRabbit has no public plan/seat API: read its own words from recent PRs.
# Review bodies carry "Plan: <name>" and "Included review availability"; issue
# comments carry rate-limit and seat notices.
PRS=$(gh pr list -R "$REPO" --state all --limit 15 --json number -q '.[].number')
TEXT=""
for p in $PRS; do
  TEXT+=$(gh api "repos/$REPO/pulls/$p/reviews" --paginate \
    --jq '.[]|select(.user.login|test("coderabbit"))|.submitted_at+" "+.body' 2>/dev/null)$'\n'
  TEXT+=$(gh api "repos/$REPO/issues/$p/comments" --paginate \
    --jq '.[]|select(.user.login|test("coderabbit"))|.created_at+" "+.body' 2>/dev/null)$'\n'
done

TEXT_FILE=$(mktemp); trap 'rm -f "$TEXT_FILE"' EXIT
printf '%s' "$TEXT" >"$TEXT_FILE"
python3 -I - "$(crq_cfg)" "$REPO" "$BASE" "$USER_LOGIN" "$TZONE" "$CLI" "${RPH:-}" "$TEXT_FILE" <<'PY'
import json, math, re, sys, datetime
cfg, repo, base, user, tz, cli, rph_override, text_file = sys.argv[1:9]
text = open(text_file, encoding="utf-8", errors="replace").read()

def last(pattern):
    found = re.findall(pattern, text, re.I)
    return found[-1] if found else None

plan = last(r"\*\*Plan\*\*:\s*([A-Za-z+ ]+?)\s*(?:\n|$)")
allowance = last(r"allowance at (\d+) reviews? per hour")
remaining = last(r"(\d+) included reviews? remain")
seat_problem = bool(re.search(r"not (?:been )?assigned a seat|seat (?:is )?not assigned|no seat", text, re.I))

# Documented full-rate caps (docs.coderabbit.ai/management/rate-limits); they
# step down to 1/hour with heavy 7-day use, so a detected allowance wins.
defaults = {"essentials": 5, "team": 8, "advanced": 10, "enterprise": 12}
if rph_override:
    rph, source = int(rph_override), "--rph override"
elif allowance:
    rph, source = int(allowance), "CodeRabbit 'Included review availability'"
elif plan and plan.strip().lower() in defaults:
    rph, source = defaults[plan.strip().lower()], "documented cap for plan"
else:
    rph, source = 1, "unknown plan: conservative default"

conf = {
    "repo": repo,
    "base": base,
    "user": user,
    "timezone": tz,
    "coderabbit_cli": cli,
    "plan": (plan or "unknown").strip(),
    "reviews_per_hour": rph,
    "reviews_per_hour_source": source,
    "included_reviews_remaining": int(remaining) if remaining else None,
    "seat_problem_seen": seat_problem,
    "slot_seconds": math.ceil(3600 / max(rph, 1)) + 30,
    "bot_login_regex": "coderabbit",
    "watch_interval_seconds": 240,
    "detected_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
json.dump(conf, open(cfg, "w"), indent=2)
for k, v in conf.items():
    print(f"  {k:28} {v}")
print(f"\nwrote {cfg}")
PY

[ "$(crq_get seat_problem_seen)" = True ] &&
  echo "WARNING: CodeRabbit reported a seat problem on a recent PR; check seat assignment in CodeRabbit." >&2
exit 0
