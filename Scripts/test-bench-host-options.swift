import Foundation

// Checks for the stand-in host's command line and its packet log lines. The
// stand-in is an executable target, which no test runner here can import, so
// `test-bench-host-options.sh` compiles the two Foundation-only sources it
// needs beside this file.

@main
@MainActor
struct BenchHostOptionsChecks {
    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        failures += 1
        print("FAIL: \(message)")
    }

    private static let base = ["mini.tail1234.ts.net", "7790", "--state-dir", "/tmp/state", "--trace", "/tmp/trace"]

    private static func parse(_ extra: [String]) -> Result<BenchHostOptions, BenchHostOptions.ParseError> {
        BenchHostOptions.parse(base + extra)
    }

    private static func rejects(_ extra: [String], _ message: String) {
        if case .success = parse(extra) {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        guard case let .success(plain) = parse([]) else {
            print("FAIL: the unchanged command line must still parse")
            exit(1)
        }
        check(plain.canvasSize == nil, "no --canvas must leave the stand-in at its own picture size")
        check(plain.packetLogPath == nil, "no --packet-log must write no packet log")

        if case let .success(options) = parse(["--canvas", "3008x1692", "--packet-log", "/tmp/packets"]) {
            check(options.canvasSize == BenchHostOptions.CanvasSize(width: 3008, height: 1692), "--canvas 3008x1692 must be read as 3008 by 1692")
            check(options.packetLogPath == "/tmp/packets", "--packet-log must keep its path")
        } else {
            failures += 1
            print("FAIL: --canvas 3008x1692 --packet-log /tmp/packets must parse")
        }
        if case let .success(options) = parse(["--canvas", "4096x2304"]) {
            check(options.canvasSize == BenchHostOptions.CanvasSize(width: 4096, height: 2304), "4096 is the hardware encoder's own limit and must be accepted")
        } else {
            failures += 1
            print("FAIL: --canvas 4096x2304 must parse")
        }

        rejects(["--canvas", "4098x2304"], "a canvas wider than the hardware encoder takes must be refused")
        rejects(["--canvas", "3840x4098"], "a canvas taller than the hardware encoder takes must be refused")
        rejects(["--canvas", "3007x1692"], "an odd width must be refused: 4:2:0 video cannot encode it")
        rejects(["--canvas", "3008x1693"], "an odd height must be refused: 4:2:0 video cannot encode it")
        rejects(["--canvas", "0x0"], "a zero-sized canvas must be refused")
        rejects(["--canvas", "3008"], "a canvas with one number must be refused")
        rejects(["--canvas", "3008x1692x2"], "a canvas with three numbers must be refused")
        rejects(["--canvas", "-3008x1692"], "a negative canvas must be refused")
        rejects(["--canvas", "widexhigh"], "a canvas that is not numbers must be refused")
        rejects(["--canvas"], "--canvas with no value must be refused")
        rejects(["--packet-log"], "--packet-log with no value must be refused")

        let key = PacketLogLine.packet(atNanoseconds: 1_500, sequence: 7, isKeyFrame: true, bytes: 1_718_000, parameterSetHex: "6742c0")
        check(
            key == #"{"bytes":1718000,"key":true,"kind":"packet","seq":7,"sps":"6742c0","t":1500}"#,
            "a key frame's line must carry its sequence-parameter set; got \(key)"
        )
        let delta = PacketLogLine.packet(atNanoseconds: 2_500, sequence: 8, isKeyFrame: false, bytes: 36_000, parameterSetHex: nil)
        check(
            delta == #"{"bytes":36000,"key":false,"kind":"packet","seq":8,"t":2500}"#,
            "a delta frame's line must carry no parameter set; got \(delta)"
        )
        let viewer = PacketLogLine.viewer(atNanoseconds: 3_000, presentedFramesPerSecond: 59.5, decodedFramesPerSecond: 60, receivedBitsPerSecond: nil)
        check(
            viewer == #"{"decodedFps":60,"kind":"viewer","presentedFps":59.5,"receivedBps":null,"t":3000}"#,
            "a viewer reading must keep an absent figure as null; got \(viewer)"
        )
        let config = PacketLogLine.configuration(atNanoseconds: 10, settled: "3008x1692", moving: "1920x1080")
        check(
            config == #"{"kind":"config","moving":"1920x1080","settled":"3008x1692","t":10}"#,
            "the opening line must name both sizes; got \(config)"
        )
        let single = PacketLogLine.configuration(atNanoseconds: 10, settled: "1920x1200", moving: nil)
        check(
            single == #"{"kind":"config","moving":null,"settled":"1920x1200","t":10}"#,
            "a stream with no motion size must say so; got \(single)"
        )

        if failures == 0 {
            print("PASS: the stand-in's command line and packet log lines")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
