#!/usr/bin/env python3
"""Exercises the Linux self-update release tooling without a network.

It covers three scripts:

* Scripts/test-linux-update-archive.sh, against good and malformed archives.
* Scripts/make-linux-update-archive.sh, when GNU tar is installed.
* Scripts/sign-linux-update.sh, in a scratch copy of the repository layout.
  `gh` is a logging stub on PATH, the update key is generated into a scratch
  folder, and the key compiled into the scratch tree is that key's public
  half. Nothing here reaches GitHub or reads the real update key.
"""
import hashlib
import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Scripts"
VERSION = "9.8.7"
TAG = f"v{VERSION}"
TARBALL = f"Sensorium-{VERSION}-linux-x86_64.tar.gz"
MANIFEST = "sensorium-update-linux-x86_64.json"
BINARY = b"\x7fELF fixture viewer binary\n"

passed = 0


def check(condition, message):
    global passed
    if not condition:
        print(f"FAIL: {message}", file=sys.stderr)
        sys.exit(1)
    passed += 1
    print(f"PASS: {message}")


def run(args, env=None, cwd=None):
    merged = dict(os.environ)
    merged.update(env or {})
    return subprocess.run(args, env=merged, cwd=cwd, capture_output=True, text=True)


def write_executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def build_archive(path, members):
    """members: (name, kind, mode, uid, content) tuples; kind is file, dir or link."""
    with tarfile.open(path, "w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name, kind, mode, uid, content in members:
            info = tarfile.TarInfo(name)
            info.mode = mode
            info.uid = info.gid = uid
            info.mtime = 1700000000
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            elif kind == "link":
                info.type = tarfile.SYMTYPE
                info.linkname = "/bin/sh"
                archive.addfile(info)
            else:
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))


GOOD = [("Sensorium", "file", 0o755, 0, BINARY)]


def sha256_of(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def gnu_tar_available():
    probe = run(["tar", "--version"])
    return probe.returncode == 0 and "GNU tar" in probe.stdout


work = Path(tempfile.mkdtemp(prefix="sensorium-linux-update-test."))
try:
    # ---- the archive check -------------------------------------------------
    checker = SCRIPTS / "test-linux-update-archive.sh"
    good = work / "good.tar.gz"
    build_archive(good, GOOD)
    result = run(["sh", str(checker), str(good)])
    check(result.returncode == 0, f"a one-file archive passes the archive check ({result.stderr.strip()})")

    bad_cases = {
        "a second entry": GOOD + [("extra", "file", 0o644, 0, b"x")],
        "a different name": [("sensorium", "file", 0o755, 0, BINARY)],
        "a leading ./": [("./Sensorium", "file", 0o755, 0, BINARY)],
        "an absolute path": [("/Sensorium", "file", 0o755, 0, BINARY)],
        "a parent directory": [("../Sensorium", "file", 0o755, 0, BINARY)],
        "a directory entry": [("Sensorium", "dir", 0o755, 0, b"")],
        "a symbolic link": [("Sensorium", "link", 0o755, 0, b"")],
        "no execute bit": [("Sensorium", "file", 0o644, 0, BINARY)],
        "group write access": [("Sensorium", "file", 0o775, 0, BINARY)],
        "an owner other than root": [("Sensorium", "file", 0o755, 1000, BINARY)],
        "no content": [("Sensorium", "file", 0o755, 0, b"")],
    }
    for label, members in bad_cases.items():
        path = work / "bad.tar.gz"
        build_archive(path, members)
        result = run(["sh", str(checker), str(path)])
        check(result.returncode != 0 and "FAIL" in result.stderr, f"the archive check refuses {label}")
    result = run(["sh", str(checker), str(work / "missing.tar.gz")])
    check(result.returncode != 0, "the archive check refuses a missing file")
    garbage = work / "garbage.tar.gz"
    garbage.write_bytes(b"not an archive")
    result = run(["sh", str(checker), str(garbage)])
    check(result.returncode != 0, "the archive check refuses a file that is not an archive")

    # ---- the archive maker -------------------------------------------------
    maker = SCRIPTS / "make-linux-update-archive.sh"
    if not maker.exists():
        check(False, "Scripts/make-linux-update-archive.sh exists")
    if gnu_tar_available():
        binary = work / "viewer-binary"
        binary.write_bytes(BINARY)
        binary.chmod(0o700)
        outputs = []
        for index, mtime in enumerate((1_600_000_000, 1_650_000_000)):
            os.utime(binary, (mtime, mtime))
            out = work / f"out{index}"
            out.mkdir()
            result = run(["sh", str(maker), str(binary), str(out)], env={"SOURCE_DATE_EPOCH": "1700000000"})
            check(result.returncode == 0, f"the archive maker runs ({result.stderr.strip()})")
            outputs.append(out / f"Sensorium-{(ROOT / 'VERSION').read_text().strip()}-linux-x86_64.tar.gz")
        check(outputs[0].read_bytes() == outputs[1].read_bytes(), "the archive is byte for byte reproducible")
        result = run(["sh", str(checker), str(outputs[0])])
        check(result.returncode == 0, f"the archive the maker writes passes the archive check ({result.stderr.strip()})")
        with tarfile.open(outputs[0]) as archive:
            member = archive.getmembers()[0]
            check(member.mtime == 1700000000, "the archive carries SOURCE_DATE_EPOCH as its time")
            check(member.uname == "" and member.gname == "", "the archive carries no owner names")
            check(archive.extractfile(member).read() == BINARY, "the archive holds the binary it was given")
        recorded = Path(str(outputs[0]) + ".sha256").read_text().split()
        check(recorded == [sha256_of(outputs[0]), outputs[0].name], "the .sha256 names the archive and its hash")
        result = run(["sh", str(maker), str(work / "absent"), str(work / "out0")], env={"SOURCE_DATE_EPOCH": "1"})
        check(result.returncode != 0, "the archive maker refuses a binary that is not there")
    else:
        print("SKIP: the archive maker needs GNU tar; this machine has another tar")

    # ---- the signing script, in a scratch layout ---------------------------
    scratch = work / "repo"
    (scratch / "Scripts").mkdir(parents=True)
    (scratch / "Sources/SensoriumUpdate").mkdir(parents=True)
    for name in ("sign-linux-update.sh", "sign-update.swift", "test-linux-update-archive.sh"):
        shutil.copy(SCRIPTS / name, scratch / "Scripts" / name)
    (scratch / "VERSION").write_text(VERSION + "\n")

    key = work / "update-key"
    keygen = run(["swift", str(SCRIPTS / "sign-update.swift"), "generate", str(key)])
    check(keygen.returncode == 0, f"a throwaway key is generated ({keygen.stderr.strip()})")
    public_key = keygen.stdout.strip()
    (scratch / "Sources/SensoriumUpdate/UpdatePublicKey.swift").write_text(
        f'public enum UpdatePublicKey {{\n    public static let base64 = "{public_key}"\n}}\n'
    )

    stubs = work / "bin"
    stubs.mkdir()
    gh_log = work / "gh.log"
    fixture_dir = work / "release"
    fixture_dir.mkdir()
    # A release page with a tarball on it: `release download` copies the file
    # named by --pattern from the fixture folder, `release upload` is logged.
    write_executable(
        stubs / "gh",
        """#!/bin/sh
printf '%s\\n' "gh $*" >> "$STUB_GH_LOG"
[ "$1 $2" = "release download" ] || exit 0
[ "${STUB_GH_MODE:-}" = fail ] && exit 1
tag="$3"; shift 3
while [ $# -gt 0 ]; do
    case "$1" in
        --pattern) pattern="$2"; shift 2 ;;
        --dir) dir="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ "${STUB_GH_MODE:-}" = empty ] && exit 0
[ -f "$STUB_GH_FIXTURES/$pattern" ] || { echo "no asset matches $pattern" >&2; exit 1; }
cp "$STUB_GH_FIXTURES/$pattern" "$dir/$pattern"
""",
    )
    release_tarball = fixture_dir / TARBALL
    build_archive(release_tarball, GOOD)

    def sign(*args, tag=TAG, mode="", output=None, extra_env=None):
        gh_log.write_text("")
        (work / "tmp").mkdir(exist_ok=True)
        env = {
            "PATH": f"{stubs}:{os.environ['PATH']}",
            "STUB_GH_LOG": str(gh_log),
            "STUB_GH_FIXTURES": str(fixture_dir),
            "STUB_GH_MODE": mode,
            "SENSORIUM_UPDATE_KEY": str(key),
            "TMPDIR": str(work / "tmp"),
        }
        env.update(extra_env or {})
        if output is not None:
            env["SENSORIUM_LINUX_UPDATE_DIR"] = str(output)
        return run(["sh", str(scratch / "Scripts/sign-linux-update.sh"), tag, *args], env=env, cwd=work)

    def gh_calls():
        return gh_log.read_text().splitlines()

    result = sign("--dry-run", tag="v9.8.6")
    check(result.returncode != 0 and "VERSION" in result.stderr, "a tag that does not match VERSION is refused")
    check(gh_calls() == [], "a mismatched tag reaches nothing on GitHub")
    result = sign("--dry-run", tag=VERSION)
    check(result.returncode != 0 and gh_calls() == [], "a tag without the leading v is refused")
    result = sign("--dry-run", "--nonsense")
    check(result.returncode == 2 and gh_calls() == [], "an unknown option is refused with the usage exit")
    result = run(["sh", str(scratch / "Scripts/sign-linux-update.sh")])
    check(result.returncode == 2, "a missing tag is refused with the usage exit")

    result = sign("--dry-run", mode="fail")
    check(result.returncode != 0 and "tarball" in result.stderr, "a failed download is refused")
    result = sign("--dry-run", mode="empty")
    check(result.returncode != 0 and "tarball" in result.stderr, "a download that leaves no tarball is refused")
    release_tarball.rename(fixture_dir / "held-back")
    result = sign("--dry-run")
    check(result.returncode != 0 and "tarball" in result.stderr, "a release without the tarball is refused")
    (fixture_dir / "held-back").rename(release_tarball)

    build_archive(release_tarball, GOOD + [("extra", "file", 0o644, 0, b"x")])
    result = sign("--dry-run")
    check(result.returncode != 0 and "FAIL" in result.stderr, "a malformed tarball is refused before it is signed")
    build_archive(release_tarball, GOOD)

    result = sign("--dry-run", extra_env={"SENSORIUM_UPDATE_KEY": str(work / "no-such-key")})
    check(result.returncode != 0 and "update key" in result.stderr, "a missing key file is refused")

    other_key = work / "other-key"
    other = run(["swift", str(SCRIPTS / "sign-update.swift"), "generate", str(other_key)])
    check(other.returncode == 0, "a second throwaway key is generated")
    result = sign("--dry-run", extra_env={"SENSORIUM_UPDATE_KEY": str(other_key)})
    check(
        result.returncode != 0 and "compiled" in result.stderr,
        "a key that does not match the one compiled into the apps is refused",
    )

    out = work / "out-dry"
    out.mkdir()
    result = sign("--dry-run", output=out)
    check(result.returncode == 0, f"a dry run succeeds ({result.stderr.strip()})")
    upload_line = f"gh release upload {TAG}"
    check(upload_line in result.stdout.replace('"', ""), "the dry run prints the upload command it would run")
    check(not any(call.startswith("gh release upload") for call in gh_calls()), "the dry run uploads nothing")
    check(
        any(call.startswith(f"gh release download {TAG}") and TARBALL in call for call in gh_calls()),
        "the tarball is downloaded from the release by name",
    )

    manifest = out / MANIFEST
    signature = out / f"{MANIFEST}.sig"
    expected = (
        '{"format":1,"version":"%s","file":"%s","size":%d,"sha256":"%s"}'
        % (VERSION, TARBALL, release_tarball.stat().st_size, sha256_of(release_tarball))
    )
    check(manifest.read_bytes() == expected.encode(), "the manifest is compact JSON in stable key order with the tarball's size and hash")
    sig_text = signature.read_text()
    check(sig_text.endswith("\n") and sig_text.count("\n") == 1, "the signature is one line")
    check(len(__import__("base64").b64decode(sig_text.strip(), validate=True)) == 64, "the signature is the base64 of 64 bytes")
    verify = run(["swift", str(SCRIPTS / "sign-update.swift"), "verify", public_key, str(manifest), str(signature)])
    check(verify.returncode == 0, f"the signature verifies with the throwaway public key ({verify.stderr.strip()})")
    tampered = work / "tampered.json"
    tampered.write_bytes(manifest.read_bytes().replace(b'"format":1', b'"format":2'))
    verify = run(["swift", str(SCRIPTS / "sign-update.swift"), "verify", public_key, str(tampered), str(signature)])
    check(verify.returncode != 0, "the signature does not verify for changed manifest bytes")
    check(key.read_text().strip() not in result.stdout + result.stderr, "the private key is never printed")

    out_live = work / "out-live"
    out_live.mkdir()
    result = sign(output=out_live)
    check(result.returncode == 0, f"a real run succeeds ({result.stderr.strip()})")
    uploads = [call for call in gh_calls() if call.startswith("gh release upload")]
    check(len(uploads) == 2, "a real run uploads twice")
    check(
        uploads[0].endswith(f"{MANIFEST}.sig --clobber") and uploads[1].endswith(f"{MANIFEST} --clobber"),
        "the signature goes up first, then the manifest, each replacing an earlier copy",
    )
    printed = result.stdout.replace('"', "")
    check(uploads[0] in printed and uploads[1] in printed, "the upload commands are printed")
    check(printed.index(uploads[0]) < printed.index("Uploaded"), "the commands are printed before they run")
    check((out_live / MANIFEST).read_bytes() == manifest.read_bytes(), "signing the same tarball again gives the same manifest")

    reuse = sign("--dry-run", output=out)
    check(reuse.returncode != 0, "a working folder that is not empty is refused")

    leftovers = [p for p in (work / "tmp").iterdir() if p.name.startswith("sensorium-linux-update.")]
    check(leftovers == [], f"no scratch folder is left behind {leftovers}")
finally:
    shutil.rmtree(work, ignore_errors=True)

print(f"All {passed} checks passed")
