import Darwin
import Foundation

/// 내 Mac의 네트워크 인터페이스에서 Tailscale 주소를 읽는다.
/// Tailscale 프로그램(GUI·CLI·시스템 확장)은 실행하지 않고, OS의 인터페이스 목록만 조회한다.
/// 주소가 없으면 Tailscale이 꺼져 있거나 설치되지 않은 것이므로 Tailscale 경로를 쓰지 않는다.
enum TailscaleAddress {
    struct InterfaceAddress: Equatable {
        let interface: String
        /// IFF_UP과 IFF_RUNNING이 모두 켜져 있는가
        let isActive: Bool
        let address: String
    }

    static func current() -> [String] {
        detect(interfaces: interfaceAddresses())
    }

    /// 순수 판정 함수. 켜져 있는 utun(가상 터널) 인터페이스의 Tailscale 대역 주소만 고른다.
    /// 100.64.0.0/10은 통신사 CGNAT 대역과 겹치므로 en0 같은 일반 인터페이스의 주소는 무시한다.
    /// IPv6를 끈 tailnet도 있어 fd7a 주소가 없는 utun의 100.64.0.0/10 주소도 채택한다.
    /// 결과는 IPv4 → IPv6 순으로 정렬해, 같은 상태에서는 항상 같은 목록이 나오게 한다.
    static func detect(interfaces: [InterfaceAddress]) -> [String] {
        var ipv4: Set<String> = []
        var ipv6: Set<String> = []
        for entry in interfaces where entry.isActive && entry.interface.hasPrefix("utun") {
            guard let address = ProtocolSecurity.tailscaleAddress(entry.address) else { continue }
            if address.contains(":") {
                ipv6.insert(address)
            } else {
                ipv4.insert(address)
            }
        }
        return Array((ipv4.sorted() + ipv6.sorted()).prefix(ProtocolSecurity.maxAddressCount))
    }

    /// 상대가 알려 준 주소 중 연결에 쓸 하나를 고른다(IPv4 우선).
    static func preferred(_ addresses: [String]) -> String? {
        let valid = addresses.compactMap(ProtocolSecurity.tailscaleAddress)
        return valid.first { !$0.contains(":") } ?? valid.first
    }

    private static func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                socketAddress, socklen_t(socketAddress.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            result.append(InterfaceAddress(
                interface: String(cString: entry.ifa_name),
                isActive: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0,
                address: String(cString: host)
            ))
        }
        return result
    }
}

/// 주소 알림의 응답 요청에 답할지 정한다. 응답에는 응답 요청을 넣지 않으므로 메시지가 무한히 오가지 않고,
/// 같은 Mac에는 30초에 한 번만 답해 요청이 몰려도 전송량이 늘지 않는다.
enum AddressReplyPolicy {
    static let minimumInterval: TimeInterval = 30

    static func shouldReply(wantsReply: Bool, lastReply: Date?, now: Date) -> Bool {
        guard wantsReply else { return false }
        guard let lastReply else { return true }
        // 시계가 뒤로 바뀐 경우에는 오래 막히지 않도록 바로 허용한다.
        return now < lastReply || now.timeIntervalSince(lastReply) >= minimumInterval
    }
}
