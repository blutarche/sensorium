// Signs and verifies the Sensorium update manifest with Ed25519.
//
//   swift Scripts/sign-update.swift generate <key file>
//   swift Scripts/sign-update.swift public-key <key file>
//   swift Scripts/sign-update.swift sign <key file> <manifest>
//   swift Scripts/sign-update.swift verify <public key base64> <manifest> <signature file>
//
// A key file holds the base64 of the 32 byte raw private key on one line and
// is readable by its owner alone. A signature file holds the base64 of the 64
// byte signature on one line. This tool never prints the private key.
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      sign-update.swift generate <key file>
      sign-update.swift public-key <key file>
      sign-update.swift sign <key file> <manifest>
      sign-update.swift verify <public key base64> <manifest> <signature file>

    """.utf8))
    exit(2)
}

func decodeBase64(_ text: String, bytes: Int, what: String) -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed), data.count == bytes else {
        fail("\(what) must be base64 of \(bytes) bytes")
    }
    return data
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    var info = stat()
    guard lstat(path, &info) == 0 else { fail("cannot read the key file \(path)") }
    guard (info.st_mode & S_IFMT) == S_IFREG else { fail("\(path) is not a regular file") }
    guard info.st_mode & 0o077 == 0 else {
        fail("\(path) grants access to group or others; run: chmod 600 \(path)")
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read the key file \(path)")
    }
    let raw = decodeBase64(text, bytes: 32, what: "the key file")
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("the key file does not hold a valid key")
    }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

switch (command, args.count) {
case ("generate", 2):
    let path = args[1]
    let key = Curve25519.Signing.PrivateKey()
    let line = key.rawRepresentation.base64EncodedString() + "\n"
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else {
        fail(errno == EEXIST ? "\(path) already exists; refusing to overwrite it" : "cannot create \(path)")
    }
    let bytes = Array(line.utf8)
    guard write(fd, bytes, bytes.count) == bytes.count else { close(fd); fail("cannot write \(path)") }
    close(fd)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case ("public-key", 2):
    print(loadKey(args[1]).publicKey.rawRepresentation.base64EncodedString())

case ("sign", 3):
    let key = loadKey(args[1])
    let manifest = read(args[2])
    guard let signature = try? key.signature(for: manifest) else { fail("signing failed") }
    let line = signature.base64EncodedString() + "\n"
    do { try line.write(toFile: args[2] + ".sig", atomically: true, encoding: .utf8) } catch {
        fail("cannot write \(args[2]).sig")
    }

case ("verify", 4):
    let raw = decodeBase64(args[1], bytes: 32, what: "the public key")
    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("not a valid public key")
    }
    guard let text = String(data: read(args[3]), encoding: .utf8) else { fail("the signature file is not text") }
    let signature = decodeBase64(text, bytes: 64, what: "the signature file")
    guard publicKey.isValidSignature(signature, for: read(args[2])) else { fail("the signature does not verify") }

default:
    usage()
}
