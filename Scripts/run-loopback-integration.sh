#!/bin/sh
# Runs the in-process host/client loopback: pairing, authenticated handshake,
# canvas lifecycle, input path, and the recovery scenarios.
#
# No socket is opened and no permission is used: the transport is in-memory and
# the display adapter is a fake. For a real cross-machine run see docs/install.md.
set -eu

cd "$(dirname "$0")/.."
swift build
swift run SensoriumIntegrationTestRunner
