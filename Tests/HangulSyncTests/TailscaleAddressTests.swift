import XCTest
@testable import HangulSync

final class TailscaleAddressTests: XCTestCase {
    private func entry(_ interface: String, _ address: String, active: Bool = true)
        -> TailscaleAddress.InterfaceAddress {
        TailscaleAddress.InterfaceAddress(interface: interface, isActive: active, address: address)
    }

    func testIPv4RangeBoundaries() {
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("100.63.255.255"))
        XCTAssertEqual(ProtocolSecurity.tailscaleAddress("100.64.0.0"), "100.64.0.0")
        XCTAssertEqual(ProtocolSecurity.tailscaleAddress("100.101.102.103"), "100.101.102.103")
        XCTAssertEqual(ProtocolSecurity.tailscaleAddress("100.127.255.255"), "100.127.255.255")
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("100.128.0.0"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("192.168.1.10"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("10.0.0.1"))
    }

    func testIPv6RangeBoundariesAndCanonicalForm() {
        XCTAssertEqual(ProtocolSecurity.tailscaleAddress("fd7a:115c:a1e0::1"), "fd7a:115c:a1e0::1")
        XCTAssertEqual(
            ProtocolSecurity.tailscaleAddress("FD7A:115C:A1E0:0000:0000:0000:0000:0001"),
            "fd7a:115c:a1e0::1"
        )
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("fd7a:115c:a1e1::1"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("fe80::1"))
    }

    func testServiceAddressesAndMalformedTextAreRejected() {
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("100.100.100.100"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("fd7a:115c:a1e0::53"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress(""))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("100.64.0"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("fd7a:115c:a1e0::1%utun3"))
        XCTAssertNil(ProtocolSecurity.tailscaleAddress("tailscale.example"))
    }

    func testDetectsTailscaleUtunAddresses() {
        let detected = TailscaleAddress.detect(interfaces: [
            entry("lo0", "127.0.0.1"),
            entry("en0", "192.168.1.20"),
            entry("utun4", "fe80::1%utun4"),
            entry("utun4", "fd7a:115c:a1e0::abcd"),
            entry("utun4", "100.90.1.2"),
        ])
        XCTAssertEqual(detected, ["100.90.1.2", "fd7a:115c:a1e0::abcd"])
    }

    func testIgnoresCarrierGradeNATOnPhysicalInterfaces() {
        XCTAssertEqual(TailscaleAddress.detect(interfaces: [entry("en0", "100.72.0.5")]), [])
    }

    func testIgnoresOtherVPNTunnels() {
        XCTAssertEqual(TailscaleAddress.detect(interfaces: [
            entry("utun1", "10.8.0.2"),
            entry("utun2", "192.168.1.26"),
        ]), [])
    }

    func testIgnoresInactiveInterfaces() {
        XCTAssertEqual(TailscaleAddress.detect(interfaces: [
            entry("utun4", "100.90.1.2", active: false),
            entry("utun4", "fd7a:115c:a1e0::abcd", active: false),
        ]), [])
    }

    func testAcceptsIPv4OnlyTailnet() {
        XCTAssertEqual(TailscaleAddress.detect(interfaces: [entry("utun5", "100.90.1.2")]), ["100.90.1.2"])
    }

    func testDetectionIsStableAndLimited() {
        let first = TailscaleAddress.detect(interfaces: [
            entry("utun4", "fd7a:115c:a1e0::2"),
            entry("utun4", "100.90.1.3"),
            entry("utun5", "100.90.1.1"),
            entry("utun4", "100.90.1.3"),
            entry("utun6", "100.90.1.2"),
            entry("utun6", "fd7a:115c:a1e0::1"),
        ])
        XCTAssertEqual(first, ["100.90.1.1", "100.90.1.2", "100.90.1.3", "fd7a:115c:a1e0::1"])
    }

    func testPreferredAddressChoosesIPv4() {
        XCTAssertEqual(TailscaleAddress.preferred(["fd7a:115c:a1e0::1", "100.90.1.2"]), "100.90.1.2")
        XCTAssertEqual(TailscaleAddress.preferred(["fd7a:115c:a1e0::1"]), "fd7a:115c:a1e0::1")
        XCTAssertNil(TailscaleAddress.preferred([]))
        XCTAssertNil(TailscaleAddress.preferred(["192.168.1.2"]))
    }

    func testReplyPolicy() {
        let now = Date()
        XCTAssertFalse(AddressReplyPolicy.shouldReply(wantsReply: false, lastReply: nil, now: now))
        XCTAssertTrue(AddressReplyPolicy.shouldReply(wantsReply: true, lastReply: nil, now: now))
        XCTAssertFalse(AddressReplyPolicy.shouldReply(
            wantsReply: true, lastReply: now.addingTimeInterval(-10), now: now
        ))
        XCTAssertTrue(AddressReplyPolicy.shouldReply(
            wantsReply: true, lastReply: now.addingTimeInterval(-30), now: now
        ))
        XCTAssertTrue(AddressReplyPolicy.shouldReply(
            wantsReply: true, lastReply: now.addingTimeInterval(3600), now: now
        ))
    }
}
