import Foundation

enum SyncMessageKind: String, Codable {
    case input
    case session
    case pair
    case hello
    /// 페어링된 Mac에 내 Tailscale 주소를 알린다. 빈 목록은 "지금은 Tailscale 경로 없음"이다.
    /// 이 값을 모르는 구버전은 메시지 전체를 해석하지 못해 버리므로 영향이 없다.
    case address
}

/// Newline-delimited JSON message used on direct connections.
struct SyncMessage: Codable {
    var origin: String
    var kind: SyncMessageKind
    var sourceID: String? = nil
    var isKorean: Bool? = nil
    var sessionActive: Bool? = nil
    var relayKey: String? = nil
    var name: String? = nil
    var publicKey: String? = nil
    var pairingRequest: Bool? = nil
    var addresses: [String]? = nil
    var wantsReply: Bool? = nil
}

enum ProtocolSecurity {
    static let maxMessageBytes = 4 * 1024
    static let maxBufferBytes = 8 * 1024
    static let maxOriginLength = 64
    static let maxNameLength = 100
    static let maxSourceIDLength = 256
    static let relayKeyLength = 32
    static let maxAddressCount = 4

    /// Tailscale이 기기에 배정하는 대역(IPv4 100.64.0.0/10, IPv6 fd7a:115c:a1e0::/48)의
    /// 주소면 정규화한 문자열을, 아니면 nil을 돌려준다. Tailscale 자체 서비스 주소(quad100)는 뺀다.
    /// 상대가 알려 준 주소를 이 대역으로 제한해, 임의의 내부망 호스트로 연결하게 만들 수 없게 한다.
    static func tailscaleAddress(_ text: String) -> String? {
        // Darwin의 inet_pton은 "%utun3" 같은 범위 표기도 받아들이므로 숫자 표기 문자만 허용한다.
        guard !text.isEmpty, text.utf8.count <= Int(INET6_ADDRSTRLEN),
              text.utf8.allSatisfy({ $0 == 0x2E || $0 == 0x3A || ($0 < 0x80 && Character(UnicodeScalar($0)).isHexDigit) })
        else { return nil }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            guard bytes[0] == 100, bytes[1] & 0xC0 == 0x40,
                  bytes != [100, 100, 100, 100] else { return nil }
            return numericString(family: AF_INET, address: &ipv4)
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, text, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let quad100: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + Array(repeating: 0, count: 9) + [0x53]
            guard Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0],
                  bytes != quad100 else { return nil }
            return numericString(family: AF_INET6, address: &ipv6)
        }
        return nil
    }

    private static func numericString<Address>(family: Int32, address: inout Address) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let converted = withUnsafePointer(to: &address) {
            inet_ntop(family, $0, &buffer, socklen_t(buffer.count))
        }
        return converted == nil ? nil : String(cString: buffer)
    }

    static func isValidRelayKey(_ key: String) -> Bool {
        guard key.utf8.count == relayKeyLength else { return false }
        return key.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    static func validate(_ message: SyncMessage) -> Bool {
        guard !message.origin.isEmpty,
              message.origin.utf8.count <= maxOriginLength else { return false }

        if let name = message.name, name.utf8.count > maxNameLength { return false }
        if let sourceID = message.sourceID,
           sourceID.isEmpty || sourceID.utf8.count > maxSourceIDLength { return false }
        if let relayKey = message.relayKey, !isValidRelayKey(relayKey) { return false }
        if let publicKey = message.publicKey,
           publicKey.utf8.count > 64 || Data(base64Encoded: publicKey)?.count != 32 {
            return false
        }
        // 주소 알림 필드는 .address 메시지에서만 허용한다.
        if message.kind != .address, message.addresses != nil || message.wantsReply != nil {
            return false
        }

        switch message.kind {
        case .hello:
            return message.name != nil && message.publicKey != nil
                && message.sourceID == nil && message.isKorean == nil
                && message.sessionActive == nil && message.relayKey == nil
        case .input:
            return message.sourceID != nil
                && message.sessionActive == nil && message.relayKey == nil
                && message.name == nil && message.publicKey == nil
                && message.pairingRequest == nil
        case .session:
            return message.sessionActive != nil
                && message.sourceID == nil && message.isKorean == nil
                && message.relayKey == nil && message.name == nil
                && message.publicKey == nil && message.pairingRequest == nil
        case .pair:
            return message.relayKey != nil
                && message.sourceID == nil && message.isKorean == nil
                && message.sessionActive == nil && message.name == nil
                && message.publicKey == nil && message.pairingRequest == nil
        case .address:
            guard let addresses = message.addresses, message.wantsReply != nil,
                  addresses.count <= maxAddressCount,
                  addresses.allSatisfy({ tailscaleAddress($0) != nil })
            else { return false }
            return message.sourceID == nil && message.isKorean == nil
                && message.sessionActive == nil && message.relayKey == nil
                && message.name == nil && message.publicKey == nil
                && message.pairingRequest == nil
        }
    }

    static func decode(_ data: Data) -> SyncMessage? {
        guard !data.isEmpty, data.count <= maxMessageBytes,
              let message = try? JSONDecoder().decode(SyncMessage.self, from: data),
              validate(message) else { return nil }
        return message
    }

    static func permits(
        _ kind: SyncMessageKind,
        enabled: Bool,
        trusted: Bool,
        pairingMode: Bool
    ) -> Bool {
        if kind == .hello { return true }
        guard enabled, trusted else { return false }
        if kind == .pair { return pairingMode }
        return true
    }
}

enum SemanticVersion: Comparable, Equatable {
    case version(Int, Int, Int)

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        self = .version(major, minor, patch)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        switch (lhs, rhs) {
        case let (.version(lMajor, lMinor, lPatch), .version(rMajor, rMinor, rPatch)):
            return (lMajor, lMinor, lPatch) < (rMajor, rMinor, rPatch)
        }
    }
}
