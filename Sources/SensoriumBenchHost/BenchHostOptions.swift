import Foundation

/// The command line of `SensoriumBenchHost`, parsed and checked before
/// anything is created or bound.
struct BenchHostOptions: Equatable {
    static let usage = """
    usage: SensoriumBenchHost <tailnet-address> <port> --state-dir <dir> --trace <path> [--max-seconds N] [--canvas <width>x<height>] [--packet-log <path>]

      <tailnet-address>  this machine's tailnet address; any other address is refused
      <port>             the UDP port to listen on, 1-65535 except 7777 (the host app's port)
      --state-dir <dir>  where the stand-in keeps its keys and paired devices; created if missing
      --trace <path>     file the host stage traces are appended to; its folder must exist
      --max-seconds N    exit after N seconds if no session has ended by then (default 180)
      --canvas WxH       draw and encode the picture at W by H pixels, whatever size the viewer asked
                         for, and ignore its later size requests; each side even, at most 4096
                         (default 1920x1200, resized to the viewer's window)
      --packet-log PATH  file that gets one JSON line per encoded packet, per viewer reading and
                         per encoder configuration; its folder must exist
    """

    static let defaultMaxSeconds = 180
    /// The port the host app listens on by default. A stand-in beside a real
    /// host must never take it.
    static let hostAppPort: UInt16 = 7777

    /// The picture size of a fixed-size stand-in, in pixels.
    struct CanvasSize: Equatable {
        let width: Int
        let height: Int
    }

    /// The largest side the hardware H.264 encoder takes; the same limit as
    /// `VideoEncoderConfiguration.hardwareH264MaxDimension`, which this file
    /// cannot import because the checks compile it on its own.
    static let maximumCanvasSide = 4096

    let address: String
    let port: UInt16
    let stateDirectory: URL
    let tracePath: String
    let maxSeconds: Int
    let canvasSize: CanvasSize?
    let packetLogPath: String?

    enum ParseError: Error, Equatable {
        case message(String)
    }

    static func parse(_ arguments: [String]) -> Result<BenchHostOptions, ParseError> {
        var positional: [String] = []
        var stateDirectory: String?
        var tracePath: String?
        var maxSeconds = defaultMaxSeconds
        var canvasSize: CanvasSize?
        var packetLogPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state-dir", "--trace", "--max-seconds", "--canvas", "--packet-log":
                guard index + 1 < arguments.count else {
                    return .failure(.message("\(argument) needs a value"))
                }
                let value = arguments[index + 1]
                index += 2
                switch argument {
                case "--state-dir":
                    stateDirectory = value
                case "--trace":
                    tracePath = value
                case "--packet-log":
                    packetLogPath = value
                case "--canvas":
                    guard let size = parseCanvasSize(value) else {
                        return .failure(.message("--canvas needs <width>x<height>, each an even number from 2 to \(maximumCanvasSide)"))
                    }
                    canvasSize = size
                default:
                    guard let seconds = Int(value), seconds > 0 else {
                        return .failure(.message("--max-seconds needs a whole number above zero"))
                    }
                    maxSeconds = seconds
                }
            default:
                guard !argument.hasPrefix("--") else {
                    return .failure(.message("unknown option \(argument)"))
                }
                positional.append(argument)
                index += 1
            }
        }
        guard positional.count == 2 else {
            return .failure(.message("expected <tailnet-address> and <port>"))
        }
        guard let port = UInt16(positional[1]), port != 0 else {
            return .failure(.message("<port> must be a number from 1 to 65535"))
        }
        guard port != hostAppPort else {
            return .failure(.message("port \(hostAppPort) belongs to the host app; choose another"))
        }
        guard let stateDirectory else {
            return .failure(.message("--state-dir is required"))
        }
        guard let tracePath else {
            return .failure(.message("--trace is required"))
        }
        return .success(BenchHostOptions(
            address: positional[0],
            port: port,
            stateDirectory: URL(fileURLWithPath: stateDirectory, isDirectory: true),
            tracePath: tracePath,
            maxSeconds: maxSeconds,
            canvasSize: canvasSize,
            packetLogPath: packetLogPath
        ))
    }

    /// 4:2:0 video keeps colour at half resolution on both axes, so an odd
    /// side cannot be encoded.
    private static func parseCanvasSize(_ value: String) -> CanvasSize? {
        let sides = value.split(separator: "x", omittingEmptySubsequences: false)
        guard sides.count == 2,
              let width = Int(sides[0]), let height = Int(sides[1]),
              [width, height].allSatisfy({ $0 >= 2 && $0 <= maximumCanvasSide && $0 % 2 == 0 }) else {
            return nil
        }
        return CanvasSize(width: width, height: height)
    }
}
