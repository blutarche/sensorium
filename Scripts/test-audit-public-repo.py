#!/usr/bin/env python3
"""Fixture tests for the audit, both directions.

The inline-secret-assignment rule: a reference passed where a secret's value
goes is silent, and a real literal in the same position still matches.

The private-term check: the audit reads a list of terms kept in the git
directory, never in the tree, and fails on any candidate path, file or
unpushed commit that contains one. Each case runs the audit in a scratch
repository.
"""
import atexit
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("audit_public_repo", ROOT / "audit-public-repo.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

RULE = dict(audit.CONTENT_RULES)["inline secret assignment"]


def matches(text: str) -> bool:
    return RULE.search(text) is not None


assert not matches("CaptureIntent.hostScreen(token: tokenA)"), \
    "a bare identifier argument is not a literal secret"
assert not matches("CaptureIntent.hostScreen(token: tokenA) == CaptureIntent.hostScreen(token: tokenA)"), \
    "the same shape repeated (both call sites in the real test file) must not match either"
assert not matches("SessionStateMachine(captureIntent: .hostScreen(token: tokenA))"), \
    "a bare identifier still reads as an identifier when nested one call deeper"
assert not matches("password = adminPassword;"), \
    "a bare identifier terminated by a semicolon is excluded the same way as one terminated by a parenthesis"
assert not matches("secret: nextValue,\n"), \
    "a bare identifier terminated by a comma (a middle argument, not the last) is excluded the same way"

# A dotted member-access path is no more a hardcoded secret than a bare identifier.
assert not matches("token: scenario.token,"), \
    "a dotted member-access path is not a literal secret"
assert not matches("guard.admit(deviceKey: key, token: fixture.expectedToken)"), \
    "a dotted path nested inside a real call, not just the minimal reproduction, is still excluded"
assert not matches("secret: config.nested.value;"), \
    "a path more than one dot deep is still a reference, not a literal, and is excluded the same way"

# A reference invoked as a call -- the identifier or dotted path is itself
# calling something, not holding a value -- is excluded too.
assert not matches("let token = Self.secureRandomToken()"), \
    "a dotted reference immediately invoked with empty parens is not a literal secret"
assert not matches("token: Data([0x01, 0x02])"), \
    "a bare identifier immediately invoked with a literal argument (constructing fixture bytes, not holding a secret string) must not match"
assert not matches("token = offerAndExtractToken(fixture.controller)"), \
    "a bare identifier naming a function, invoked with a reference argument, must not match"

# A reference that is the right-hand side of a `guard`/`if let ... else`
# binding is excluded the same way as an argument reference.
assert not matches("guard let token = wire.hostScreenToken else {"), \
    "a dotted reference bound by `guard let ... else` is not a literal secret"
assert not matches("if let apiKey = self.config.apiKey else {"), \
    "a deeper dotted path in the identical `if let ... else` position is still excluded"

# A reference that names an Optional type, not a value, is excluded the
# same way: a Swift parameter like `token: Data?` binds no literal at all.
assert not matches("func selectRealScreen(token: Data?)"), \
    "an Optional-typed parameter is not a literal secret"
assert not matches("func selectRealScreen(token: Data?) {}"), \
    "the same parameter shape with a following function body brace is still excluded"

# A reference that is the source of an `as`/`as?`/`as!` cast is excluded
# the same way: casting a reference to a type is not holding a literal
# secret value either.
assert not matches("let token = sender.representedObject as? Data"), \
    "a dotted reference cast with `as?` is not a literal secret"
assert not matches("let secret = value as! Data"), \
    "the same shape with a forced cast (`as!`) is still excluded"
assert not matches("let apiKey = config.rawKey as Data"), \
    "the same shape with an unconditional cast (`as`, no `?` or `!`) is still excluded"

# A reference position with no identifier at all -- the terminator sitting
# directly after the colon, no space, no name -- is excluded too: prose
# naming a parameter label by itself holds no value.
assert not matches("`token:)`/`shouldStartHostScreenRequest`"), \
    "a parameter label closed by its own paren, immediately followed by an unrelated code span with " \
    "no space between, is not a literal secret"
assert not matches("(token:)"), \
    "the same shape without the surrounding markdown backticks is still excluded"
assert not matches("secret:,"), \
    "the same shape terminated by a comma instead of a parenthesis is still excluded"

# The zero-identifier exclusion only covers terminators that cannot start a
# value in that same label-only shape -- `)`, `?`, `else`, `as` -- never
# `(`, `,`, or `;`, which a real literal can start with when nothing
# precedes it.
assert matches("token = (abcdef1234567890)"), \
    "a literal immediately wrapped in its own parens, nothing before the paren -- must still match: an" \
    " opening paren is never a terminator, identifier-less or not"
assert matches("secret: (abcdef1234567890)"), \
    "the same shape with a colon separator instead of `=` must still match"
assert matches("token: ,abcdef1234567890"), \
    "a literal immediately preceded by a bare comma -- nothing before it -- must still match: a comma" \
    " terminates an argument that came before it, never stands in for one"
assert matches("token = ;abcdef1234567890"), \
    "the same shape with a semicolon in place of the comma must still match"

# A genuine literal in the exact same syntactic position is still caught:
# proof this narrowed the false-positive shape specifically, not secret
# detection generally.
assert matches('CaptureIntent.hostScreen(token: "abcdef123456")'), \
    "a quoted literal passed in the identical argument position as the false positive still matches"
assert matches('token: "scenario.token"'), \
    "a quoted string that merely looks like a dotted path is still a literal and still matches -- the quotes, not the shape of what is inside them, decide this one"
assert matches('password = "hunter2fallback"'), \
    "a quoted string literal assignment still matches"
assert matches("apiKey = 0xDEADBEEF12345678"), \
    "an unquoted numeric/hex literal still matches -- it cannot be mistaken for an identifier, since identifiers cannot start with a digit"
assert matches("secret: correct-horse-battery-staple"), \
    "an unquoted value containing hyphens cannot be an identifier in any language this rule needs to cover, so it is never excluded regardless of what terminates it"
assert matches("token=abc123xyz456\n"), \
    "a bare identifier-shaped value with no call/statement terminator after it -- end of line, the shape an unquoted secret takes in a shell or .env-style config line -- still matches; only the specific argument-position shape (immediately followed by `)`, `,`, or `;`) is excluded"
assert matches("token=abc123xyz456"), \
    "the same value at true end of string (no trailing newline) still matches too"
assert matches('token: "abcdef123456"(x)'), \
    "a quoted literal immediately followed by a call still matches -- only a bare identifier invoking one is excluded"
assert matches('secret = "hunter2fallback" else {'), \
    "a quoted literal in the identical `... else` position as the guard-let false positive still matches"


# A `_key`/`_token` compound name and a JSON-quoted key must both match.
assert matches("secret_key=abcdef1234567890"), \
    "a `_key`-suffixed keyword assigned a literal must match -- the suffix does not turn it into a" \
    " different, unmonitored word"
assert matches('"token": "abcdef1234567890"'), \
    "a JSON-quoted key assigned a quoted literal must match -- the closing quote before the colon" \
    " must not hide the keyword from the rule"

print("PASS: audit-public-repo inline-secret-assignment fixtures")

# ---------------------------------------------------------------------------
# Private terms
# ---------------------------------------------------------------------------

AUDIT_SCRIPT = ROOT / "audit-public-repo.py"
TERM = "zz-private-sample-term"
PASS_LINE = "PASS: public-repository audit found no sensitive tracked or unignored candidates"

SCRATCH = Path(tempfile.mkdtemp(prefix="audit-private-terms-")).resolve()
atexit.register(shutil.rmtree, SCRATCH, ignore_errors=True)

# A scratch repository must not inherit the caller's git configuration, hooks
# or repository selection (this test may run from inside a git hook).
GIT_ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
GIT_ENV.update({
    "HOME": str(SCRATCH),
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_AUTHOR_NAME": "Sample Author",
    "GIT_AUTHOR_EMAIL": "author@example.invalid",
    "GIT_COMMITTER_NAME": "Sample Author",
    "GIT_COMMITTER_EMAIL": "author@example.invalid",
})
_counter = 0


def git(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=cwd, env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    output = result.stdout.decode("utf-8", "replace")
    assert result.returncode == 0, f"git {' '.join(args)} failed: {output}"
    return output.strip()


def write(repo: Path, relative: str, content: str | bytes) -> None:
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)


def commit_all(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "--allow-empty", "-m", message)
    return git(repo, "rev-parse", "--short", "HEAD")


def next_directory() -> Path:
    global _counter
    _counter += 1
    return SCRATCH / f"repo{_counter}"


def new_repo() -> Path:
    repo = next_directory()
    repo.mkdir()
    git(repo, "init", "-q", "-b", "main")
    (repo / "Scripts").mkdir()
    shutil.copy(AUDIT_SCRIPT, repo / "Scripts" / "audit-public-repo.py")
    write(repo, ".gitignore", "ignored.txt\n")
    write(repo, "README.md", "A harmless sample file.\n")
    commit_all(repo, "Initial commit")
    return repo


def clone(origin: Path) -> Path:
    target = next_directory()
    git(SCRATCH, "clone", "-q", str(origin), str(target))
    return target


def set_terms(repo: Path, text: str) -> None:
    common = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    (common / "info").mkdir(exist_ok=True)
    (common / "info" / "private-terms").write_text(text)


def audit(repo: Path) -> tuple[int, list[str]]:
    result = subprocess.run(
        [sys.executable, str(repo / "Scripts" / "audit-public-repo.py")],
        cwd=SCRATCH, env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    return result.returncode, result.stdout.decode("utf-8", "replace").splitlines()


def assert_passes(repo: Path, why: str) -> None:
    code, lines = audit(repo)
    assert (code, lines) == (0, [PASS_LINE]), f"{why}: expected a silent pass, got {code} {lines}"


def assert_flags(repo: Path, finding: str, why: str, *, path_names_term: bool = False) -> None:
    code, lines = audit(repo)
    assert code == 1, f"{why}: expected exit 1, got {code} {lines}"
    assert f"  {finding}" in lines, f"{why}: expected {finding!r} in {lines}"
    if not path_names_term:
        assert not any(TERM in line.lower() for line in lines), f"{why}: output echoed the term: {lines}"


# A term in a tracked text file fails, naming the path and the category only.
repo = new_repo()
write(repo, "notes.txt", f"first line\nsecond {TERM} line\n")
commit_all(repo, "Add notes")
set_terms(repo, TERM + "\n")
assert_flags(repo, "notes.txt: private term", "a tracked text file")

# A term in a path fails even when the content is harmless.
repo = new_repo()
write(repo, f"docs/{TERM}-guide.md", "Nothing to see.\n")
commit_all(repo, "Add guide")
set_terms(repo, TERM + "\n")
assert_flags(repo, f"docs/{TERM}-guide.md: private term", "a path", path_names_term=True)

# A term inside binary content fails, with no size cap and no per-file exemption.
repo = new_repo()
write(repo, "media/picture.png", b"\x89PNG\r\n\x1a\n\0\0" + TERM.encode() + b"\0\x01")
write(repo, "media/large.bin", b"\0" * 2_100_000 + TERM.encode())
commit_all(repo, "Add media")
set_terms(repo, TERM + "\n")
assert_flags(repo, "media/picture.png: private term", "a small binary file")
assert_flags(repo, "media/large.bin: private term", "a binary file above the size cap")

# The audit's own script is checked like any other file.
repo = new_repo()
write(repo, "Scripts/audit-public-repo.py", AUDIT_SCRIPT.read_text() + f"\n# {TERM}\n")
commit_all(repo, "Edit audit")
set_terms(repo, TERM + "\n")
assert_flags(repo, "Scripts/audit-public-repo.py: private term", "the audit script itself")

# An untracked, non-ignored file fails; an ignored file does not.
repo = new_repo()
set_terms(repo, TERM + "\n")
write(repo, "ignored.txt", f"{TERM}\n")
assert_passes(repo, "an ignored file")
write(repo, "loose.txt", f"{TERM}\n")
assert_flags(repo, "loose.txt: private term", "an untracked file")

# Matching ignores case in both directions.
repo = new_repo()
write(repo, "mixed.txt", "Zz-PRIVATE-Sample-TERM\n")
commit_all(repo, "Add mixed case")
set_terms(repo, TERM + "\n")
assert_flags(repo, "mixed.txt: private term", "an upper-case occurrence")
write(repo, "mixed.txt", f"{TERM}\n")
set_terms(repo, TERM.upper() + "\n")
assert_flags(repo, "mixed.txt: private term", "an upper-case term")

# Comments, blank lines and surrounding whitespace in the terms file.
repo = new_repo()
write(repo, "notes.txt", f"{TERM}\n")
commit_all(repo, "Add notes")
set_terms(repo, f"# {TERM}\n\n   \n  # {TERM}\n")
assert_passes(repo, "a terms file with only comments and blank lines")
set_terms(repo, f"# header\n\n   {TERM}  \n")
assert_flags(repo, "notes.txt: private term", "a term padded with whitespace")

# A missing terms file means no check and no message.
repo = new_repo()
write(repo, "notes.txt", f"{TERM}\n")
commit_all(repo, "Add notes")
assert_passes(repo, "no terms file")

# The terms file is found from a linked worktree.
repo = new_repo()
set_terms(repo, TERM + "\n")
linked = next_directory()
git(repo, "worktree", "add", "-q", "-b", "side", str(linked))
write(linked, "notes.txt", f"{TERM}\n")
assert_flags(linked, "notes.txt: private term", "a linked worktree")
os.remove(linked / "notes.txt")
assert_passes(linked, "a clean linked worktree")

# Unpushed commits: the message and the full patch are checked. A repository
# with no upstream skips this part.
origin = new_repo()
write(origin, "published.txt", f"{TERM}\n")
commit_all(origin, f"Publish {TERM}")
git(origin, "rm", "-q", "published.txt")
commit_all(origin, "Remove published file")

standalone = new_repo()
write(standalone, "gone.txt", f"{TERM}\n")
commit_all(standalone, f"Add {TERM}")
git(standalone, "rm", "-q", "gone.txt")
commit_all(standalone, "Remove it again")
set_terms(standalone, TERM + "\n")
assert_passes(standalone, "history of a branch with no upstream")

work = clone(origin)
set_terms(work, TERM + "\n")
assert_passes(work, "terms only in commits already on the upstream")
write(work, "plain.txt", "A harmless change.\n")
commit_all(work, "Harmless change")
assert_passes(work, "a harmless unpushed commit")

message_sha = commit_all(work, f"Mention {TERM.upper()} in a message")
assert_flags(work, f"commit {message_sha}: private term", "an unpushed commit message")

work = clone(origin)
set_terms(work, TERM + "\n")
write(work, "temp.txt", f"{TERM}\n")
added_sha = commit_all(work, "Add a scratch file")
git(work, "rm", "-q", "temp.txt")
commit_all(work, "Remove the scratch file")
assert_flags(work, f"commit {added_sha}: private term", "a term added then removed in unpushed commits")

work = clone(origin)
set_terms(work, TERM + "\n")
write(work, "temp.bin", b"\x89PNG\0\0" + TERM.encode() + b"\0\x01")
binary_sha = commit_all(work, "Add a scratch binary")
git(work, "rm", "-q", "temp.bin")
commit_all(work, "Remove the scratch binary")
assert_flags(work, f"commit {binary_sha}: private term", "a term in a binary file added then removed")

work = clone(origin)
set_terms(work, TERM + "\n")
write(work, "twice.txt", f"{TERM}\n")
twice_sha = commit_all(work, f"Message and patch both carry {TERM}")
git(work, "rm", "-q", "twice.txt")
commit_all(work, "Remove it")
code, lines = audit(work)
assert lines.count(f"  commit {twice_sha}: private term") == 1, \
    f"a commit with the term in both message and patch is reported once: {lines}"

print("PASS: audit-public-repo private-term fixtures")
