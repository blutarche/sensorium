#!/usr/bin/env python3
"""Reclaim disk space from finished agent worktrees and stale build output.

Agent worktrees live under `<main>/.claude/worktrees/agent-*`, and each one's
SwiftPM `.build` grows past a gigabyte. This script takes two actions, each
behind guards. A guard it cannot evaluate counts as failed, so the item is
kept.

A. Remove a finished agent worktree, and its `worktree-agent-*` branch, when
   it is not locked, has no uncommitted or untracked changes, its HEAD is on
   `main` or on a remote-tracking branch, no process works in it or holds a
   file open in it, no SwiftPM build holds its lock, and nothing outside its
   build output changed for `--min-idle` minutes. It uses `git worktree
   remove` and `git branch -d`, never a forced variant.

B. Delete gitignored `.build` and `DerivedData` directories, in unlocked agent
   worktrees and in the main checkout, only when free space is below
   `--min-free`, no process works in the owning checkout or holds a file open
   in the directory, no SwiftPM build holds its lock, and nothing in it
   changed for `--min-idle` minutes.

SwiftPM 6 locks a scratch directory with an flock on
`<build temp dir>/<real path of the scratch dir, "/" replaced by "_">.lock`,
held for the whole build. The lock lives outside `.build`, so deleting
`.build` never deletes it. The script treats the lock as held when any
process has that file open, or when it cannot take the flock itself, and it
holds the flock while it deletes so no build can start in the middle.

It acts only with `--apply`; otherwise it prints what it would do. Symbolic
links are never followed. Exit status is 0 on success and 1 when any step
failed or any guard could not be evaluated.

The environment variable CLEAN_BUILD_OUTPUT_TEST_FREE_BYTES replaces the
measured free space. It exists for Scripts/test-clean-build-output.py only.
"""
from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

BUILD_DIR_NAMES = (".build", "DerivedData")
AGENT_PREFIX = "agent-"
AGENT_BRANCH_PREFIX = "worktree-agent-"
COMMAND_TIMEOUT = 120


class GuardError(Exception):
    """A guard could not be evaluated."""


class Busy(Exception):
    """A guard found the item in use."""


def parse_size(text: str) -> int:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([KMGT]?)i?B?\s*", text, re.IGNORECASE)
    if not match:
        raise argparse.ArgumentTypeError(f"not a size: {text!r} (use e.g. 40G, 500M)")
    number, unit = match.groups()
    scale = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}[unit.upper()]
    return int(float(number) * scale)


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024:
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def real(path: str | Path) -> str:
    return os.path.realpath(path)


def is_under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def run_git(cwd: str, *args: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", "--no-optional-locks", "-C", cwd, *args],
            capture_output=True, text=True, timeout=COMMAND_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GuardError(f"git {args[0]} failed: {error}") from error


def first_line(text: str) -> str:
    lines = text.strip().splitlines()
    return lines[0] if lines else "no output"


# Worktrees -------------------------------------------------------------------

@dataclass
class Worktree:
    path: str
    head: str = ""
    branch: str = ""
    locked: str | None = None
    prunable: bool = False
    bare: bool = False


def list_worktrees(repo: str) -> list[Worktree]:
    result = run_git(repo, "worktree", "list", "--porcelain")
    if result.returncode != 0:
        raise GuardError(f"git worktree list failed: {first_line(result.stderr)}")
    worktrees: list[Worktree] = []
    for line in result.stdout.splitlines():
        key, _, value = line.partition(" ")
        if key == "worktree":
            worktrees.append(Worktree(path=value))
        elif not worktrees:
            continue
        elif key == "HEAD":
            worktrees[-1].head = value
        elif key == "branch":
            worktrees[-1].branch = value
        elif key == "locked":
            worktrees[-1].locked = value or "no reason given"
        elif key == "prunable":
            worktrees[-1].prunable = True
        elif key == "bare":
            worktrees[-1].bare = True
    if not worktrees:
        raise GuardError("git worktree list returned no worktrees")
    return worktrees


def head_is_published(main: str, head: str) -> bool:
    refs = ["refs/heads/main"]
    listed = run_git(main, "for-each-ref", "--format=%(refname)", "refs/remotes/")
    if listed.returncode != 0:
        raise GuardError(f"git for-each-ref failed: {first_line(listed.stderr)}")
    refs += [ref for ref in listed.stdout.split() if not ref.endswith("/HEAD")]
    for ref in refs:
        verified = run_git(main, "rev-parse", "--verify", "--quiet", ref)
        if verified.returncode != 0:
            continue
        result = run_git(main, "merge-base", "--is-ancestor", head, ref)
        if result.returncode == 0:
            return True
        if result.returncode != 1:
            raise GuardError(f"git merge-base failed: {first_line(result.stderr)}")
    return False


# Processes -------------------------------------------------------------------

@dataclass
class Process:
    pid: int
    command: str
    ppid: int = 0
    cwd: str = ""
    names: list[str] = field(default_factory=list)


class ProcessTable:
    def __init__(self) -> None:
        if sys.platform == "darwin":
            self.processes = self._from_lsof()
        else:
            self.processes = self._from_proc()
        if not self.processes:
            raise GuardError("the process table could not be read")
        parents = {p.pid: p.ppid for p in self.processes}
        parents.setdefault(os.getpid(), os.getppid())
        self.invokers: set[int] = set()
        pid = os.getpid()
        while pid > 1 and pid not in self.invokers:
            self.invokers.add(pid)
            pid = parents.get(pid, 0)

    @staticmethod
    def _from_lsof() -> list[Process]:
        try:
            result = subprocess.run(
                ["lsof", "-n", "-P", "-w", "-F", "pcRfn"],
                capture_output=True, text=True, timeout=COMMAND_TIMEOUT,
                errors="replace",
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GuardError(f"lsof failed: {error}") from error
        if result.returncode not in (0, 1):
            raise GuardError(f"lsof exited {result.returncode}")
        processes: list[Process] = []
        fd = ""
        for line in result.stdout.splitlines():
            tag, value = line[:1], line[1:]
            if tag == "p":
                processes.append(Process(pid=int(value), command=""))
                fd = ""
            elif not processes:
                continue
            elif tag == "c":
                processes[-1].command = value
            elif tag == "R":
                processes[-1].ppid = int(value)
            elif tag == "f":
                fd = value
            elif tag == "n":
                if fd == "cwd":
                    processes[-1].cwd = value
                else:
                    processes[-1].names.append(value)
        return processes

    @staticmethod
    def _from_proc() -> list[Process]:
        try:
            entries = [e for e in os.listdir("/proc") if e.isdigit()]
        except OSError as error:
            raise GuardError(f"/proc could not be read: {error}") from error
        processes: list[Process] = []
        for entry in entries:
            base = f"/proc/{entry}"
            try:
                with open(f"{base}/stat") as stat:
                    fields = stat.read().rsplit(")", 1)[1].split()
                with open(f"{base}/comm") as comm:
                    command = comm.read().strip()
            except OSError:
                continue
            process = Process(pid=int(entry), command=command, ppid=int(fields[1]))
            # Another user's process cannot be inspected without privilege;
            # it is skipped rather than failing the whole table.
            with contextlib.suppress(OSError):
                process.cwd = os.readlink(f"{base}/cwd")
            with contextlib.suppress(OSError):
                process.names.append(os.readlink(f"{base}/exe"))
            with contextlib.suppress(OSError):
                for fd in os.listdir(f"{base}/fd"):
                    with contextlib.suppress(OSError):
                        process.names.append(os.readlink(f"{base}/fd/{fd}"))
            processes.append(process)
        return processes

    def users(self, root: str, *, cwd_root: str | None = None,
              cwd_exclude: str | None = None) -> str | None:
        """Describe the first process working in or holding a file under a path.

        `cwd_root` widens the working-directory check to an enclosing
        checkout, and `cwd_exclude` narrows it again, so work inside an agent
        worktree does not hold the main checkout. The script and the
        processes that launched it are ignored for the working-directory
        check: they are waiting on it.
        """
        roots = {root, real(root)}
        cwd_roots = roots if cwd_root is None else {cwd_root, real(cwd_root)}
        excluded = set() if cwd_exclude is None else {cwd_exclude, real(cwd_exclude)}
        for process in self.processes:
            if process.pid == os.getpid():
                continue
            if process.pid not in self.invokers and process.cwd \
                    and any(is_under(process.cwd, r) for r in cwd_roots) \
                    and not any(is_under(process.cwd, r) for r in excluded):
                return f"in use: pid {process.pid} ({process.command}) works there"
            for name in process.names:
                if any(is_under(name, r) for r in roots):
                    return f"in use: pid {process.pid} ({process.command}) has a file open there"
        return None

    def holds_file_named(self, basenames: set[str]) -> Process | None:
        for process in self.processes:
            for name in process.names:
                if os.path.basename(name) in basenames:
                    return process
        return None


# SwiftPM lock ----------------------------------------------------------------

def swiftpm_temp_dirs() -> list[str]:
    candidates = [os.environ.get("TMPDIR", ""), tempfile.gettempdir(), "/tmp", "/private/tmp"]
    if sys.platform == "darwin":
        with contextlib.suppress(OSError, subprocess.TimeoutExpired):
            result = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"],
                                    capture_output=True, text=True, timeout=10)
            candidates.append(result.stdout.strip())
    seen: dict[str, None] = {}
    for candidate in candidates:
        if candidate and os.path.isdir(candidate):
            seen.setdefault(real(candidate))
    return list(seen)


def swiftpm_lock_names(build: str) -> set[str]:
    return {path.replace("/", "_") + ".lock" for path in (os.path.abspath(build), real(build))}


@contextlib.contextmanager
def hold_swiftpm_locks(builds: list[str], processes: ProcessTable):
    """Take every SwiftPM scratch lock for these directories, or raise Busy."""
    names: set[str] = set()
    for build in builds:
        names |= swiftpm_lock_names(build)
    holder = processes.holds_file_named(names)
    if holder:
        raise Busy(f"SwiftPM lock held by pid {holder.pid} ({holder.command})")
    with contextlib.ExitStack() as stack:
        for directory in swiftpm_temp_dirs():
            for name in names:
                path = os.path.join(directory, name)
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                except FileNotFoundError:
                    continue
                except OSError as error:
                    raise GuardError(f"SwiftPM lock {path} unreadable: {error}") from error
                stack.callback(os.close, fd)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as error:
                    if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN):
                        raise Busy(f"SwiftPM lock held: {path}") from error
                    raise GuardError(f"SwiftPM lock {path}: {error}") from error
                stack.callback(fcntl.flock, fd, fcntl.LOCK_UN)
        yield


# Files -----------------------------------------------------------------------

def _raise(error: OSError) -> None:
    raise error


def recent_change(root: str, cutoff: float,
                  prune: set[str] = frozenset()) -> tuple[str, float] | None:
    """Return the first file or link under root modified at or after cutoff.

    Directory times are not consulted: creating or deleting build output
    changes its parent directory's time without anyone working there.
    """
    try:
        for directory, dirs, files in os.walk(root, onerror=_raise):
            dirs[:] = [d for d in dirs if d not in prune]
            links = [d for d in dirs if os.path.islink(os.path.join(directory, d))]
            for name in links + files:
                path = os.path.join(directory, name)
                mtime = os.lstat(path).st_mtime
                if mtime >= cutoff:
                    return path, mtime
    except OSError as error:
        raise GuardError(f"could not scan {root}: {error}") from error
    return None


def disk_usage(root: str) -> int:
    seen: set[tuple[int, int]] = set()
    total = 0
    for directory, dirs, files in os.walk(root):
        for name in [""] + dirs + files:
            path = os.path.join(directory, name) if name else directory
            try:
                stat = os.lstat(path)
            except OSError:
                continue
            key = (stat.st_dev, stat.st_ino)
            if key not in seen:
                seen.add(key)
                total += stat.st_blocks * 512
    return total


def find_build_dirs(root: str, prune_paths: set[str] = frozenset()) -> list[str]:
    found: list[str] = []
    for directory, dirs, _ in os.walk(root):
        keep = []
        for name in dirs:
            path = os.path.join(directory, name)
            if name == ".git" or path in prune_paths:
                continue
            if name in BUILD_DIR_NAMES:
                found.append(path)
            else:
                keep.append(name)
        dirs[:] = keep
    return sorted(found)


# Report ----------------------------------------------------------------------

class Report:
    def __init__(self, main: str, apply: bool, quiet: bool) -> None:
        self.main = main
        self.apply = apply
        self.quiet = quiet
        self.reclaimed = 0
        self.failed = False

    def name(self, path: str) -> str:
        return os.path.relpath(path, self.main) if is_under(path, self.main) else path

    def act(self, line: str, size: int) -> None:
        self.reclaimed += size
        print(line, flush=True)

    def keep(self, line: str) -> None:
        if not self.quiet:
            print(line, flush=True)

    def info(self, line: str) -> None:
        if not self.quiet:
            print(line, flush=True)

    def error(self, line: str) -> None:
        self.failed = True
        print(f"error: {line}", file=sys.stderr, flush=True)

    def total(self) -> None:
        if self.apply:
            print(f"reclaimed {human(self.reclaimed)}", flush=True)
        else:
            print(f"would reclaim {human(self.reclaimed)} (dry run; run with --apply to act)",
                  flush=True)


def age(mtime: float) -> str:
    minutes = max(0, int((time.time() - mtime) // 60))
    return f"{minutes} min ago"


# Actions ---------------------------------------------------------------------

class Cleaner:
    def __init__(self, args: argparse.Namespace, main: str, report: Report,
                 processes: ProcessTable) -> None:
        self.args = args
        self.main = main
        self.report = report
        self.processes = processes
        self.cutoff = time.time() - args.min_idle * 60

    def remove_worktree(self, wt: Worktree) -> bool:
        """Apply action A. Return True if the worktree is gone or would be."""
        name = self.report.name(wt.path)
        try:
            reason = self._worktree_blocker(wt)
        except GuardError as error:
            self.report.error(f"{name}: {error}")
            self.report.keep(f"keep worktree {name}: guard could not be evaluated")
            return False
        except Busy as error:
            reason = str(error)
        if reason:
            self.report.keep(f"keep worktree {name}: {reason}")
            return False
        builds = [b for b in find_build_dirs(wt.path) if not os.path.islink(b)]
        size = disk_usage(wt.path)
        branch = wt.branch.removeprefix("refs/heads/")
        delete_branch = branch.startswith(AGENT_BRANCH_PREFIX)
        branch_note = f" and branch {branch}" if delete_branch else ""
        if not self.args.apply:
            self.report.act(f"would remove worktree {name}{branch_note} ({human(size)})", size)
            return True
        try:
            with hold_swiftpm_locks(builds, self.processes):
                result = run_git(self.main, "worktree", "remove", wt.path)
        except Busy as error:
            self.report.keep(f"keep worktree {name}: {error}")
            return False
        except GuardError as error:
            self.report.error(f"{name}: {error}")
            self.report.keep(f"keep worktree {name}: guard could not be evaluated")
            return False
        if result.returncode != 0:
            self.report.error(f"git worktree remove {name}: {first_line(result.stderr)}")
            return False
        self.report.act(f"removed worktree {name} ({human(size)})", size)
        if delete_branch:
            deleted = run_git(self.main, "branch", "-d", branch)
            if deleted.returncode == 0:
                self.report.act(f"deleted branch {branch}", 0)
            else:
                self.report.keep(f"kept branch {branch}: git refused to delete it "
                                 f"({first_line(deleted.stderr)})")
        return True

    def _worktree_blocker(self, wt: Worktree) -> str | None:
        if wt.locked is not None:
            return f"locked ({wt.locked})"
        if wt.prunable or not os.path.isdir(wt.path):
            return "missing on disk"
        if os.path.islink(wt.path):
            return "is a symbolic link"
        if not wt.head:
            return "no HEAD commit"
        status = run_git(wt.path, "status", "--porcelain", "--ignored=no")
        if status.returncode != 0:
            raise GuardError(f"git status failed: {first_line(status.stderr)}")
        if status.stdout.strip():
            return "uncommitted or untracked changes"
        if not head_is_published(self.main, wt.head):
            return f"HEAD {wt.head[:9]} is not on main or any remote-tracking branch"
        user = self.processes.users(wt.path)
        if user:
            return user
        with hold_swiftpm_locks(find_build_dirs(wt.path), self.processes):
            pass
        recent = recent_change(wt.path, self.cutoff, prune=set(BUILD_DIR_NAMES))
        if recent is None:
            admin = run_git(wt.path, "rev-parse", "--absolute-git-dir")
            if admin.returncode != 0:
                raise GuardError(f"git rev-parse failed: {first_line(admin.stderr)}")
            recent = recent_change(admin.stdout.strip(), self.cutoff)
        if recent:
            return f"modified {age(recent[1])}: {self.report.name(recent[0])}"
        return None

    def delete_build_output(self, owner: str, exclude: str | None = None) -> None:
        """Apply action B to every build directory inside one checkout.

        `exclude` is a directory inside the checkout that belongs to someone
        else, the agent worktrees inside the main checkout.
        """
        for build in find_build_dirs(owner, set() if exclude is None else {exclude}):
            name = self.report.name(build)
            try:
                reason = self._build_blocker(owner, build, exclude)
                if reason:
                    self.report.keep(f"keep build output {name}: {reason}")
                    continue
                size = disk_usage(build)
                with hold_swiftpm_locks([build], self.processes):
                    if not self.args.apply:
                        self.report.act(f"would delete build output {name} ({human(size)})", size)
                        continue
                    try:
                        shutil.rmtree(build)
                    except OSError as error:
                        self.report.error(f"could not delete {name}: {error}")
                        continue
                self.report.act(f"deleted build output {name} ({human(size)})", size)
            except Busy as error:
                self.report.keep(f"keep build output {name}: {error}")
            except GuardError as error:
                self.report.error(f"{name}: {error}")
                self.report.keep(f"keep build output {name}: guard could not be evaluated")

    def _build_blocker(self, owner: str, build: str, exclude: str | None) -> str | None:
        if os.path.islink(build):
            return "is a symbolic link"
        ignored = run_git(owner, "check-ignore", "-q", "--", os.path.relpath(build, owner))
        if ignored.returncode == 1:
            return "not ignored by git"
        if ignored.returncode != 0:
            raise GuardError(f"git check-ignore failed: {first_line(ignored.stderr)}")
        user = self.processes.users(build, cwd_root=owner, cwd_exclude=exclude)
        if user:
            return user
        recent = recent_change(build, self.cutoff)
        if recent:
            return f"modified {age(recent[1])}: {self.report.name(recent[0])}"
        return None


def free_bytes(path: str) -> int:
    override = os.environ.get("CLEAN_BUILD_OUTPUT_TEST_FREE_BYTES")
    if override:
        return int(override)
    return shutil.disk_usage(path).free


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove finished agent worktrees and stale build output. "
                    "Prints what it would do unless --apply is given.")
    parser.add_argument("--apply", action="store_true", help="act instead of reporting")
    parser.add_argument("--min-idle", type=float, default=60, metavar="MINUTES",
                        help="leave anything modified within this many minutes (default 60)")
    parser.add_argument("--min-free", type=parse_size, metavar="SIZE",
                        help="delete build output only while free space is below SIZE, "
                             "e.g. 40G; without it build output is left alone")
    parser.add_argument("--repo", default=".", metavar="PATH",
                        help="any directory inside the repository (default: current)")
    parser.add_argument("--quiet", action="store_true",
                        help="print only actions taken and the total")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        worktrees = list_worktrees(os.path.abspath(args.repo))
    except GuardError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if worktrees[0].bare:
        print("error: the main worktree is a bare repository", file=sys.stderr)
        return 1
    main_path = worktrees[0].path
    report = Report(main_path, args.apply, args.quiet)
    try:
        processes = ProcessTable()
    except GuardError as error:
        print(f"error: {error}; nothing was touched", file=sys.stderr)
        return 1
    cleaner = Cleaner(args, main_path, report, processes)
    agent_root = real(os.path.join(main_path, ".claude", "worktrees"))

    low_space = False
    if args.min_free is None:
        report.info("build output: left alone (no --min-free given)")
    else:
        free = free_bytes(main_path)
        low_space = free < args.min_free
        if not low_space:
            report.info(f"build output: left alone, {human(free)} free is at or above "
                        f"--min-free {human(args.min_free)}")
        else:
            report.info(f"build output: {human(free)} free is below "
                        f"--min-free {human(args.min_free)}")

    for wt in worktrees[1:]:
        name = report.name(wt.path)
        inside = os.path.dirname(real(wt.path)) == agent_root
        if not inside or not os.path.basename(wt.path).startswith(AGENT_PREFIX):
            report.keep(f"skip worktree {name}: not an agent worktree under .claude/worktrees")
            continue
        if cleaner.remove_worktree(wt):
            continue
        if low_space and wt.locked is None and os.path.isdir(wt.path) \
                and not os.path.islink(wt.path):
            cleaner.delete_build_output(wt.path)

    if low_space:
        cleaner.delete_build_output(main_path, exclude=os.path.join(main_path, ".claude", "worktrees"))

    report.total()
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
