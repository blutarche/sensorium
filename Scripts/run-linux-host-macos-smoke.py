#!/usr/bin/env python3
"""Run the Linux host fixture and the macOS viewer without a desktop session."""

import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "SensoriumLinuxHostTestRunner"
IMAGE = os.environ.get("SENSORIUM_LINUX_SMOKE_IMAGE", "sensorium-linux-dev:44")
CACHE = "sensorium-linux-host-smoke-build"


def output(*command):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, cwd=ROOT, timeout=15)


def safe_log(log):
    log = re.sub(r"(?m)^PAIRING \d{6}$", "PAIRING [redacted]", log)
    return re.sub(r"\b[0-9a-f]{64}\b", "[redacted]", log)


def wait_for_host(container, proof):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        log = output("docker", "logs", container)
        if proof in log:
            return log
        if output("docker", "inspect", "--format", "{{.State.Running}}", container).strip() != "true":
            break
        time.sleep(0.1)
    raise RuntimeError(f"Linux host did not report {proof!r}\n{safe_log(output('docker', 'logs', container))}")


def run():
    if sys.platform != "darwin":
        raise RuntimeError("The viewer smoke runs on macOS.")
    subprocess.run(["swift", "build", "-c", "release", "--product", PRODUCT], cwd=ROOT, check=True)
    subprocess.run([
        "docker", "run", "--rm", "--pull=never", "--network=none",
        "-v", f"{ROOT}:/src:ro", "-v", f"{CACHE}:/build", IMAGE,
        "swift", "build", "--package-path", "/src", "--scratch-path", "/build", "-c", "release",
        "--product", PRODUCT,
    ], cwd=ROOT, check=True)
    container = output(
        "docker", "run", "-d", "--pull=never", "-p", "127.0.0.1::7777/udp",
        "-v", f"{CACHE}:/build:ro", "-e", "SENSORIUM_INTEROP_SMOKE=1", IMAGE,
        "stdbuf", "-oL", f"/build/release/{PRODUCT}", "host", "/tmp/sensorium-fixture", "0.0.0.0", "7777",
    ).strip()
    try:
        host_log = wait_for_host(container, "host screen offered: true")
        match = re.search(r"(?m)^PAIRING (\d{6})$", host_log)
        if not match:
            raise RuntimeError("The Linux fixture did not issue a pairing code.")
        port = output("docker", "port", container, "7777/udp").strip().split(":")[-1]
        viewer = subprocess.run([
            str(ROOT / ".build" / "release" / PRODUCT), "view", "127.0.0.1", port, "-", "1",
        ], cwd=ROOT, env={**os.environ, "SENSORIUM_INTEROP_SMOKE": "1"},
            input=match[1] + "\n", timeout=30, text=True, capture_output=True)
        viewer_log = viewer.stdout + viewer.stderr
        print(safe_log(viewer_log), end="")
        print(f"macOS viewer exit={viewer.returncode}")
        if viewer.returncode != 0 or not all(
            proof in viewer_log for proof in (
                "VIEW Linux host suppresses macOS shortcuts",
                "VIEW Metal pixels matched both monitors after switching",
                "VIEW Stop acknowledged",
            )
        ):
            raise RuntimeError("The macOS viewer did not prove monitor switching, shortcut availability, and Stop.")
        proof = "HOST Stop dismissed the indicator and released the held key"
        host_log = wait_for_host(container, proof)
        input_proof = "HOST received pointer and key on the second monitor"
        if input_proof not in host_log:
            raise RuntimeError("The Linux host did not record the test input on the second monitor.")
        print(input_proof)
        print(proof)
    except (RuntimeError, subprocess.TimeoutExpired):
        print(safe_log(output("docker", "logs", container)), file=sys.stderr, end="")
        raise
    finally:
        output("docker", "rm", "-f", container)


if __name__ == "__main__":
    try:
        run()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"FAIL: {error}") from None
