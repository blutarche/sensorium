#!/usr/bin/env python3
"""Exercise transport routing on loopback HTTP; TLS is tested separately.

Only the scheme allow-list is changed in the extracted test copy: Linux
FoundationNetworking uses the system CA bundle and cannot trust a temporary
fixture certificate without changing system trust.
"""
import http.server
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent

def patch(source, old, new, count=1):
    # A gate that silently fails to apply would let a scenario pass vacuously.
    assert source.count(old) == count, f'test gate no longer matches the transport source: {old!r}'
    return source.replace(old, new)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path == '/stream':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'0123456789')
            return
        if self.path == '/stall':
            time.sleep(4)
            return
        if self.path in ('/redirect', '/downgrade'):
            self.send_response(302)
            self.send_header('Location', '/data/one' if self.path == '/redirect' else 'ftp://127.0.0.1:9/')
            self.end_headers()
            return
        if not self.path.startswith('/data/'):
            self.send_response(404)
            self.end_headers()
            return
        data = self.path.removeprefix('/data/').encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

with tempfile.TemporaryDirectory(prefix='sensorium-transport-') as tmp:
    tmp = Path(tmp)
    server = Server(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    source = (ROOT / 'Sources/SensoriumLinuxUpdate/URLSessionLinuxUpdateTransport.swift').read_text()
    source = source[source.index('struct URLSessionLinuxUpdateTransport:'):source.rindex('\n#endif')]
    # Both the address check and the redirect check.
    source = patch(source, '== "https"', '== "http"', count=2)
    # Test-only gates force the two interleavings; production logic is unchanged.
    source = patch(source, 'try await withCheckedThrowingContinuation {', 'if ProcessInfo.processInfo.environment["RACE_TEST"] == "1" { testRegistrationReached.signal(); testRegistrationContinue.wait() }\n            try await withCheckedThrowingContinuation {')
    source = patch(source, 'func write(_ chunk: Data) throws { try handle.write(contentsOf: chunk) }', 'func write(_ chunk: Data) throws { if ["BLOCK_TEST", "OWN_DEADLINE_TEST", "OWN_CANCEL_TEST"].contains(where: { ProcessInfo.processInfo.environment[$0] == "1" }) { testSinkReached.signal(); testSinkContinue.wait() }; try handle.write(contentsOf: chunk) }')
    source = patch(source, 'try handle.synchronize()', 'if ProcessInfo.processInfo.environment["OWN_SYNC_TEST"] == "1" { testSinkReached.signal(); testSinkContinue.wait() }; try handle.synchronize()')
    combined = (ROOT / 'Scripts/test-linux-update-transport.swift').read_text() + '\nlet testRegistrationReached = DispatchSemaphore(value: 0)\nlet testRegistrationContinue = DispatchSemaphore(value: 0)\nlet testSinkReached = DispatchSemaphore(value: 0)\nlet testSinkContinue = DispatchSemaphore(value: 0)\n' + source + '\n' + (ROOT / 'Scripts/test-linux-update-transport-body.swift').read_text()
    swift = tmp / 'test.swift'
    swift.write_text(combined)
    env = os.environ.copy()
    env.update(TEST_HTTPS_BASE=f'http://127.0.0.1:{server.server_port}')
    try:
        for flags in ([], ['-O']):
            subprocess.run(['swiftc', '-parse-as-library', *flags, str(swift), '-o', str(tmp / 'test')], check=True)
            print('Configuration:', 'release' if flags else 'debug', flush=True)
            for mode in ('OWN_SYNC_TEST', 'OWN_DEADLINE_TEST', 'OWN_CANCEL_TEST', 'RACE_TEST', 'BLOCK_TEST', 'NORMAL'):
                mode_env = dict(env, **{mode: '1'})
                print('Scenario:', mode, flush=True)
                subprocess.run([str(tmp / 'test')], check=True, env=mode_env, timeout=45)
    finally:
        server.shutdown()

# Exercise the queued-byte cap deterministically, independently of network speed.
subprocess.run(['python3', str(ROOT / 'Scripts/test-linux-update-backpressure.py')], check=True)
