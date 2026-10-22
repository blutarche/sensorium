#!/usr/bin/env python3
"""Fixture-driven test for clean-build-output.py.

Every case builds a throwaway repository under a temporary directory: a
`main` branch pushed to a bare remote, and agent worktrees under
`.claude/worktrees/`. It never reads or changes the repository it lives in.

Run one case by name, or all of them with no argument.
"""
from __future__ import annotations

import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "clean-build-output.py"
OLD = time.time() - 2 * 3600

GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Fixture",
    "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "Fixture",
    "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
}


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args], env=GIT_ENV,
        capture_output=True, text=True, check=True,
    )
    return result.stdout


def backdate(path: Path) -> None:
    for root, dirs, files in os.walk(path):
        for name in dirs + files:
            os.utime(os.path.join(root, name), (OLD, OLD), follow_symlinks=False)
    os.utime(path, (OLD, OLD), follow_symlinks=False)


class Fixture:
    def __init__(self, tmp: Path) -> None:
        self.tmp = tmp
        self.remote = tmp / "remote.git"
        self.repo = tmp / "repo"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.remote)],
                       env=GIT_ENV, check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)],
                       env=GIT_ENV, check=True)
        (self.repo / ".gitignore").write_text(
            ".build/\nDerivedData/\nArtifacts/\n.claude/worktrees/\n")
        (self.repo / "README.md").write_text("fixture\n")
        git(self.repo, "add", ".gitignore", "README.md")
        git(self.repo, "commit", "-q", "-m", "initial")
        git(self.repo, "remote", "add", "origin", str(self.remote))
        git(self.repo, "push", "-q", "origin", "main")
        git(self.repo, "fetch", "-q", "origin")

    def worktree(self, agent_id: str) -> Path:
        path = self.repo / ".claude" / "worktrees" / f"agent-{agent_id}"
        git(self.repo, "worktree", "add", "-q", "-b", f"worktree-agent-{agent_id}",
            str(path), "main")
        return path

    def build_dir(self, owner: Path, relative: str = ".build") -> Path:
        build = owner / relative
        (build / "debug").mkdir(parents=True)
        (build / "debug" / "object.o").write_bytes(b"\0" * 65536)
        return build

    def settle(self) -> None:
        backdate(self.repo)

    def run(self, *args: str, free: int | None = None,
            cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        env = dict(GIT_ENV)
        if free is not None:
            env["CLEAN_BUILD_OUTPUT_TEST_FREE_BYTES"] = str(free)
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), *args],
            env=env, capture_output=True, text=True, cwd=str(cwd or self.tmp),
            timeout=120,
        )

    def branches(self) -> list[str]:
        return git(self.repo, "branch", "--format=%(refname:short)").split()


def check(result: subprocess.CompletedProcess[str], code: int = 0) -> str:
    output = result.stdout + result.stderr
    assert result.returncode == code, f"exit {result.returncode}\n{output}"
    return output


GIB = 1 << 30


def test_merged_clean_worktree_removed(fx: Fixture) -> None:
    wt = fx.worktree("a1")
    build = fx.build_dir(wt)
    outside = fx.tmp / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_text("must survive\n")
    os.symlink(outside, build / "link-out")
    fx.settle()
    out = check(fx.run("--apply"))
    assert not wt.exists(), out
    assert "worktree-agent-a1" not in fx.branches(), out
    assert (outside / "keep.txt").read_text() == "must survive\n", out
    assert "agent-a1" in out and "removed" in out, out


def test_uncommitted_change_kept(fx: Fixture) -> None:
    wt = fx.worktree("a2")
    (wt / "README.md").write_text("changed\n")
    fx.settle()
    out = check(fx.run("--apply"))
    assert wt.exists(), out
    assert "worktree-agent-a2" in fx.branches(), out
    assert "uncommitted" in out, out


def test_untracked_file_kept(fx: Fixture) -> None:
    wt = fx.worktree("a3")
    (wt / "notes.txt").write_text("new\n")
    fx.settle()
    out = check(fx.run("--apply"))
    assert wt.exists(), out
    assert "uncommitted" in out, out


def test_unmerged_commit_kept(fx: Fixture) -> None:
    wt = fx.worktree("a4")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    fx.settle()
    out = check(fx.run("--apply"))
    assert wt.exists(), out
    assert "worktree-agent-a4" in fx.branches(), out
    assert "not on main" in out, out


def test_commit_on_remote_branch_removed(fx: Fixture) -> None:
    wt = fx.worktree("a5")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "pushed work")
    git(wt, "push", "-q", "origin", "HEAD:refs/heads/topic")
    git(fx.repo, "fetch", "-q", "origin")
    fx.settle()
    out = check(fx.run("--apply"))
    assert not wt.exists(), out


def test_locked_worktree_kept(fx: Fixture) -> None:
    wt = fx.worktree("a6")
    git(fx.repo, "worktree", "lock", "--reason", "agent running", str(wt))
    fx.settle()
    out = check(fx.run("--apply", "--min-free", "1000G", free=1 * GIB))
    assert wt.exists(), out
    assert "locked" in out, out


def test_recently_modified_worktree_kept(fx: Fixture) -> None:
    wt = fx.worktree("a7")
    fx.settle()
    os.utime(wt / "README.md")
    out = check(fx.run("--apply"))
    assert wt.exists(), out
    assert "modified" in out, out


def test_freshly_deleted_build_does_not_count_as_activity(fx: Fixture) -> None:
    wt = fx.worktree("a9")
    build = fx.build_dir(wt)
    fx.settle()
    shutil.rmtree(build)
    out = check(fx.run("--apply"))
    assert not wt.exists(), out


def test_process_cwd_kept(fx: Fixture) -> None:
    wt = fx.worktree("a8")
    fx.settle()
    sleeper = subprocess.Popen(["sleep", "60"], cwd=str(wt))
    try:
        time.sleep(0.3)
        out = check(fx.run("--apply"))
    finally:
        sleeper.kill()
        sleeper.wait()
    assert wt.exists(), out
    assert "in use" in out and str(sleeper.pid) in out, out


def test_build_deleted_when_idle_and_space_low(fx: Fixture) -> None:
    wt = fx.worktree("b1")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    build = fx.build_dir(wt)
    nested = fx.build_dir(wt, "Artifacts/tool/.build")
    derived = fx.build_dir(wt, "DerivedData")
    main_build = fx.build_dir(fx.repo)
    fx.settle()
    out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    assert wt.exists(), out
    assert (wt / "feature.txt").exists(), out
    for path in (build, nested, derived, main_build):
        assert not path.exists(), f"{path} survived\n{out}"


def test_main_build_kept_while_someone_works_in_main(fx: Fixture) -> None:
    main_build = fx.build_dir(fx.repo)
    (fx.repo / "Sources").mkdir()
    fx.settle()
    sleeper = subprocess.Popen(["sleep", "60"], cwd=str(fx.repo / "Sources"))
    try:
        time.sleep(0.3)
        out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    finally:
        sleeper.kill()
        sleeper.wait()
    assert main_build.exists(), out
    assert str(sleeper.pid) in out, out


def test_main_build_not_held_by_work_in_agent_worktree(fx: Fixture) -> None:
    wt = fx.worktree("b6")
    git(fx.repo, "worktree", "lock", str(wt))
    main_build = fx.build_dir(fx.repo)
    fx.settle()
    sleeper = subprocess.Popen(["sleep", "60"], cwd=str(wt))
    try:
        time.sleep(0.3)
        out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    finally:
        sleeper.kill()
        sleeper.wait()
    assert not main_build.exists(), out


def test_build_kept_when_space_high(fx: Fixture) -> None:
    wt = fx.worktree("b2")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    build = fx.build_dir(wt)
    main_build = fx.build_dir(fx.repo)
    fx.settle()
    out = check(fx.run("--apply", "--min-free", "40G", free=500 * GIB))
    assert build.exists() and main_build.exists(), out
    assert "at or above" in out, out


def test_build_kept_without_min_free(fx: Fixture) -> None:
    wt = fx.worktree("b3")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    build = fx.build_dir(wt)
    fx.settle()
    out = check(fx.run("--apply", free=1 * GIB))
    assert build.exists(), out


def test_build_kept_when_recently_modified(fx: Fixture) -> None:
    wt = fx.worktree("b4")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    build = fx.build_dir(wt)
    fx.settle()
    os.utime(build / "debug" / "object.o")
    out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    assert build.exists(), out
    assert "modified" in out, out


def test_build_kept_when_swiftpm_lock_held(fx: Fixture) -> None:
    wt = fx.worktree("b5")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    build = fx.build_dir(wt)
    fx.settle()
    # SwiftPM names its scratch-directory lock after the real path of the
    # scratch directory and keeps it in the build's temporary directory.
    lock = Path(tempfile.gettempdir()) / (os.path.realpath(build).replace("/", "_") + ".lock")
    lock.touch()
    fd = os.open(lock, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    finally:
        os.close(fd)
        lock.unlink()
    assert build.exists(), out
    assert "lock" in out, out


def test_dry_run_deletes_nothing(fx: Fixture) -> None:
    wt = fx.worktree("c1")
    other = fx.worktree("c2")
    (other / "feature.txt").write_text("work\n")
    git(other, "add", "feature.txt")
    git(other, "commit", "-q", "-m", "unmerged work")
    build = fx.build_dir(other)
    main_build = fx.build_dir(fx.repo)
    fx.settle()
    out = check(fx.run("--min-free", "40G", free=1 * GIB))
    assert wt.exists() and build.exists() and main_build.exists(), out
    assert "worktree-agent-c1" in fx.branches(), out
    assert "would remove" in out and "would delete" in out, out
    assert "--apply" in out, out


def test_symlinked_build_dir_not_followed(fx: Fixture) -> None:
    wt = fx.worktree("c3")
    (wt / "feature.txt").write_text("work\n")
    git(wt, "add", "feature.txt")
    git(wt, "commit", "-q", "-m", "unmerged work")
    outside = fx.tmp / "outside-build"
    (outside / "debug").mkdir(parents=True)
    (outside / "debug" / "object.o").write_text("must survive\n")
    os.symlink(outside, wt / ".build")
    inner = fx.build_dir(wt, "Artifacts/tool/.build")
    os.symlink(outside, inner / "link-out")
    fx.settle()
    out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    assert (outside / "debug" / "object.o").read_text() == "must survive\n", out
    assert (wt / ".build").is_symlink(), out
    assert not inner.exists(), out


def test_worktree_outside_agent_dir_untouched(fx: Fixture) -> None:
    path = fx.tmp / "elsewhere"
    git(fx.repo, "worktree", "add", "-q", "-b", "worktree-agent-x9", str(path), "main")
    build = fx.build_dir(path)
    fx.settle()
    backdate(path)
    out = check(fx.run("--apply", "--min-free", "40G", free=1 * GIB))
    assert path.exists() and build.exists(), out


def test_quiet_prints_actions_and_total(fx: Fixture) -> None:
    fx.worktree("d1")
    kept = fx.worktree("d2")
    (kept / "notes.txt").write_text("new\n")
    fx.settle()
    out = check(fx.run("--quiet"))
    lines = out.strip().splitlines()
    assert any("would remove" in line for line in lines), out
    assert not any("agent-d2" in line for line in lines), out
    assert "reclaim" in lines[-1], out


def test_not_a_repository_fails(fx: Fixture) -> None:
    empty = fx.tmp / "empty"
    empty.mkdir()
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--repo", str(empty)],
        env=GIT_ENV, capture_output=True, text=True, timeout=60,
    )
    assert result.returncode != 0, result


TESTS = {name: fn for name, fn in globals().items() if name.startswith("test_")}


def main(argv: list[str]) -> int:
    selected = argv or list(TESTS)
    failed = 0
    for name in selected:
        tmp = Path(tempfile.mkdtemp(prefix="clean-build-output."))
        try:
            TESTS[name](Fixture(Path(os.path.realpath(tmp))))
            print(f"ok   {name}")
        except AssertionError as error:
            failed += 1
            print(f"FAIL {name}\n{error}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    if failed:
        print(f"FAIL: {failed} of {len(selected)} clean-build-output cases")
        return 1
    print(f"PASS: clean-build-output fixtures ({len(selected)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
