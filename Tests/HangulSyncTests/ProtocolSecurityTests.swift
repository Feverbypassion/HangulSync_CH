import XCTest
@testable import HangulSync

final class ProtocolSecurityTests: XCTestCase {
    func testValidMessages() {
        XCTAssertTrue(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer",
                kind: .hello,
                name: "Mac",
                publicKey: Data(repeating: 1, count: 32).base64EncodedString()
            )
        ))
        XCTAssertTrue(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .input, sourceID: "com.apple.keylayout.US", isKorean: false)
        ))
    }

    func testUnknownAndMalformedKindsAreRejected() {
        let unknown = Data(#"{"origin":"peer","kind":"surprise","sourceID":"x"}"#.utf8)
        XCTAssertNil(ProtocolSecurity.decode(unknown))
        XCTAssertNil(ProtocolSecurity.decode(Data("{".utf8)))
    }

    func testRelayKeyMustBeExactly32HexCharacters() {
        XCTAssertTrue(ProtocolSecurity.isValidRelayKey(String(repeating: "a", count: 32)))
        XCTAssertFalse(ProtocolSecurity.isValidRelayKey(""))
        XCTAssertFalse(ProtocolSecurity.isValidRelayKey(String(repeating: "a", count: 31)))
        XCTAssertFalse(ProtocolSecurity.isValidRelayKey(String(repeating: "a", count: 33)))
        XCTAssertFalse(ProtocolSecurity.isValidRelayKey(String(repeating: "z", count: 32)))
    }

    func testFieldAndMessageLimits() throws {
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: String(repeating: "a", count: 65),
                kind: .hello,
                name: "Mac",
                publicKey: Data(repeating: 1, count: 32).base64EncodedString()
            )
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer",
                kind: .hello,
                name: String(repeating: "a", count: 101),
                publicKey: Data(repeating: 1, count: 32).base64EncodedString()
            )
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .input, sourceID: String(repeating: "a", count: 257))
        ))
        XCTAssertNil(ProtocolSecurity.decode(Data(repeating: 0x20, count: ProtocolSecurity.maxMessageBytes + 1)))
    }

    func testMessageShapeMustMatchKind() {
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .input, sourceID: nil)
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .session, sourceID: "spoof", sessionActive: true)
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .pair, relayKey: "")
        ))
    }

    func testPausedAndUntrustedStateChangingMessagesAreRejected() {
        for kind in [SyncMessageKind.input, .session, .pair] {
            XCTAssertFalse(ProtocolSecurity.permits(
                kind, enabled: false, trusted: true, pairingMode: true
            ))
            XCTAssertFalse(ProtocolSecurity.permits(
                kind, enabled: true, trusted: false, pairingMode: true
            ))
        }
        XCTAssertFalse(ProtocolSecurity.permits(
            .pair, enabled: true, trusted: true, pairingMode: false
        ))
        XCTAssertTrue(ProtocolSecurity.permits(
            .input, enabled: true, trusted: true, pairingMode: false
        ))
    }

    func testAddressMessages() throws {
        XCTAssertTrue(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .address, addresses: [], wantsReply: true)
        ))
        let full = SyncMessage(
            origin: "peer",
            kind: .address,
            addresses: ["100.90.1.2", "fd7a:115c:a1e0::1"],
            wantsReply: false
        )
        XCTAssertTrue(ProtocolSecurity.validate(full))
        let decoded = try XCTUnwrap(ProtocolSecurity.decode(JSONEncoder().encode(full)))
        XCTAssertEqual(decoded.addresses, ["100.90.1.2", "fd7a:115c:a1e0::1"])
        XCTAssertEqual(decoded.wantsReply, false)
    }

    func testAddressMessagesRejectOutOfRangeOrTooManyAddresses() {
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .address, addresses: ["192.168.1.10"], wantsReply: false)
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .address, addresses: ["100.100.100.100"], wantsReply: false)
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer",
                kind: .address,
                addresses: (1...5).map { "100.90.1.\($0)" },
                wantsReply: false
            )
        ))
    }

    func testAddressMessageShape() {
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .address, wantsReply: true)
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(origin: "peer", kind: .address, addresses: [])
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer", kind: .address, sourceID: "com.apple.keylayout.US",
                addresses: [], wantsReply: false
            )
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer", kind: .address, name: "Mac",
                addresses: [], wantsReply: false
            )
        ))
        // 다른 종류의 메시지에는 주소 필드를 실을 수 없다.
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer", kind: .input, sourceID: "com.apple.keylayout.US",
                addresses: ["100.90.1.2"]
            )
        ))
        XCTAssertFalse(ProtocolSecurity.validate(
            SyncMessage(
                origin: "peer", kind: .hello, name: "Mac",
                publicKey: Data(repeating: 1, count: 32).base64EncodedString(),
                wantsReply: true
            )
        ))
    }

    func testMessagesWithoutAddressFieldsKeepTheirWireFormat() throws {
        let data = try JSONEncoder().encode(
            SyncMessage(origin: "peer", kind: .session, sessionActive: true)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("addresses"))
        XCTAssertFalse(text.contains("wantsReply"))
    }

    func testPausedAndUntrustedAddressMessagesAreRejected() {
        XCTAssertFalse(ProtocolSecurity.permits(.address, enabled: false, trusted: true, pairingMode: false))
        XCTAssertFalse(ProtocolSecurity.permits(.address, enabled: true, trusted: false, pairingMode: true))
        XCTAssertTrue(ProtocolSecurity.permits(.address, enabled: true, trusted: true, pairingMode: false))
    }

    func testSemanticVersionComparisonAndMalformedVersions() {
        XCTAssertTrue(UpdateChecker.version("1.2.10", isNewerThan: "1.2.9"))
        XCTAssertTrue(UpdateChecker.version("v2.0.0", isNewerThan: "1.99.99"))
        XCTAssertFalse(UpdateChecker.version("autocd.autocd.1", isNewerThan: "1.0.1"))
        XCTAssertFalse(UpdateChecker.version("1.2", isNewerThan: "1.0.1"))
        XCTAssertNil(SemanticVersion("v1.2.3-beta"))
    }
}
