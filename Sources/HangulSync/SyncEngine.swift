import Foundation
import AppKit
import Carbon
import Network

struct PeerInventory {
    static func includingRelayFallbacks(
        direct: [String: String],
        trustedOrigins: Set<String>
    ) -> [String: String] {
        var result = direct
        for origin in trustedOrigins where result[origin] == nil {
            result[origin] = "relay-\(origin)"
        }
        return result
    }
}

/// 입력 소스 변경 감지 → 피어 전파, 피어 메시지 수신 → 로컬 적용.
/// 피어 경로: ① Bonjour(같은 네트워크/AWDL) ② Tailscale ③ 수신 연결 ④ 암호화 릴레이
/// Tailscale은 사용자가 이미 켜 둔 경우에만 쓰는 경로다. HangulSync는 Tailscale의 GUI·CLI·
/// 시스템 확장 중 어느 것도 실행하지 않고, 내 Mac의 인터페이스 주소만 읽어 페어링된 Mac과 교환한다.
/// 기본적으로 원격 데스크탑 뷰어가 사용 중일 때만 동기화가 활성화된다.
final class SyncEngine {

    static let serviceType = "_hangulsync._tcp"
    static let port: UInt16 = 47820

    /// 전면(frontmost)일 때 "원격 세션 중"으로 인식할 원격 데스크탑 앱들의 번들 ID 접두사
    static let viewerBundlePrefixes = [
        "com.p5sys.jump",            // Jump Desktop
        "com.apple.ScreenSharing",   // macOS 화면 공유
        "com.edovia.screens",        // Screens 4/5
        "com.microsoft.rdc",         // Windows App (MS Remote Desktop)
        "com.realvnc.vncviewer",     // VNC Viewer
        "com.teamviewer.TeamViewer", // TeamViewer
        "com.philandro.anydesk",     // AnyDesk
        "com.carriez.rustdesk",      // RustDesk
        "tv.parsec.www",             // Parsec
        "com.splashtop",             // Splashtop
    ]

    private static let sessionTTL: TimeInterval = 600      // 원격 세션 신호 유효시간
    private static let sessionRefresh: TimeInterval = 240  // 세션 유지 재전송 주기
    private static let onlyRemoteDefaults = "OnlyDuringRemote"
    private static let deviceIDDefaults = "DeviceID"
    private static let trustedOriginsDefaults = "TrustedDeviceIDs"
    private static let peerPublicKeysDefaults = "TrustedPeerPublicKeys"
    private static let tailscaleIPsDefaults = "TrustedPeerTailscaleIPs"
    private static let useTailscaleDefaults = "UseTailscalePath"
    private static let pairingDuration: TimeInterval = 120
    /// 시작 직후 릴레이 구독이 자리 잡을 시간을 준 뒤 주소를 알린다(응답을 놓치지 않도록).
    private static let addressAnnouncementDelay: TimeInterval = 3

    let instanceID: String
    let serviceName: String
    private let identity: SecureIdentity?
    private let relay: RelayChannel
    private let rendezvous = PairingRendezvous()

    private let netQueue = DispatchQueue(label: "hangulsync.network")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]      // netQueue에서만 접근
    private var originByKey: [String: String] = [:]             // netQueue에서만 접근
    private var messageTimesByKey: [String: [Date]] = [:]       // netQueue에서만 접근
    private var trustedConnectionKeys: Set<String> = []         // netQueue에서만 접근
    private var trustedOrigins: Set<String> = []                 // netQueue에서만 접근
    private var peerPublicKeys: [String: String] = [:]           // netQueue에서만 접근
    private var tailscaleIPsByOrigin: [String: String] = [:]     // netQueue에서만 접근 (상대가 알려 준 주소)
    private var localTailscaleAddresses: [String] = []           // netQueue에서만 접근 (토글이 꺼져 있으면 빈 목록)
    private var tailscalePathAllowed = true                      // netQueue에서만 접근 (useTailscalePath 사본)
    private var addressRepliesByOrigin: [String: Date] = [:]     // netQueue에서만 접근
    private let pathMonitor = NWPathMonitor()
    private var pendingApprovalOrigins: Set<String> = []         // netQueue에서만 접근
    private var localRemoteApprovals: [String: (key: String, persist: Bool, name: String)] = [:]
    private var remoteApprovedOrigins: Set<String> = []
    private var pairingHelloRepliedOrigins: Set<String> = []    // netQueue에서만 접근
    private var lastBonjourResults: Set<NWBrowser.Result> = []  // netQueue에서만 접근
    private var retryTimer: Timer?
    private var pairingUntil = Date.distantPast

    // ↓ 메인 스레드에서만 접근
    private var suppressUntil = Date.distantPast
    private var lastKnownID: String?
    private var remoteActive: [String: Date] = [:]  // origin → 마지막 세션 신호 시각
    private var lastSessionBroadcast = Date.distantPast
    private var namesByOrigin: [String: String] = [:]
    private(set) var localViewerActive = false
    private(set) var readyPeerCount = 0
    /// 설정 창에 보여줄 피어 목록: (컴퓨터 이름, 연결 경로)
    private(set) var peerInfo: [(id: String, name: String, via: String)] = []

    let hostName = Host.current().localizedName ?? "Mac"

    var enabled = true {
        didSet {
            onStateChange?()
            // 일시정지 중에는 상대의 주소 알림을 거부했으므로, 재개하면 다시 주고받는다.
            if enabled, !oldValue {
                netQueue.async { self.announceAddresses(wantsReply: true) }
            }
        }
    }

    /// true(기본): 원격 데스크탑 뷰어 사용 중일 때만 동기화
    var onlyDuringRemote: Bool {
        didSet {
            UserDefaults.standard.set(onlyDuringRemote, forKey: Self.onlyRemoteDefaults)
            onStateChange?()
        }
    }

    /// true(기본): 두 Mac에서 Tailscale이 이미 켜져 있으면 Tailscale 주소로 직접 연결한다.
    /// false이면 내 Tailscale 주소를 빈 목록으로 알리고 Tailscale 경로를 쓰지 않는다.
    /// 어느 쪽이든 HangulSync가 Tailscale을 실행하지는 않는다.
    var useTailscalePath: Bool {
        didSet {
            UserDefaults.standard.set(useTailscalePath, forKey: Self.useTailscaleDefaults)
            let allowed = useTailscalePath
            netQueue.async {
                self.tailscalePathAllowed = allowed
                self.refreshLocalTailscaleAddresses()
            }
            onStateChange?()
        }
    }

    /// 지금 동기화가 실제로 동작하는 상태인가
    var syncAllowed: Bool {
        guard enabled else { return false }
        guard onlyDuringRemote else { return true }
        if localViewerActive { return true }
        let now = Date()
        return remoteActive.values.contains { now.timeIntervalSince($0) < Self.sessionTTL }
    }

    /// UI 갱신 콜백 (메인 스레드에서 호출됨)
    var onStateChange: (() -> Void)?
    var onPairingComplete: (() -> Void)?
    var onPairingError: ((Int) -> Void)?

    init() {
        let defaults = UserDefaults.standard
        let secureIdentity = SecureIdentity.loadOrCreate()
        let deviceID: String
        if let secureIdentity {
            deviceID = secureIdentity.deviceID
        } else if let saved = defaults.string(forKey: Self.deviceIDDefaults),
           UUID(uuidString: saved) != nil {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDDefaults)
        }
        self.identity = secureIdentity
        self.instanceID = deviceID
        self.relay = RelayChannel(localID: deviceID)
        let host = Host.current().localizedName ?? "Mac"
        self.serviceName = "\(host)-\(deviceID.prefix(8))"
        self.peerPublicKeys = defaults.dictionary(forKey: Self.peerPublicKeysDefaults)?
            .compactMapValues { $0 as? String } ?? [:]
        // 계속 신뢰하는 Mac의 주소만, Tailscale 대역인 것만 이어서 쓴다.
        let savedPublicKeys = self.peerPublicKeys
        self.tailscaleIPsByOrigin = (defaults.dictionary(forKey: Self.tailscaleIPsDefaults) ?? [:])
            .compactMapValues { ($0 as? String).flatMap(ProtocolSecurity.tailscaleAddress) }
            .filter { savedPublicKeys[$0.key] != nil }
        self.trustedOrigins = Set(self.peerPublicKeys.keys)
        if defaults.object(forKey: Self.onlyRemoteDefaults) == nil {
            self.onlyDuringRemote = true
        } else {
            self.onlyDuringRemote = defaults.bool(forKey: Self.onlyRemoteDefaults)
        }
        let useTailscale = defaults.object(forKey: Self.useTailscaleDefaults) == nil
            || defaults.bool(forKey: Self.useTailscaleDefaults)
        self.useTailscalePath = useTailscale
        self.tailscalePathAllowed = useTailscale
    }

    func start() {
        lastKnownID = InputSourceManager.current()?.id
        relay.onMessage = { [weak self] message, peerID in
            self?.netQueue.async {
                self?.handle(message, fromKey: "relay-\(peerID)")
            }
        }
        rendezvous.onPeer = { [weak self] publicKey, name, remoteApproved in
            self?.netQueue.async {
                guard let self,
                      let origin = SecureIdentity.deviceID(for: publicKey),
                      origin != self.instanceID else { return }
                let message = SyncMessage(
                    origin: origin, kind: .hello, name: name,
                    publicKey: publicKey, pairingRequest: true
                )
                if remoteApproved { self.remoteApprovedOrigins.insert(origin) }
                if self.trustedOrigins.contains(origin) {
                    self.rendezvous.publishApproval(
                        publicKey: self.identity?.publicKeyBase64 ?? "",
                        name: self.hostName
                    )
                } else {
                    self.requestApproval(for: message, allowWithoutConnection: true)
                }
                self.finishRemoteApprovalIfReady(origin: origin)
            }
        }
        rendezvous.onError = { [weak self] status in
            DispatchQueue.main.async {
                self?.onPairingError?(status)
            }
        }
        if let identity {
            for (peerID, publicKey) in peerPublicKeys {
                if let secret = identity.sharedSecret(with: publicKey) {
                    relay.configure(peerID: peerID, sharedSecret: secret)
                }
            }
        }
        recountPeers()
        observeLocalChanges()
        observeViewerApps()
        startListener()
        startBonjourBrowser()
        // 경로 감시보다 먼저 큐에 넣어, 첫 경로 이벤트 전에 현재 주소가 반영되게 한다.
        netQueue.async {
            self.refreshLocalTailscaleAddresses(announceChange: false)
            self.connectKnownTailscalePeers()
        }
        startPathMonitor()
        netQueue.asyncAfter(deadline: .now() + Self.addressAnnouncementDelay) {
            self.announceAddresses(wantsReply: true)
        }
        startTimer()
    }

    // MARK: - 로컬 입력 소스 변경 감지

    private func observeLocalChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleLocalChange()
        }
    }

    private func handleLocalChange() {
        onStateChange?()
        guard syncAllowed else { return }
        guard Date() >= suppressUntil else { return } // 원격 적용에 의한 에코 → 무시
        guard let cur = InputSourceManager.current(), cur.id != lastKnownID else { return }
        lastKnownID = cur.id
        send(input: cur)
    }

    // MARK: - 원격 데스크탑 뷰어 감지 (세션 게이트)
    // "뷰어 앱이 실행 중이면 원격 세션 중"으로 판정한다.
    // (frontmost 기준은 다른 앱만 잠깐 클릭해도 대기로 빠져 UX가 나쁘다)

    private func observeViewerApps() {
        let nc = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification,
                      NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.updateViewerState()
            }
        }
        updateViewerState()
    }

    private func updateViewerState() {
        let running = NSWorkspace.shared.runningApplications.contains { Self.isViewer($0) }
        setLocalViewer(active: running)
    }

    private static func isViewer(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return viewerBundlePrefixes.contains { id.hasPrefix($0) }
    }

    private func setLocalViewer(active: Bool) {
        guard active != localViewerActive else { return }
        localViewerActive = active
        lastSessionBroadcast = Date()
        send(session: active)
        if active, let cur = InputSourceManager.current() {
            // 세션 시작: 뷰어를 보고 있는 쪽(클라이언트)의 상태로 상대를 정렬
            lastKnownID = cur.id
            send(input: cur)
        }
        onStateChange?()
    }

    // MARK: - 메시지 송신

    private func send(input state: InputSourceManager.State) {
        push(SyncMessage(origin: instanceID, kind: .input,
                         sourceID: state.id, isKorean: state.isKorean))
    }

    private func send(session active: Bool) {
        push(SyncMessage(origin: instanceID, kind: .session, sessionActive: active))
    }

    private func push(_ msg: SyncMessage, requiresTrust: Bool = true) {
        guard var data = try? JSONEncoder().encode(msg) else { return }
        data.append(0x0A) // "\n"
        netQueue.async {
            var directPeerIDs: Set<String> = []
            for (key, conn) in self.connections {
                guard case .ready = conn.state else { continue }
                guard !requiresTrust || self.trustedConnectionKeys.contains(key) else { continue }
                if let origin = self.originByKey[key] { directPeerIDs.insert(origin) }
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
            if requiresTrust {
                self.relay.publish(msg, excluding: directPeerIDs)
            }
        }
    }

    // MARK: - 메시지 수신 (netQueue에서 호출)

    private func handle(_ msg: SyncMessage, fromKey key: String) {
        guard msg.origin != instanceID else { return }
        if msg.kind == .hello {
            guard let publicKey = msg.publicKey,
                  SecureIdentity.deviceID(for: publicKey) == msg.origin else {
                connections[key]?.cancel()
                return
            }
            if let trustedKey = peerPublicKeys[msg.origin], trustedKey != publicKey {
                connections[key]?.cancel()
                return
            }
        }
        if let boundOrigin = originByKey[key] {
            guard boundOrigin == msg.origin else {
                connections[key]?.cancel()
                return
            }
        } else {
            originByKey[key] = msg.origin
        }
        if trustedOrigins.contains(msg.origin),
           trustedConnectionKeys.insert(key).inserted,
           !key.hasPrefix("relay-") {
            // 새 직접 연결이 신뢰되면 그 연결로 내 주소를 알린다. 릴레이가 막혀 있어도
            // 같은 네트워크에서 만난 Mac끼리 Tailscale 주소를 배워 두게 된다.
            sendAddresses(onKey: key)
        }
        guard ProtocolSecurity.permits(
            msg.kind,
            enabled: enabled,
            trusted: trustedConnectionKeys.contains(key),
            pairingMode: Date() < pairingUntil
        ) else { return }

        switch msg.kind {
        case .hello:
            if msg.pairingRequest == true,
               !trustedOrigins.contains(msg.origin),
               pairingHelloRepliedOrigins.insert(msg.origin).inserted {
                push(
                    SyncMessage(
                        origin: instanceID,
                        kind: .hello,
                        name: hostName,
                        publicKey: identity?.publicKeyBase64,
                        pairingRequest: true
                    ),
                    requiresTrust: false
                )
            }
            requestApproval(for: msg)
            DispatchQueue.main.async {
                self.namesByOrigin[msg.origin] = msg.name ?? "Mac"
            }
            recountPeers()
        case .session:
            let active = msg.sessionActive == true
            DispatchQueue.main.async {
                if active {
                    self.remoteActive[msg.origin] = Date()
                } else {
                    self.remoteActive.removeValue(forKey: msg.origin)
                }
                self.onStateChange?()
            }
        case .pair:
            // 1차 긴급 수정: 페어링 UI/상호 인증이 완성되기 전에는 키를
            // 저장하거나 응답하지 않는다. 명시적 120초 창도 후속 승인 흐름 전용이다.
            return
        case .input:
            guard let sourceID = msg.sourceID else { return }
            DispatchQueue.main.async {
                guard self.syncAllowed else { return }
                if let cur = InputSourceManager.current(), cur.id == sourceID { return } // 이미 동일
                self.suppressUntil = Date().addingTimeInterval(1.0)
                self.lastKnownID = sourceID
                InputSourceManager.apply(id: sourceID, isKorean: msg.isKorean ?? false)
                self.onStateChange?()
            }
        case .address:
            applyTailscaleAddresses(msg.addresses ?? [], from: msg.origin)
            let now = Date()
            if AddressReplyPolicy.shouldReply(
                wantsReply: msg.wantsReply == true,
                lastReply: addressRepliesByOrigin[msg.origin],
                now: now
            ) {
                addressRepliesByOrigin[msg.origin] = now
                sendAddresses(toOrigin: msg.origin, wantsReply: false)
            }
        }
    }

    /// 후속 승인 UI에서만 호출한다. 이 창 자체는 어떤 키도 신뢰/저장하지 않는다.
    func beginPairingMode() {
        netQueue.async {
            self.pairingUntil = Date().addingTimeInterval(Self.pairingDuration)
            self.pairingHelloRepliedOrigins.removeAll()
            // 자동으로 찾기는 같은 네트워크(Bonjour)에서만 동작한다.
            // 다른 네트워크의 Mac은 초대 코드로 페어링하고, 그 뒤 Tailscale 주소를 교환한다.
            self.push(
                SyncMessage(
                    origin: self.instanceID,
                    kind: .hello,
                    name: self.hostName,
                    publicKey: self.identity?.publicKeyBase64,
                    pairingRequest: true
                ),
                requiresTrust: false
            )
        }
    }

    func createRemotePairingInvite() -> String? {
        guard let publicKey = identity?.publicKeyBase64 else { return nil }
        beginPairingMode()
        netQueue.async {
            self.localRemoteApprovals.removeAll()
            self.remoteApprovedOrigins.removeAll()
        }
        return rendezvous.createInvite(publicKey: publicKey, name: hostName)
    }

    func joinRemotePairing(invite: String) -> Bool {
        guard let publicKey = identity?.publicKeyBase64 else { return false }
        beginPairingMode()
        netQueue.async {
            self.localRemoteApprovals.removeAll()
            self.remoteApprovedOrigins.removeAll()
        }
        return rendezvous.join(inviteText: invite, publicKey: publicKey, name: hostName)
    }

    func forgetPeer(id: String) {
        netQueue.async {
            self.trustedOrigins.remove(id)
            self.peerPublicKeys.removeValue(forKey: id)
            self.tailscaleIPsByOrigin.removeValue(forKey: id)
            self.addressRepliesByOrigin.removeValue(forKey: id)
            self.persistTrustedPeers()
            self.relay.remove(peerID: id)
            for (key, origin) in self.originByKey where origin == id {
                self.connections[key]?.cancel()
            }
            self.recountPeers()
        }
    }

    func resetPairings() {
        netQueue.async {
            let peerIDs = Array(self.peerPublicKeys.keys)
            self.trustedOrigins.removeAll()
            self.peerPublicKeys.removeAll()
            self.tailscaleIPsByOrigin.removeAll()
            self.addressRepliesByOrigin.removeAll()
            self.persistTrustedPeers()
            for peerID in peerIDs { self.relay.remove(peerID: peerID) }
            for connection in self.connections.values { connection.cancel() }
            self.recountPeers()
        }
    }

    private func persistTrustedPeers() {
        UserDefaults.standard.set(
            trustedOrigins.sorted(),
            forKey: Self.trustedOriginsDefaults
        )
        UserDefaults.standard.set(peerPublicKeys, forKey: Self.peerPublicKeysDefaults)
        UserDefaults.standard.set(tailscaleIPsByOrigin, forKey: Self.tailscaleIPsDefaults)
    }

    private func requestApproval(for message: SyncMessage, allowWithoutConnection: Bool = false) {
        let origin = message.origin
        guard let publicKey = message.publicKey,
              let identity,
              let confirmationCode = identity.confirmationCode(with: publicKey),
              message.pairingRequest == true
        else { return }
        guard !trustedOrigins.contains(origin),
              !pendingApprovalOrigins.contains(origin) else { return }
        pendingApprovalOrigins.insert(origin)
        let peerName = message.name ?? "Mac"
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L10n.t(.connectionRequest)
            alert.informativeText =
                String(format: L10n.t(.connectionRequestBody), peerName)
                + "\n\n"
                + String(format: L10n.t(.pairingCode), confirmationCode)
                + "\n"
                + L10n.t(.pairingHint)
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.t(.approve))
            alert.addButton(withTitle: L10n.t(.reject))
            let remember = NSButton(checkboxWithTitle: L10n.t(.alwaysTrustDevice), target: nil, action: nil)
            remember.state = .on
            alert.accessoryView = remember
            let approved = alert.runModal() == .alertFirstButtonReturn
            let persist = remember.state == .on
            self.netQueue.async {
                self.pendingApprovalOrigins.remove(origin)
                let matchingKeys = self.originByKey.compactMap { connectionKey, peerOrigin in
                    peerOrigin == origin ? connectionKey : nil
                }
                guard allowWithoutConnection || !matchingKeys.isEmpty else { return }
                if approved {
                    if allowWithoutConnection {
                        self.localRemoteApprovals[origin] = (publicKey, persist, peerName)
                        self.rendezvous.publishApproval(
                            publicKey: identity.publicKeyBase64,
                            name: self.hostName
                        )
                        self.finishRemoteApprovalIfReady(origin: origin)
                        return
                    }
                    self.trustedOrigins.insert(origin)
                    if persist {
                        self.peerPublicKeys[origin] = publicKey
                        self.persistTrustedPeers()
                    }
                    DispatchQueue.main.async {
                        self.namesByOrigin[origin] = peerName
                    }
                    if let secret = identity.sharedSecret(with: publicKey) {
                        self.relay.configure(peerID: origin, sharedSecret: secret)
                    }
                    self.trustedConnectionKeys.formUnion(matchingKeys)
                    // 상대가 아직 승인하지 않았다면 이 알림은 버려지지만, 상대가 승인하면서
                    // 응답을 요청하므로 결국 양쪽 모두 주소를 받게 된다.
                    self.sendAddresses(toOrigin: origin, wantsReply: true)
                    self.recountPeers()
                    DispatchQueue.main.async {
                        self.onPairingComplete?()
                        guard self.enabled else { return }
                        if let cur = InputSourceManager.current() {
                            self.send(session: self.localViewerActive)
                            self.send(input: cur)
                        }
                    }
                } else {
                    for connectionKey in matchingKeys {
                        self.connections[connectionKey]?.cancel()
                    }
                }
            }
        }
    }

    private func finishRemoteApprovalIfReady(origin: String) {
        guard remoteApprovedOrigins.contains(origin),
              let approval = localRemoteApprovals.removeValue(forKey: origin),
              let identity,
              identity.sharedSecret(with: approval.key) != nil
        else { return }
        remoteApprovedOrigins.remove(origin)
        trustedOrigins.insert(origin)
        if approval.persist {
            peerPublicKeys[origin] = approval.key
            persistTrustedPeers()
        }
        DispatchQueue.main.async {
            self.namesByOrigin[origin] = approval.name
        }
        if let secret = identity.sharedSecret(with: approval.key) {
            relay.configure(peerID: origin, sharedSecret: secret)
        }
        // 방금 만든 릴레이 구독이 자리 잡은 뒤에 알려야 상대의 응답을 놓치지 않는다.
        netQueue.asyncAfter(deadline: .now() + Self.addressAnnouncementDelay) {
            self.sendAddresses(toOrigin: origin, wantsReply: true)
        }
        recountPeers()
        DispatchQueue.main.async {
            self.onPairingComplete?()
            self.onStateChange?()
            let alert = NSAlert()
            alert.messageText = L10n.t(.pairingComplete)
            alert.informativeText = String(format: L10n.t(.pairingCompleteBody), approval.name)
            alert.runModal()
        }
    }

    // MARK: - 네트워크 파라미터 (저지연 튜닝)

    /// TCP_NODELAY(Nagle 비활성)로 소형 메시지를 즉시 전송 — 체감 지연의 핵심 해결책
    private static func tunedTCPParams() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true            // 패킷 모아 보내기 비활성 → 즉시 전송
        tcp.enableKeepalive = true    // 끊긴 연결 조기 감지
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .responsiveData // 응답성 우선 QoS
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    // MARK: - 리스너 (수신 대기 + Bonjour 광고)

    private func startListener() {
        let params = Self.tunedTCPParams()
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            l.newConnectionHandler = { [weak self] conn in
                self?.adopt(conn, key: "in-\(UUID().uuidString)")
            }
            l.stateUpdateHandler = { state in
                NSLog("HangulSync listener: \(state)")
            }
            l.start(queue: netQueue)
            listener = l
        } catch {
            NSLog("HangulSync listener 시작 실패: \(error)")
        }
    }

    // MARK: - Bonjour 탐색 (같은 네트워크)

    private func startBonjourBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.lastBonjourResults = results
            self.connectBonjourPeers()
        }
        b.start(queue: netQueue)
        browser = b
    }

    /// netQueue에서 호출. 끊긴 피어가 있으면 다시 연결 시도.
    private func connectBonjourPeers() {
        for result in lastBonjourResults {
            guard case let NWEndpoint.service(name, _, _, _) = result.endpoint else { continue }
            guard name != serviceName else { continue } // 자기 자신 제외
            let key = "bonjour-\(name)"
            if connections[key] == nil {
                let conn = NWConnection(to: result.endpoint, using: Self.tunedTCPParams())
                adopt(conn, key: key)
            }
        }
    }

    // MARK: - 주기 작업 (30초): Tailscale 주소 확인·재연결·세션 유지·만료 정리

    private func startTimer() {
        let tick: () -> Void = { [weak self] in
            guard let self else { return }
            self.updateViewerState() // 뷰어 실행 상태 안전망 재확인
            self.netQueue.async {
                // 경로 변경 이벤트를 놓쳐도 주소 변화를 잡는 보조 확인(인터페이스 조회 1회)
                self.refreshLocalTailscaleAddresses()
                self.connectBonjourPeers()
                self.connectKnownTailscalePeers()
            }
            // 세션 신호 유지 재전송
            if self.localViewerActive,
               Date().timeIntervalSince(self.lastSessionBroadcast) > Self.sessionRefresh {
                self.lastSessionBroadcast = Date()
                self.send(session: true)
            }
            // 만료된 원격 세션 정리
            let now = Date()
            let before = self.remoteActive.count
            self.remoteActive = self.remoteActive.filter { now.timeIntervalSince($0.value) < Self.sessionTTL }
            if self.remoteActive.count != before { self.onStateChange?() }
        }
        tick()
        let t = Timer(timeInterval: 30, repeats: true) { _ in tick() }
        t.tolerance = 5 // OS가 타이머를 묶어 깨울 수 있게 여유 부여 (전력·CPU 절약)
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    // MARK: - Tailscale 경로 (이미 켜져 있을 때만 사용)
    // Tailscale 실행 파일은 호출하지 않는다. 내 주소는 인터페이스에서 읽고,
    // 상대 주소는 페어링된 Mac에게서 암호화 채널(.address 메시지)로만 받는다.

    /// 네트워크 경로가 바뀔 때(Tailscale 연결·해제 포함) 내 주소를 다시 확인한다.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            self.refreshLocalTailscaleAddresses()
            // 경로 이벤트보다 인터페이스에 주소가 늦게 붙을 수 있어 한 번 더 확인한다.
            self.netQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refreshLocalTailscaleAddresses()
            }
        }
        pathMonitor.start(queue: netQueue)
    }

    /// netQueue에서 호출. 내 Tailscale 주소가 바뀌었을 때만 알림과 연결 정리를 한다.
    private func refreshLocalTailscaleAddresses(announceChange: Bool = true) {
        let detected = tailscalePathAllowed ? TailscaleAddress.current() : []
        guard detected != localTailscaleAddresses else { return }
        localTailscaleAddresses = detected
        NSLog("HangulSync: Tailscale 경로 \(detected.isEmpty ? "사용 안 함" : "사용 가능(주소 \(detected.count)개)")")
        if detected.isEmpty { cancelTailscaleConnections() }
        if announceChange { announceAddresses(wantsReply: true) }
        connectKnownTailscalePeers()
    }

    /// netQueue에서 호출. 페어링된 Mac이 알려 준 Tailscale 주소로 직접 연결한다.
    /// 내 Mac에 Tailscale 주소가 없으면(꺼짐·미설치·토글 끔) 시도하지 않는다.
    private func connectKnownTailscalePeers() {
        guard !localTailscaleAddresses.isEmpty else { return }
        for (origin, ip) in tailscaleIPsByOrigin where trustedOrigins.contains(origin) {
            guard !localTailscaleAddresses.contains(ip) else { continue }
            let key = "ts-\(ip)"
            guard connections[key] == nil else { continue }
            let connection = NWConnection(
                host: NWEndpoint.Host(ip),
                port: NWEndpoint.Port(rawValue: Self.port)!,
                using: Self.tunedTCPParams()
            )
            adopt(connection, key: key)
        }
    }

    /// netQueue에서 호출. 연결 정리는 상태 콜백(.cancelled)에 맡겨 신뢰 표시가 함께 지워지게 한다.
    private func cancelTailscaleConnections(for origin: String? = nil) {
        let savedKey = origin.flatMap { tailscaleIPsByOrigin[$0] }.map { "ts-\($0)" }
        for (key, connection) in connections where key.hasPrefix("ts-") {
            if let origin, originByKey[key] != origin, key != savedKey { continue }
            connection.cancel()
        }
    }

    /// netQueue에서 호출. 상대가 알린 주소를 저장하고, 바뀌었으면 기존 Tailscale 연결을 정리한다.
    /// 빈 목록이면 상대의 Tailscale이 꺼졌거나 토글이 꺼진 것이므로 그 Mac으로 시도하지 않는다.
    private func applyTailscaleAddresses(_ addresses: [String], from origin: String) {
        guard trustedOrigins.contains(origin) else { return }
        let next = TailscaleAddress.preferred(addresses)
        if tailscaleIPsByOrigin[origin] != next {
            cancelTailscaleConnections(for: origin)
            tailscaleIPsByOrigin[origin] = next
            UserDefaults.standard.set(tailscaleIPsByOrigin, forKey: Self.tailscaleIPsDefaults)
        }
        connectKnownTailscalePeers()
    }

    private func addressMessage(wantsReply: Bool) -> SyncMessage {
        SyncMessage(
            origin: instanceID,
            kind: .address,
            addresses: localTailscaleAddresses,
            wantsReply: wantsReply
        )
    }

    /// netQueue에서 호출. 페어링된 모든 Mac에 알린다(직접 연결 우선, 없으면 릴레이).
    private func announceAddresses(wantsReply: Bool) {
        push(addressMessage(wantsReply: wantsReply))
    }

    /// netQueue에서 호출. 한 Mac에만 알린다(직접 연결 우선, 없으면 그 Mac의 릴레이).
    private func sendAddresses(toOrigin origin: String, wantsReply: Bool) {
        guard trustedOrigins.contains(origin) else { return }
        let message = addressMessage(wantsReply: wantsReply)
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        var sentDirectly = false
        for (key, connection) in connections where originByKey[key] == origin {
            guard case .ready = connection.state, trustedConnectionKeys.contains(key) else { continue }
            connection.send(content: data, completion: .contentProcessed { _ in })
            sentDirectly = true
        }
        if !sentDirectly { relay.publish(message, to: origin) }
    }

    /// netQueue에서 호출. 방금 신뢰된 직접 연결 하나로만 알린다(응답 요청 없음).
    private func sendAddresses(onKey key: String) {
        guard let connection = connections[key], case .ready = connection.state,
              var data = try? JSONEncoder().encode(addressMessage(wantsReply: false))
        else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - 연결 관리

    /// 연결을 등록하고 시작 (netQueue에서 호출됨)
    private func adopt(_ conn: NWConnection, key: String) {
        connections[key] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.recountPeers()
                let pairingRequested = Date() < self.pairingUntil
                DispatchQueue.main.async {
                    // 이름 소개 (피어 목록·고유 카운트용)
                    self.push(
                        SyncMessage(
                            origin: self.instanceID,
                            kind: .hello,
                            name: self.hostName,
                            publicKey: self.identity?.publicKeyBase64,
                            pairingRequest: pairingRequested
                        ),
                        requiresTrust: false
                    )
                    // 내가 원격 세션 중이면 새 피어에게 즉시 알림 + 상태 정렬
                    if self.localViewerActive {
                        self.send(session: true)
                        if let cur = InputSourceManager.current() { self.send(input: cur) }
                    }
                }
            case .failed(_), .cancelled:
                self.netQueue.async {
                    if self.connections[key] === conn {
                        self.connections.removeValue(forKey: key)
                        self.messageTimesByKey.removeValue(forKey: key)
                        self.trustedConnectionKeys.remove(key)
                        if let origin = self.originByKey.removeValue(forKey: key),
                           !self.originByKey.values.contains(origin) {
                            DispatchQueue.main.async {
                                self.remoteActive.removeValue(forKey: origin)
                                self.onStateChange?()
                            }
                        }
                    }
                    self.recountPeers()
                }
            case .waiting(_):
                // 상대가 아직 앱을 안 켠 경우 등 — Network.framework가 자동 재시도하므로 유지
                self.recountPeers()
            default:
                break
            }
        }
        receiveLoop(conn, key: key, buffer: Data())
        conn.start(queue: netQueue)
    }

    /// 연결 개수가 아니라 "고유한 Mac" 기준으로 집계
    /// (두 맥이 서로 동시에 연결 + Tailscale 경로가 겹치면 연결은 2~4개가 되므로)
    private func recountPeers() {
        netQueue.async {
            var keyByOrigin: [String: String] = [:] // origin → 대표 연결 key
            for (key, conn) in self.connections {
                guard case .ready = conn.state else { continue }
                guard self.trustedConnectionKeys.contains(key) else { continue }
                guard let origin = self.originByKey[key] else { continue }
                // 경로 우선순위: 같은 네트워크 > Tailscale > 수신
                if let existing = keyByOrigin[origin] {
                    let rank: (String) -> Int = { $0.hasPrefix("bonjour") ? 0 : $0.hasPrefix("ts-") ? 1 : 2 }
                    if rank(key) < rank(existing) { keyByOrigin[origin] = key }
                } else {
                    keyByOrigin[origin] = key
                }
            }
            keyByOrigin = PeerInventory.includingRelayFallbacks(
                direct: keyByOrigin,
                trustedOrigins: self.trustedOrigins
            )
            DispatchQueue.main.async {
                self.readyPeerCount = keyByOrigin.count
                self.peerInfo = keyByOrigin.map { origin, key in
                    let name = self.namesByOrigin[origin] ?? "Mac"
                    let via: L10n.Key = key.hasPrefix("bonjour") ? .viaLocalNetwork
                        : key.hasPrefix("ts-") ? .viaTailscale
                        : key.hasPrefix("relay-") ? .viaEncryptedRelay
                        : .viaIncoming
                    return (origin, name, L10n.t(via))
                }.sorted { $0.name < $1.name }
                self.onStateChange?()
            }
        }
    }

    private func receiveLoop(_ conn: NWConnection, key: String, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard buf.count <= ProtocolSecurity.maxBufferBytes else {
                conn.cancel()
                return
            }
            while let newlineIndex = buf.firstIndex(of: 0x0A) {
                let line = buf.prefix(upTo: newlineIndex)
                buf = Data(buf.suffix(from: buf.index(after: newlineIndex)))
                guard line.count <= ProtocolSecurity.maxMessageBytes else {
                    conn.cancel()
                    return
                }
                if let msg = ProtocolSecurity.decode(Data(line)) {
                    let now = Date()
                    var recent = self.messageTimesByKey[key, default: []]
                        .filter { now.timeIntervalSince($0) < 1 }
                    guard recent.count < 30 else {
                        conn.cancel()
                        return
                    }
                    recent.append(now)
                    self.messageTimesByKey[key] = recent
                    self.handle(msg, fromKey: key)
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receiveLoop(conn, key: key, buffer: buf)
        }
    }
}
