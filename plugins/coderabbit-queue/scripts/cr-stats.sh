#!/usr/bin/env bash
# Measure how CodeRabbit review slots are spent, per repo and base branch.
# usage: cr-stats.sh [--days N] [--base BRANCH]      (defaults: 7 days, all bases)
# Compare the same numbers before/after a config change, or across repos
# (run it in each repo, or set CRQ_REPO=owner/repo).
#
# Numbers (CodeRabbit reviews by the bot in the window, on PRs updated in the window):
#   reviews        review runs with a body (thread replies excluded) ~ what the allowance counts
#   prs            PRs that got at least one review
#   rounds/PR      reviews ÷ PRs                  (goal 1-2)
#   findings       sum of "Actionable comments posted: N"
#   rate-limited   "Review rate limited" replies  (wasted requests)
#   failed         "Review failed" replies
#   merged         PRs merged in the window, and median hours from creation to merge
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
R=$(crq_repo); DAYS=7; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
SINCE=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)
BOT=$(crq_bot_re)
Q="repo:$R is:pr updated:>=${SINCE%%T*}"
[ -n "$BASE" ] && Q="$Q base:$BASE"
PRS=$(gh api -X GET search/issues -f q="$Q" -f per_page=100 --paginate -q '.items[].number')

python3 -I - "$R" "$SINCE" "$BOT" "$DAYS" "${BASE:-all}" "$(crq_tz)" $PRS <<'PY'
import json, re, statistics, subprocess, sys, datetime
repo, since, bot, days, base, tz, *prs = sys.argv[1:]

def api(path):
    out = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True).stdout
    items = []
    for chunk in re.split(r"(?<=\])\s*(?=\[)", out.strip()) if out.strip() else []:
        items += json.loads(chunk)
    return items

reviews = findings = limited = failed = 0
reviewed_prs, merged_hours = set(), []
for n in prs:
    for rv in api(f"repos/{repo}/pulls/{n}/reviews?per_page=100"):
        # Thread replies are reviews with an empty body; they don't use the allowance.
        if (re.search(bot, rv["user"]["login"]) and (rv.get("submitted_at") or "") >= since
                and (rv.get("body") or "").strip()):
            reviews += 1; reviewed_prs.add(n)
            m = re.search(r"Actionable comments posted:\s*(\d+)", rv.get("body") or "")
            findings += int(m.group(1)) if m else 0
    for c in api(f"repos/{repo}/issues/{n}/comments?per_page=100"):
        if re.search(bot, c["user"]["login"]) and c["created_at"] >= since:
            body = c.get("body") or ""
            limited += bool(re.search(r"rate limited", body, re.I))
            failed += bool(re.search(r"review failed", body, re.I))
    pr = json.loads(subprocess.run(["gh", "api", f"repos/{repo}/pulls/{n}"], capture_output=True, text=True).stdout)
    if pr.get("merged_at") and pr["merged_at"] >= since:
        a = datetime.datetime.fromisoformat(pr["created_at"].replace("Z", "+00:00"))
        b = datetime.datetime.fromisoformat(pr["merged_at"].replace("Z", "+00:00"))
        merged_hours.append((b - a).total_seconds() / 3600)

rows = [
    ("window", f"last {days} days (since {since}, shown in {tz})"),
    ("repo / base", f"{repo} / {base}"),
    ("reviews", reviews),
    ("prs", len(reviewed_prs)),
    ("rounds/PR", round(reviews / len(reviewed_prs), 2) if reviewed_prs else "-"),
    ("findings", findings),
    ("rate-limited", limited),
    ("failed", failed),
    ("merged", len(merged_hours)),
    ("median h to merge", round(statistics.median(merged_hours), 1) if merged_hours else "-"),
]
for k, v in rows:
    print(f"  {k:18} {v}")
print("\nTeam plan steps down to 1 review/hour at about 70 reviews in 7 days "
      "(docs.coderabbit.ai/management/rate-limits).")
PY
