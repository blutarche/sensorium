#!/usr/bin/env python3
"""Fixture-driven unit test for summarize-motion-switches.py.

The SPS values are real ones: the sequence parameter sets VideoToolbox's
H.264 encoder produced for those frame sizes. The packet logs are built here
the way the stand-in host writes them. No host, viewer or network involved.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "summarize_motion_switches", ROOT / "summarize-motion-switches.py"
)
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)

SETTLED_SPS = "2742c033ab4017806afda0"  # 3008x1692, constrained baseline
MOVING_SPS = "2742c028ab403c0113f2a0"  # 1920x1080, constrained baseline

# --- SPS sizes, including the cropped heights (1692 and 1080 are not
# multiples of 16) and a profile that carries a chroma format.
for sps, size in [
    (SETTLED_SPS, (3008, 1692)),
    (MOVING_SPS, (1920, 1080)),
    ("2742c032ab403c012f20", (1920, 1200)),
    ("2742c033ab401e0021f2", (3840, 2160)),
    ("2742c01fab402782df5320", (1262, 710)),
    ("274d0028ab280f0044fca8", (1920, 1080)),
    ("27640033ac56500bc0357ed0", (3008, 1692)),
]:
    assert summary.sps_size(sps) == size, (sps, summary.sps_size(sps), size)
assert summary.sps_size("") is None
assert summary.sps_size("2742") is None, "a truncated parameter set has no size"
assert summary.sps_size("68ce3c80") is None, "a picture parameter set is not a sequence parameter set"


def line(**fields):
    return json.dumps(fields, sort_keys=True)


def log(cycles, end_size=SETTLED_SPS, delta_switch=False):
    """A stand-in log: `cycles` times a 1 s moving stretch at 60 packets a
    second and a 2 s rest, then the settled picture."""
    lines = [line(kind="config", t=0, settled="3008x1692", moving="1920x1080")]
    seq = 0
    t = 0
    lines.append(line(kind="packet", t=t, seq=seq, key=True, bytes=1_700_000, sps=SETTLED_SPS))
    for cycle in range(cycles):
        t += 2_000_000_000
        seq += 1
        # The change of size to the moving picture: a key frame, or, in the
        # broken case, a delta frame.
        lines.append(line(kind="packet", t=t, seq=seq, key=not delta_switch, bytes=300_000, **({} if delta_switch else {"sps": MOVING_SPS})))
        for _ in range(59):
            t += 16_000_000
            seq += 1
            lines.append(line(kind="packet", t=t, seq=seq, key=False, bytes=36_000))
        t += 520_000_000
        seq += 1
        last_size = SETTLED_SPS if cycle < cycles - 1 else end_size
        lines.append(line(kind="packet", t=t, seq=seq, key=True, bytes=1_700_000, sps=last_size))
        lines.append(line(kind="viewer", t=t + 300_000_000, presentedFps=40.0, decodedFps=41.0, receivedBps=9_000_000.0))
        lines.append(line(kind="viewer", t=t + 1_300_000_000, presentedFps=1.0, decodedFps=1.0, receivedBps=1_000_000.0))
    return "\n".join(lines) + "\n"


report = summary.analyse(summary.parse_log(log(6)))
assert report["settled"] == "3008x1692" and report["moving"] == "1920x1080"
assert report["sizes"] == ["1920x1080", "3008x1692"], report["sizes"]
assert report["cycles"] == 6, report["cycles"]
assert len(report["switches"]) == 12
first, second = report["switches"][0], report["switches"][1]
assert (first["from"], first["to"], first["kind"]) == ("3008x1692", "1920x1080", "motion")
assert (second["from"], second["to"], second["kind"]) == ("1920x1080", "3008x1692", "settle")
assert first["key_frame_bytes"] == 300_000 and second["key_frame_bytes"] == 1_700_000
assert first["is_key_frame"] and second["is_key_frame"]
assert abs(first["gap_ms"] - 2000.0) < 0.01, first["gap_ms"]
assert abs(second["gap_ms"] - 520.0) < 0.01, second["gap_ms"]
# The two viewer readings logged after the settle switch.
assert second["viewer"] == [(40.0, 41.0), (1.0, 1.0)], second["viewer"]
assert second["viewer_after_ms"] == [300.0, 1300.0], second["viewer_after_ms"]
episode = report["episodes"][0]
# 60 packets over 59 intervals of 16 ms: the key frame and 59 deltas.
assert abs(episode["moving_seconds"] - 0.944) < 0.001, episode
assert abs(episode["moving_bytes_per_second"] - (300_000 + 59 * 36_000) / 0.944) < 100, episode
# The rest runs from the last moving packet to the next stretch of motion:
# 0.52 s to the settled key frame and 2 s more. Only that key frame is in it.
assert abs(episode["still_seconds"] - 2.52) < 0.001, episode
assert episode["still_bytes"] == 1_700_000
assert abs(episode["still_bytes_per_second"] - 1_700_000 / 2.52) < 100, episode
# The last rest has no motion after it: it ends with the log.
assert abs(report["episodes"][-1]["still_seconds"] - 0.52) < 0.001, report["episodes"][-1]
assert report["last_size"] == "3008x1692"

checks = dict((name, ok) for name, ok, _ in summary.verdict(report, {"decodedFrames": 400, "presentedFrames": 380, "longestPresentGapDuringMoveMs": 120.0}))
assert checks["cycles"] and checks["both sizes sent"]
assert checks["ends at the settled size"] and checks["present gap during motion"]

few = summary.analyse(summary.parse_log(log(4)))
assert not dict((n, ok) for n, ok, _ in summary.verdict(few, None))["cycles"], "four cycles are too few"

stuck = summary.analyse(summary.parse_log(log(5, end_size=MOVING_SPS)))
assert stuck["last_size"] == "1920x1080"
assert not dict((n, ok) for n, ok, _ in summary.verdict(stuck, None))["ends at the settled size"]

broken = summary.analyse(summary.parse_log(log(5, delta_switch=True)))
assert not dict((n, ok) for n, ok, _ in summary.verdict(broken, None))["both sizes sent"], "no parameter set ever named the moving size"

slow = dict((n, ok) for n, ok, _ in summary.verdict(report, {"decodedFrames": 400, "presentedFrames": 380, "longestPresentGapDuringMoveMs": 300.0}))
assert not slow["present gap during motion"], "a present gap over 250 ms fails"

# Through the command line, with the viewer's own report beside it.
with tempfile.TemporaryDirectory() as directory:
    packets = Path(directory) / "run.packets"
    packets.write_text(log(6))
    viewer = Path(directory) / "run.bench-viewer.json"
    viewer.write_text(json.dumps({"decodedFrames": 400, "presentedFrames": 380, "longestPresentGapDuringMoveMs": 120.0}))
    done = subprocess.run(
        [sys.executable, "-I", str(ROOT / "summarize-motion-switches.py"), str(packets), str(viewer)],
        capture_output=True, text=True,
    )
    assert done.returncode == 0, done.stdout + done.stderr
    assert "3008x1692" in done.stdout and "1920x1080" in done.stdout and "settle" in done.stdout, done.stdout
    assert "PASS cycles" in done.stdout, done.stdout
    failing = subprocess.run(
        [sys.executable, "-I", str(ROOT / "summarize-motion-switches.py"), str(packets)],
        capture_output=True, text=True,
    )
    assert failing.returncode == 0, "no viewer report is not a failure of the host side"
    packets.write_text(log(2))
    short = subprocess.run(
        [sys.executable, "-I", str(ROOT / "summarize-motion-switches.py"), str(packets)],
        capture_output=True, text=True,
    )
    assert short.returncode == 1 and "FAIL cycles" in short.stdout, short.stdout

print("PASS: summarize-motion-switches reads sizes from sequence parameter sets and judges the switches")
