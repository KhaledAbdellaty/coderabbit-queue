---
name: cr-setup
description: Initialize the CodeRabbit review queue for the current GitHub repo — detects the GitHub user, base branch, CodeRabbit plan, the per-hour review allowance (including fair-usage step-downs), seat problems and the machine timezone, and writes the config the other coderabbit-queue skills read. Use before the first queued review in a repo, when reviews keep getting rate-limited at a different pace than expected, or when the user asks what CodeRabbit plan/allowance they have.
---

# cr-setup — initialize the review queue

Run once per repository, and again whenever CodeRabbit's limits seem to have changed.

## Run it

From inside the repository (or with `CRQ_REPO=owner/repo`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-setup.sh"
```

Options:

| Option | Use |
|---|---|
| `--rph N` | Force reviews per hour (overrides detection) |
| `--base BRANCH` | Record a base branch other than the default |
| `--tz Area/City` | Override the detected timezone |
| `--probe <pr>` | Post `@coderabbitai rate limit` on that PR to read the live allowance. **This writes a PR comment — ask the user first.** |

It writes `~/.config/coderabbit-queue/<owner>__<repo>.json` and prints every value.

## How it detects things (tell the user these limits)

CodeRabbit has **no public API for plan or seats**. The script reads CodeRabbit's own words from the repo's 15 most recent PRs:

- **Plan**: the `Plan: <name>` line in a review's "Run configuration".
- **Allowance**: "Included review availability … allowance at N review(s) per hour" and "N included reviews remain". This reflects the *current* rate after fair-usage step-downs, so it beats the plan default.
- **Seat problems**: any "not assigned a seat" notice.
- If nothing is found, it falls back to the documented caps (Essentials 5/h, Team 8/h, Advanced 10/h, Enterprise 12/h) and, for an unknown plan, a safe 1/h.

`slot_seconds` = 3600 ÷ reviews-per-hour + 30 s is the queue's default wait.

## Time

All logic is in **UTC**; the configured timezone is only used to show times ("next slot 23:47 EET"). Never compare local clock times.

## After running

Report to the user: plan, reviews per hour and its source, remaining included reviews, any seat warning, and the timezone. If the allowance is 1/hour, mention that CodeRabbit's usage-based billing can lift it (an owner cost decision — don't enable anything yourself).
