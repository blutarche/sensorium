import Foundation
import SensoriumCore

/// Two modes that let the Linux server and the macOS viewer's real
/// Network.framework client be checked against each other across a container
/// boundary:
///
///     SensoriumLinuxHostTestRunner serve <identity-file> <bind-address> <port>
///     SensoriumLinuxHostTestRunner dial <host> <port> <pin-hex>
///     SensoriumLinuxHostTestRunner identity <identity-file>
///
/// `serve` runs on Linux and echoes every packet it reads. `dial` runs on
/// macOS and sends a small packet and a payload over 1 MiB, then checks the
/// echoes. `identity` loads a stored identity file the way the macOS host
/// would and prints its pin, which proves Security accepts a certificate and
/// key that OpenSSL wrote.
enum InteropModes {
    static func run(_ arguments: [String]) async -> Int32? {
        guard let mode = arguments.first else { return nil }
        switch mode {
        case "serve" where arguments.count == 4:
            #if os(Linux)
            return await serve(identityPath: arguments[1], bindAddress: arguments[2], port: UInt16(arguments[3]) ?? 0)
            #else
            print("serve runs on Linux only")
            return 2
            #endif
        case "dial" where arguments.count == 4:
            #if canImport(Network)
            return await dial(host: arguments[1], port: UInt16(arguments[2]) ?? 0, pinHex: arguments[3])
            #else
            print("dial runs on macOS only")
            return 2
            #endif
        case "identity" where arguments.count == 2:
            return identity(path: arguments[1])
        default:
            return nil
        }
    }

    private static func identity(path: String) -> Int32 {
        let store = FileHostTLSIdentityStore(url: URL(fileURLWithPath: path), commonName: "Sensorium Host")
        do {
            let identity = try store.loadOrCreate()
            print("IDENTITY loaded, pin \(hex(identity.certificateHash))")
            return 0
        } catch {
            print("IDENTITY failed: \(error)")
            return 1
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

#if os(Linux)
import SensoriumLinuxHost

extension InteropModes {
    private static func serve(identityPath: String, bindAddress: String, port: UInt16) async -> Int32 {
        do {
            let store = FileHostTLSIdentityStore(
                url: URL(fileURLWithPath: identityPath),
                commonName: "Sensorium Host"
            )
            let identity = try store.loadOrCreate()
            let server = OpenSSLQUICServer(identity: identity, bindAddress: bindAddress, port: port)
            try server.start()
            print("PIN \(hex(identity.certificateHash))")
            print("LISTENING \(server.boundPort)")
            for await channel in server.channels {
                print("ACCEPTED")
                Task { await echo(channel) }
            }
            return 0
        } catch {
            print("serve failed: \(error)")
            return 1
        }
    }

    private static func echo(_ channel: OpenSSLQUICServerChannel) async {
        do {
            while true {
                let header = try await channel.receiveBytes(count: 5)
                let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                let payload = try await channel.receiveBytes(count: length)
                print("ECHO \(5 + length) bytes")
                try await channel.sendBytes(header + payload)
            }
        } catch {
            print("CHANNEL ENDED \(error)")
        }
    }
}
#endif

#if canImport(Network)
import Network
import SensoriumClient

extension InteropModes {
    private static func dial(host: String, port: UInt16, pinHex: String) async -> Int32 {
        guard let pin = data(hex: pinHex), let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("DIAL bad arguments")
            return 2
        }
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            tlsCertificateHash: pin
        )
        do {
            try await connection.start(timeout: 15)
            print("DIAL connected over QUIC, pin matched")
            var failures = 0
            for (tag, size) in [(UInt8(0x40), 24), (UInt8(0x41), 1_500_000)] {
                var payload = Data(count: size)
                for index in payload.indices {
                    payload[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(tag))
                }
                let packet = SensoriumTransportPacket.unrecognized(tag: tag, payload: payload)
                // A large write completes only as the far end reads.
                async let echoed = connection.receiveWirePacket()
                try await connection.send(packet)
                let received = try await echoed
                let matches = received == packet
                print("DIAL sent \(size) byte payload, echo \(matches ? "matches" : "DIFFERS")")
                if !matches { failures += 1 }
            }
            await connection.close()
            print(failures == 0 ? "DIAL OK" : "DIAL FAILED")
            return failures == 0 ? 0 : 1
        } catch {
            print("DIAL failed: \(error)")
            return 1
        }
    }
}
#endif
