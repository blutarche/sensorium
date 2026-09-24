import Foundation
import SensoriumClient
import SensoriumCore

private func pairedMachine(host: String, key: UInt8) -> SavedHost {
    SavedHost(
        displayName: host,
        host: host,
        port: 7777,
        hostPublicKey: Data([key]),
        tlsCertificateHash: Data([key, key])
    )
}

func testViewerDialGuardTests() {
    do {
        let saved = [pairedMachine(host: "studio.tail1234.ts.net", key: 1)]
        let found = SavedHostLookup.resolve(host: "Studio.Tail1234.ts.net", in: saved)
        expect(
            (try? found.get())?.hostPublicKey == Data([1]),
            "a machine already paired is found whatever case its name was typed in"
        )
        let missing = SavedHostLookup.resolve(host: "laptop.tail1234.ts.net", in: saved)
        expect(
            missing == .failure(.notPaired(host: "laptop.tail1234.ts.net")),
            "a machine that was never paired is an error, never a dial with no pin -- got \(missing)"
        )
        expect(
            SavedHostLookup.resolve(host: "studio.tail1234.ts.net", in: []) == .failure(
                .notPaired(host: "studio.tail1234.ts.net")
            ),
            "an empty store pairs with nothing"
        )
        print("PASS: dialling a machine that was never paired is refused rather than run unpinned")
    }

    do {
        let flag = PinMismatchFlag()
        expect(
            !QUICPeerCertificateVerification.accepts(
                leafCertificateDER: nil,
                pin: Data([0xAB]),
                mismatchFlag: flag
            ),
            "a peer that presented no certificate cannot satisfy a pin"
        )
        expect(
            flag.observed,
            "and the dial reports the pin as the reason, not a bare transport failure"
        )
        print("PASS: a peer presenting no certificate against a pin is reported as a pin mismatch")
    }

    do {
        expect(
            QUICApplicationProtocol.isExpected("com.sensorium.control-v1"),
            "the protocol this viewer offered is the one it accepts"
        )
        expect(
            !QUICApplicationProtocol.isExpected("h3"),
            "a host that settled on some other protocol is not this protocol"
        )
        expect(
            !QUICApplicationProtocol.isExpected(nil),
            "a handshake that negotiated nothing at all is refused"
        )
        expect(
            !QUICApplicationProtocol.isExpected("com.sensorium.control-v1 "),
            "the comparison is exact, not a prefix or a trimmed match"
        )
        print("PASS: only the exact application protocol this viewer offered is accepted")
    }
}
