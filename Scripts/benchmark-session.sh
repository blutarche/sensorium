#!/bin/sh
# Placeholder for the benchmark harness.
#
# It intentionally does nothing yet. Benchmarking requires a live session, which
# requires Screen Recording and Accessibility approval and a second machine.
# Publishing a number this project has not measured would be worse than
# publishing none.
set -eu

cat <<NOTE
No benchmark harness yet.

Before this script can do anything real:
  1. A session must run end to end (docs/install.md).
  2. Record the route with Scripts/verify-tailscale-route.sh, direct or DERP.
  3. Capture SessionMetrics traceLines() for capture, encode, send, receive,
     decode, present, and input round-trip.
  4. Record the results with machine and network conditions noted.
NOTE
exit 1
