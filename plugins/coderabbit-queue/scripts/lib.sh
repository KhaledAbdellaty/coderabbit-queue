#!/usr/bin/env bash
# Shared helpers for the coderabbit-queue scripts. Source it; don't run it.
# All times are computed in UTC and only *shown* in the configured timezone.

CRQ_HOME="${CRQ_HOME:-$HOME/.config/coderabbit-queue}"
mkdir -p "$CRQ_HOME"

# owner/repo: $CRQ_REPO, else the repo of the current directory.
crq_repo() {
  if [ -n "${CRQ_REPO:-}" ]; then echo "$CRQ_REPO"; return; fi
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null
}

crq_cfg() { echo "$CRQ_HOME/$(crq_repo | sed 's#/#__#').json"; }

# crq_get <key> [default]: one value from the repo config (written by cr-setup.sh).
crq_get() {
  python3 -I - "$(crq_cfg)" "$1" "${2:-}" <<'PY'
import json, sys
path, key, default = sys.argv[1:4]
try:
    value = json.load(open(path)).get(key)
except (OSError, ValueError):
    value = None
print(default if value is None else value)
PY
}

crq_require_config() {
  [ -f "$(crq_cfg)" ] && return 0
  echo "No config for $(crq_repo). Run cr-setup.sh first." >&2
  exit 2
}

crq_tz() { crq_get timezone "${TZ:-UTC}"; }
crq_utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# crq_local [utc-iso]: that instant (default now) in the configured timezone.
crq_local() { TZ="$(crq_tz)" date -d "${1:-now}" '+%Y-%m-%d %H:%M %Z'; }

crq_log() {
  local line
  line="[$(crq_local)] $*"
  echo "$line"
  echo "$line" >>"$CRQ_HOME/$(crq_repo | sed 's#/#__#').log"
}

# Regex for the reviewer bot's login as GitHub reports it in comments and reviews.
crq_bot_re() { crq_get bot_login_regex 'coderabbit'; }
