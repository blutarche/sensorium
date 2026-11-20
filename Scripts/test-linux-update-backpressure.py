#!/usr/bin/env python3
"""Run a deterministic test of the production Linux transport router.

Callbacks are driven directly with suspended URLSession tasks and a gated sink;
no network server, actual disk stall, or timing-dependent flood is required.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/Sensorium/main.swift').read_text()
start = source.index('struct URLSessionLinuxUpdateTransport:')
source = source[start:source.index('\n@main\n', start)]
stubs = (root / 'Scripts/test-linux-update-transport.swift').read_text()
test = (root / 'Scripts/test-linux-update-backpressure.swift').read_text()
with tempfile.TemporaryDirectory(prefix='sensorium-backpressure-') as directory:
    directory = Path(directory)
    swift = directory / 'test.swift'
    swift.write_text(stubs + '\n' + source + '\n' + test)
    for flags in ([], ['-O']):
        print('Configuration:', 'release' if flags else 'debug', flush=True)
        binary = directory / 'test'
        subprocess.run(['swiftc', '-parse-as-library', *flags, str(swift), '-o', str(binary)], check=True, timeout=120)
        subprocess.run([str(binary)], check=True, timeout=30)
