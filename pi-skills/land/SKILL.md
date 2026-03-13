---
name: land
description: Monitor and land a PR. Use when the issue is in Human Review (poll for feedback) or Merging state (wait for CI and squash-merge).
---

# Land

## Human Review

When the issue is in `Human Review`, run `pr_watch.py`. It blocks until feedback arrives. Do not poll manually.

On exit 2 (review feedback detected): move the item to `Rework` and address the feedback.

## Merging

- Ensure the PR is conflict-free with main.
- Keep CI green and fix failures when they occur.
- Squash-merge the PR once checks pass.
- Do not yield until the PR is merged; keep the watcher loop running unless blocked.
- No need to delete remote branches after merge; the repo auto-deletes head branches.

## Preconditions

- `gh` CLI is authenticated (`GH_TOKEN` is set in the environment).
- You are on the PR branch with a clean working tree.

## Steps

1. Locate the PR for the current branch.
2. Confirm the working tree is clean; commit and push any pending changes first.
3. Check mergeability and conflicts against main.
4. If conflicts exist, fetch and merge `origin/main`, resolve conflicts, commit, and push.
5. Watch CI checks until complete.
6. If checks fail, pull logs, fix the issue, commit, push, and re-watch.
7. When all checks are green, squash-merge using the PR title/body.
8. Move the project item to `Done`.

## Async Watch Helper

Preferred: use the asyncio watcher to monitor CI and head updates in parallel:

```bash
python3 "$(dirname "$0")/pr_watch.py"
```

Exit codes:

- 2: Blocking review comments detected (address feedback before merge)
- 3: CI checks failed
- 4: PR head updated (pull and retrigger CI)
- 5: Merge conflicts detected (resolve and push)

## Commands

```bash
# Locate PR for current branch
branch=$(git branch --show-current)
pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)

# Check mergeability
mergeable=$(gh pr view --json mergeable -q .mergeable)
# If CONFLICTING: fetch + merge origin/main, resolve, push
if [ "$mergeable" = "CONFLICTING" ]; then
  git fetch origin
  git merge origin/main
  git add -A && git commit -m "chore: merge origin/main"
  git push
fi

# Preferred: use the async watch helper (handles CI + head monitor in parallel)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SKILL_DIR/pr_watch.py"
# Exit 0 = all checks passed, safe to merge
# Exit 2 = blocking review comments, address them first
# Exit 3 = CI failed, fix and push
# Exit 4 = head updated, re-run watch
# Exit 5 = conflicts, resolve and push

# Squash-merge when green (remote branch auto-deletes on merge)
# Do NOT pass --repo; gh resolves the repo from the current directory.
gh pr merge "$pr_number" --squash --subject "$pr_title" --body "$pr_body"
```

## Failure Handling

- Exit 3 (CI failed): use `gh pr checks` and `gh run view --log` to identify the failure, fix locally, commit, push, and re-run `pr_watch.py`.
- Exit 4 (head updated): pull the latest branch, merge `origin/main` if needed, force-push to retrigger CI, then re-run `pr_watch.py`.
- Exit 5 (conflicts): fetch, merge `origin/main`, resolve, push, then re-run `pr_watch.py`.
- Flaky failures: re-run the failing job once; if it passes on retry, proceed.
- Do not use `--auto` merge; always run `pr_watch.py` explicitly.

## Review Handling

- Before merging, check for open human review comments:
  ```bash
  gh pr view --json reviews -q '.reviews[] | select(.state == "CHANGES_REQUESTED")'
  gh api repos/{owner}/{repo}/pulls/$pr_number/comments --jq '.[].body'
  ```
- If there are outstanding review comments requiring changes, do not merge — surface the blocker and stop.
- If reviews are approved or there are no blocking comments, proceed to merge.
