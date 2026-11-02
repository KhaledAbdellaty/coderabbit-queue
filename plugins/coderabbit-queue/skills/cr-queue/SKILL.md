---
name: cr-queue
description: Queue CodeRabbit "@coderabbitai full review" requests for one or more pull requests, one at a time under the rate limit, and watch for the verdict. Use when PRs are ready for CodeRabbit review, when a fixed PR must be re-reviewed, or when the user asks to queue/re-queue reviews or check on the review queue.
---

# cr-queue — queue CodeRabbit reviews and wait for verdicts

Requires the repo config from **cr-setup** (run it first if `cr-serial.sh` says "No config").

## Before queuing a PR (checklist)

1. **No conflicts with its base.** If the PR conflicts, have its author merge the base in (a merge commit; never force-push) and push first. The script also refuses to post on a conflicting PR.
2. The author ran the local CodeRabbit CLI (`coderabbit review --agent`) and fixed its findings — every round costs a scarce slot.
3. All fixes for the round are in **one** push.

## Queue

Run in the background — it can take hours:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-serial.sh" 482 481 485
```

- One request at a time per repo, across every caller on the machine (flock).
- Posts `@coderabbitai full review` (never plain `review`: it skips already-reviewed commits).
- Confirms CodeRabbit really started: it re-reads the reply twice, minutes apart, because CodeRabbit edits "review triggered" into "rate limited" or "Review failed".
- Rate limited → waits exactly as long as CodeRabbit says, then retries. "Review failed" → retries after 5 min.
- Skips PRs merged/closed while waiting, and PRs whose current commit CodeRabbit already reviewed (e.g. the automatic review when a PR opens); **holds and skips** PRs that conflict (log line `SKIP #N (held: conflicts…)`) — re-queue them after the conflict is resolved.
- Log: `~/.config/coderabbit-queue/<owner>__<repo>.log`, times in the configured timezone.

Re-queue a PR after a fix push simply by running `cr-serial.sh <pr>` again. Don't start a second queue job for a PR that is already queued.

## Watch for the verdict

Also in the background:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-watch.sh" 482 481 485
```

It exits on the first `APPROVED` or `CHANGES_REQUESTED` (printing `#<pr> <STATE> <sha8>`). Then hand over to **cr-merge-gate**, and restart the watcher for the PRs still waiting. A `COMMENTED` review is not a verdict.

## Never

- Post several PRs at once to "save time" — they all hit the per-developer limit.
- Edit a queue script in place while a queue job is running (bash reads scripts lazily). Replace it by writing a temp file and `mv`.
- Enable usage-based billing or change the CodeRabbit plan — that is the owner's decision.
