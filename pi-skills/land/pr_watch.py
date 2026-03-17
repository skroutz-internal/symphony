#!/usr/bin/env python3
import asyncio
import json
import random
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any

POLL_SECONDS = 10
CHECKS_APPEAR_TIMEOUT_SECONDS = 120
MAX_GH_RETRIES = 5
BASE_GH_BACKOFF_SECONDS = 2


class _WatchExit(Exception):
    def __init__(self, code: int) -> None:
        self.code = code


@dataclass
class PrInfo:
    number: int
    url: str
    head_sha: str
    mergeable: str | None
    merge_state: str | None


class RateLimitError(RuntimeError):
    pass


class NotFoundError(RuntimeError):
    pass


def is_rate_limit_error(error: str) -> bool:
    return "HTTP 429" in error or "rate limit" in error.lower()


def is_not_found_error(error: str) -> bool:
    return "HTTP 404" in error or "Not Found" in error


async def run_gh(*args: str) -> str:
    max_delay = BASE_GH_BACKOFF_SECONDS * (2 ** (MAX_GH_RETRIES - 1))
    delay_seconds = BASE_GH_BACKOFF_SECONDS
    last_error = "gh command failed"
    for attempt in range(1, MAX_GH_RETRIES + 1):
        proc = await asyncio.create_subprocess_exec(
            "gh",
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            return stdout.decode()
        error = stderr.decode().strip() or "gh command failed"
        if is_not_found_error(error):
            raise NotFoundError(error)
        if not is_rate_limit_error(error):
            raise RuntimeError(error)
        last_error = error
        if attempt >= MAX_GH_RETRIES:
            break
        jitter = random.uniform(0, delay_seconds)
        await asyncio.sleep(min(delay_seconds + jitter, max_delay))
        delay_seconds = min(delay_seconds * 2, max_delay)
    raise RateLimitError(last_error)


async def get_pr_info() -> PrInfo:
    data = await run_gh(
        "pr",
        "view",
        "--json",
        "number,url,headRefOid,mergeable,mergeStateStatus",
    )
    parsed = json.loads(data)
    return PrInfo(
        number=parsed["number"],
        url=parsed["url"],
        head_sha=parsed["headRefOid"],
        mergeable=parsed.get("mergeable"),
        merge_state=parsed.get("mergeStateStatus"),
    )


async def get_paginated_list(endpoint: str) -> list[dict[str, Any]]:
    page = 1
    items: list[dict[str, Any]] = []
    while True:
        try:
            data = await run_gh(
                "api",
                "--method",
                "GET",
                endpoint,
                "-f",
                "per_page=100",
                "-f",
                f"page={page}",
            )
        except NotFoundError:
            return items
        batch = json.loads(data)
        if not batch:
            break
        items.extend(batch)
        page += 1
    return items


async def get_issue_comments(pr_number: int) -> list[dict[str, Any]]:
    return await get_paginated_list(
        f"repos/{{owner}}/{{repo}}/issues/{pr_number}/comments",
    )


async def get_review_comments(pr_number: int) -> list[dict[str, Any]]:
    return await get_paginated_list(
        f"repos/{{owner}}/{{repo}}/pulls/{pr_number}/comments",
    )


async def get_reviews(pr_number: int) -> list[dict[str, Any]]:
    page = 1
    reviews: list[dict[str, Any]] = []
    while True:
        data = await run_gh(
            "api",
            "--method",
            "GET",
            f"repos/{{owner}}/{{repo}}/pulls/{pr_number}/reviews",
            "-f",
            "per_page=100",
            "-f",
            f"page={page}",
        )
        batch = json.loads(data)
        if not batch:
            break
        reviews.extend(batch)
        page += 1
    return reviews


async def get_check_runs(head_sha: str) -> list[dict[str, Any]]:
    page = 1
    check_runs: list[dict[str, Any]] = []
    while True:
        data = await run_gh(
            "api",
            "--method",
            "GET",
            f"repos/{{owner}}/{{repo}}/commits/{head_sha}/check-runs",
            "-f",
            "per_page=100",
            "-f",
            f"page={page}",
        )
        payload = json.loads(data)
        batch = payload.get("check_runs", [])
        if not batch:
            break
        check_runs.extend(batch)
        total_count = payload.get("total_count")
        if total_count is not None and len(check_runs) >= total_count:
            break
        page += 1
    return check_runs


def parse_time(value: str) -> datetime:
    normalized = value.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized)


CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def sanitize_terminal_output(value: str) -> str:
    return CONTROL_CHARS_RE.sub("", value)


def check_timestamp(check: dict[str, Any]) -> datetime | None:
    for key in ("completed_at", "started_at", "run_started_at", "created_at"):
        value = check.get(key)
        if value:
            return parse_time(value)
    return None


def dedupe_check_runs(check_runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest_by_name: dict[str, dict[str, Any]] = {}
    for check in check_runs:
        name = check.get("name", "unknown")
        timestamp = check_timestamp(check)
        if name not in latest_by_name:
            latest_by_name[name] = check
            continue
        existing = latest_by_name[name]
        existing_timestamp = check_timestamp(existing)
        if timestamp is None:
            continue
        if existing_timestamp is None or timestamp > existing_timestamp:
            latest_by_name[name] = check
    return list(latest_by_name.values())


def summarize_checks(check_runs: list[dict[str, Any]]) -> tuple[bool, bool, list[str]]:
    if not check_runs:
        return True, False, ["no checks reported"]
    check_runs = dedupe_check_runs(check_runs)
    pending = False
    failed = False
    failures: list[str] = []
    for check in check_runs:
        status = check.get("status")
        conclusion = check.get("conclusion")
        name = check.get("name", "unknown")
        if status != "completed":
            pending = True
            continue
        if conclusion not in ("success", "skipped", "neutral"):
            failed = True
            failures.append(f"{name}: {conclusion}")
    return pending, failed, failures


def is_bot_user(user: dict[str, Any]) -> bool:
    login = user.get("login") or ""
    if user.get("type") == "Bot":
        return True
    return login.endswith("[bot]")


def is_agent_comment(comment: dict[str, Any]) -> bool:
    """Comments posted by this system are prefixed with 'symphony(' in the body."""
    body = (comment.get("body") or "").lstrip()
    return body.startswith("symphony(")


def comment_time(comment: dict[str, Any]) -> datetime | None:
    timestamp = comment.get("updated_at") or comment.get("created_at")
    if not timestamp:
        return None
    return parse_time(timestamp)


def thread_root_id(comment: dict[str, Any]) -> int | None:
    return comment.get("in_reply_to_id") or comment.get("id")


def filter_human_review_comments(
    comments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    return [c for c in comments if not is_bot_user(c.get("user", {})) and not is_agent_comment(c)]


def review_timestamp(review: dict[str, Any]) -> datetime | None:
    created_at = review.get("submitted_at") or review.get("created_at")
    if not created_at:
        return None
    return parse_time(created_at)


def dedupe_reviews(reviews: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest_by_user: dict[str, dict[str, Any]] = {}
    for review in reviews:
        user_login = review.get("user", {}).get("login")
        if not user_login:
            continue
        timestamp = review_timestamp(review)
        if user_login not in latest_by_user:
            latest_by_user[user_login] = review
            continue
        existing = latest_by_user[user_login]
        existing_timestamp = review_timestamp(existing)
        if timestamp is None:
            continue
        if existing_timestamp is None or timestamp > existing_timestamp:
            latest_by_user[user_login] = review
    return list(latest_by_user.values())


def filter_blocking_reviews(reviews: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        review
        for review in dedupe_reviews(reviews)
        if not is_bot_user(review.get("user", {}))
        and review.get("state") == "CHANGES_REQUESTED"
    ]


def is_merge_conflicting(pr: PrInfo) -> bool:
    return pr.mergeable == "CONFLICTING" or pr.merge_state == "DIRTY"


async def fetch_review_context(
    pr_number: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    issue_comments, review_comments, reviews = await asyncio.gather(
        get_issue_comments(pr_number),
        get_review_comments(pr_number),
        get_reviews(pr_number),
    )
    return issue_comments, review_comments, reviews


def raise_on_human_feedback(
    issue_comments: list[dict[str, Any]],
    review_comments: list[dict[str, Any]],
    reviews: list[dict[str, Any]],
) -> None:
    human_issue_comments = [c for c in issue_comments if not is_bot_user(c.get("user", {})) and not is_agent_comment(c)]
    human_review_comments = filter_human_review_comments(review_comments)
    if human_issue_comments or human_review_comments:
        print("Review comments detected. Address before merge.")
        raise _WatchExit(2)
    blocking_reviews = filter_blocking_reviews(reviews)
    if blocking_reviews:
        print("Blocking review state detected. Address before merge.")
        raise _WatchExit(2)


async def wait_for_feedback(pr_number: int, checks_done: asyncio.Event, wake_on_review: bool = False) -> None:
    print("Waiting for review feedback...", flush=True)
    initial_reviews: set[str] = set()
    if wake_on_review:
        _, _, reviews0 = await fetch_review_context(pr_number)
        initial_reviews = {r.get("id", "") for r in dedupe_reviews(reviews0) if not is_bot_user(r.get("user", {}))}
    while True:
        issue_comments, review_comments, reviews = await fetch_review_context(pr_number)
        raise_on_human_feedback(issue_comments, review_comments, reviews)
        if wake_on_review:
            human_reviews = [
                r for r in dedupe_reviews(reviews)
                if not is_bot_user(r.get("user", {})) and r.get("id", "") not in initial_reviews
            ]
            if human_reviews:
                for r in human_reviews:
                    state = r.get("state", "UNKNOWN")
                    author = r.get("user", {}).get("login", "unknown")
                    body = r.get("body", "").strip()
                    print(f"New review from {author}: {state}" + (f" — {body}" if body else ""))
                return
        # In wake-on-review mode, keep waiting for explicit human feedback
        # even when CI is absent or already complete.
        if checks_done.is_set() and not wake_on_review:
            return
        await asyncio.sleep(POLL_SECONDS)


async def repo_has_workflows(pr_url: str) -> bool:
    """Return True if the repo has any GitHub Actions workflows defined."""
    # pr_url e.g. https://github.com/owner/repo/pull/N
    parts = pr_url.rstrip("/").split("/")
    nwo = f"{parts[-4]}/{parts[-3]}"
    try:
        data = await run_gh("api", f"repos/{nwo}/actions/workflows", "--jq", ".total_count")
        return int(data.strip()) > 0
    except Exception:
        return True  # assume CI exists if we can't tell


async def wait_for_checks(head_sha: str, checks_done: asyncio.Event, pr_url: str = "") -> None:
    print("Waiting for CI checks...", flush=True)
    if pr_url and not await repo_has_workflows(pr_url):
        print("No GitHub Actions workflows configured; skipping CI wait.")
        checks_done.set()
        return
    empty_seconds = 0
    while True:
        check_runs = await get_check_runs(head_sha)
        if not check_runs:
            empty_seconds += POLL_SECONDS
            if empty_seconds >= CHECKS_APPEAR_TIMEOUT_SECONDS:
                print("No checks detected after 120s; assuming no CI configured.")
                checks_done.set()
                return
            await asyncio.sleep(POLL_SECONDS)
            continue
        empty_seconds = 0
        pending, failed, failures = summarize_checks(check_runs)
        if failed:
            print("Checks failed:")
            for failure in failures:
                print(f"- {failure}")
            raise _WatchExit(3)
        if not pending:
            print("Checks passed.")
            checks_done.set()
            return
        await asyncio.sleep(POLL_SECONDS)


async def watch_pr(wake_on_review: bool = False) -> None:
    pr = await get_pr_info()
    if is_merge_conflicting(pr):
        print(
            "PR has merge conflicts. Resolve/rebase against main and push before "
            "running pr_watch again.",
        )
        raise _WatchExit(5)
    head_sha = pr.head_sha
    checks_done = asyncio.Event()
    feedback_task = asyncio.create_task(wait_for_feedback(pr.number, checks_done, wake_on_review))
    checks_task = asyncio.create_task(wait_for_checks(head_sha, checks_done, pr.url))

    async def head_monitor() -> None:
        while True:
            await asyncio.sleep(POLL_SECONDS)
            current = await get_pr_info()
            if is_merge_conflicting(current):
                print(
                    "PR has merge conflicts. Resolve/rebase against main and push "
                    "before running pr_watch again.",
                )
                raise _WatchExit(5)
            if current.head_sha != head_sha:
                print("PR head updated; pull/amend/force-push to retrigger CI.")
                raise _WatchExit(4)

    monitor_task = asyncio.create_task(head_monitor())
    success_task = asyncio.gather(feedback_task, checks_task)

    done, pending = await asyncio.wait(
        [monitor_task, success_task],
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()
    feedback_task.cancel()
    checks_task.cancel()
    monitor_task.cancel()
    await asyncio.gather(feedback_task, checks_task, monitor_task, return_exceptions=True)
    for task in done:
        if not task.cancelled():
            exc = task.exception()
            if exc:
                raise exc


if __name__ == "__main__":
    wake_on_review = "--wake-on-review" in sys.argv
    try:
        asyncio.run(watch_pr(wake_on_review=wake_on_review))
    except _WatchExit as exc:
        raise SystemExit(exc.code) from None
