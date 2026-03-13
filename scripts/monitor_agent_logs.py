#!/usr/bin/env python3
import argparse
import os
import sys
import time
from pathlib import Path
from typing import Iterable


def color(code: str, text: str, enabled: bool) -> str:
    return f"\033[{code}m{text}\033[0m" if enabled else text


def latest_activity_log(logs_dir: Path) -> Path | None:
    files = sorted(logs_dir.glob("activity-*.log"), key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def workspace_dirs(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return sorted([p for p in root.iterdir() if p.is_dir() and not p.name.startswith("_")])


class FileFollower:
    def __init__(self, path: Path, from_start: bool = True):
        self.path = path
        self.fp = None
        self.position = 0
        self.from_start = from_start

    def open(self) -> None:
        self.fp = self.path.open("r", encoding="utf-8", errors="replace")
        if self.from_start:
            self.fp.seek(0)
        else:
            self.fp.seek(0, os.SEEK_END)
        self.position = self.fp.tell()

    def read_new(self) -> Iterable[str]:
        if self.fp is None:
            self.open()
        assert self.fp is not None
        self.fp.seek(self.position)
        data = self.fp.read()
        self.position = self.fp.tell()
        if not data:
            return []
        return [line for line in data.splitlines() if line.strip()]


class WorkspaceMonitor:
    def __init__(self, name: str, follower: FileFollower, use_color: bool):
        self.name = name
        self.follower = follower
        self.use_color = use_color
        self.turn_number = 0
        self.label = color("32", f"[{name}]", use_color)

    def _banner(self, text: str, code: str) -> str:
        bar = color(code, f"{'─' * 3} {text} {'─' * 3}", self.use_color)
        return f"{self.label} {bar}"

    def process_lines(self) -> None:
        for line in self.follower.read_new():
            if line.startswith("• user:"):
                self.turn_number += 1
                is_continuation = "Continuation guidance" in line
                if self.turn_number == 1:
                    print(self._banner("agent start", "1;36"))
                label = f"turn {self.turn_number}" + (" (continuation)" if is_continuation else "")
                print(self._banner(label, "1;34"))
                # Show a brief excerpt of the user message
                msg = line[len("• user:"):].strip()
                if msg:
                    excerpt = (msg[:120] + "…") if len(msg) > 120 else msg
                    print(f"{self.label}   {color('2', excerpt, self.use_color)}")
            elif line.startswith("• assistant:"):
                msg = line[len("• assistant:"):].strip()
                excerpt = (msg[:120] + "…") if len(msg) > 120 else msg
                print(f"{self.label}   {color('2', excerpt, self.use_color)}")
                print(self._banner(f"turn {self.turn_number} done", "1;32"))
            else:
                print(f"{self.label} {line}")
        sys.stdout.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description="Monitor activity logs for Symphony workspaces")
    default_root = os.environ.get("SYMPHONY_WORKSPACES_ROOT", str(Path.home() / "symphony-workspaces"))
    parser.add_argument("root", nargs="?", default=default_root, help="Workspace root")
    parser.add_argument("--interval", type=float, default=0.5, help="Poll interval seconds")
    parser.add_argument("--no-color", action="store_true", help="Disable ANSI colors")
    parser.add_argument("--tail", action="store_true", help="Start at end of file instead of replaying existing events")
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    use_color = sys.stdout.isatty() and not args.no_color
    mode = "tailing from end" if args.tail else "replaying existing events, then following"
    print(f"Monitoring {root} ({mode})")

    monitors: dict[str, WorkspaceMonitor] = {}

    while True:
        for ws in workspace_dirs(root):
            if ws.name in monitors:
                continue
            logs_dir = root / "_logs" / ws.name
            log = latest_activity_log(logs_dir)
            if not log:
                continue
            follower = FileFollower(log, from_start=not args.tail)
            monitor = WorkspaceMonitor(ws.name, follower, use_color)
            monitors[ws.name] = monitor
            print(f"{monitor.label} tracking {log.name}")

        for monitor in monitors.values():
            monitor.process_lines()

        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nStopped.")
        raise SystemExit(130)
