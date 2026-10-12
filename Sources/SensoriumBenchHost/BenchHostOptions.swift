import Foundation

/// The command line of `SensoriumBenchHost`, parsed and checked before
/// anything is created or bound.
struct BenchHostOptions: Equatable {
    static let usage = """
    usage: SensoriumBenchHost <tailnet-address> <port> --state-dir <dir> --trace <path> [--max-seconds N]

      <tailnet-address>  this machine's tailnet address; any other address is refused
      <port>             the UDP port to listen on, 1-65535 except 7777 (the host app's port)
      --state-dir <dir>  where the stand-in keeps its keys and paired devices; created if missing
      --trace <path>     file the host stage traces are appended to; its folder must exist
      --max-seconds N    exit after N seconds if no session has ended by then (default 180)
    """

    static let defaultMaxSeconds = 180
    /// The port the host app listens on by default. A stand-in beside a real
    /// host must never take it.
    static let hostAppPort: UInt16 = 7777

    let address: String
    let port: UInt16
    let stateDirectory: URL
    let tracePath: String
    let maxSeconds: Int

    enum ParseError: Error, Equatable {
        case message(String)
    }

    static func parse(_ arguments: [String]) -> Result<BenchHostOptions, ParseError> {
        var positional: [String] = []
        var stateDirectory: String?
        var tracePath: String?
        var maxSeconds = defaultMaxSeconds
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--state-dir", "--trace", "--max-seconds":
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
            maxSeconds: maxSeconds
        ))
    }
}
