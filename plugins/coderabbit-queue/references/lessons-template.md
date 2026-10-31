# Review lessons

Every author reads this before each push, and the PR body lists it under
**"Review lessons checked"**. Add one line whenever a review teaches something new:
what happened, where (PR #), and the rule.

## Before queuing a review
- Run the local CodeRabbit CLI (`coderabbit review --agent`) on the final diff and fix its findings. Each CodeRabbit round costs a scarce slot.
- Push all fixes for a round at once; one push per review round.
- Merge the base branch in and resolve conflicts **before** queuing. A review of conflicting code is wasted.
- Run the FULL lint (`lint:check`) for every package you touched, not only your changed hunks.

## Before merging
- Read **every** CodeRabbit review on the head, including a COMMENTED review with "Follow-up Comments" or nitpicks posted seconds before the approval. An approval does not mean nothing is left.
- After merging a PR that changes a shared type or schema, type-check the base branch: two PRs can each pass alone and break together.

## Migrations
- Pick a migration timestamp only after listing every open PR's migrations. The same timestamp with different names runs in a different order on a fresh database than on an existing one.

## Tests
- A new test must fail on the old code. Prove it (revert the fix, or run a mutation) and say so in the PR.
- Flaky test seen? Record the test name and run; don't just rerun until green.

## Your project's lessons
- (add yours here)
