# 이슈 02 — 직접 연결에서는 "이 Mac이 정말 신뢰된 Mac인지" 증명하지 않는다

| 항목 | 내용 |
|---|---|
| 상태 | 확인됨(코드 분석). **공격 재현·패킷 캡처는 하지 않음** |
| 발견 | 2026-11-06 — 구현 완료 보고에서 한 줄로 언급한 뒤, 이 문서에서 코드를 다시 읽고 범위를 정밀하게 확인 |
| 종류 | 보안 — 기존 코드의 결함 + 이번 변경(`.address`)이 넓힌 부분 |
| 심각도 | 낮음~중간 — 키 입력 내용·파일은 접근 불가. 입력 소스 상태 관찰·강제 전환과 주소 오염이 가능 |
| 범위 | Bonjour·Tailscale·수신 연결 등 **직접(TCP) 연결 전부**. 암호화 릴레이는 해당 없음 |
| 관련 | 이슈 [01](01-toggle-off-still-accepts-incoming-tailscale-connections.md), [진행 기록 04-results](../progress/04-results.md) |

## 1. 정정: 처음 보고한 내용보다 범위가 넓다

구현 완료 보고에서는 "직접 연결의 hello 메시지는 서명이 아니라 공개키만 보내서, 같은 네트워크의 누군가가 신뢰된 Mac인 척할 수 있다"고만 적었다.
코드를 다시 확인한 결과 **hello를 위조할 필요조차 없다.**

- 신뢰 판정은 hello가 아닌 **모든 종류의 메시지**에서 `msg.origin`(메시지 안에 적힌 자기 주장 문자열)이
  신뢰 목록에 있는지만 본다.
- 공개키 검증은 `kind == .hello`일 때만 실행되고, 그 검증도 "공개키의 해시가 origin과 같은가"와
  "저장된 공개키와 같은가"뿐이라 개인키를 가졌다는 증명이 아니다.

## 2. 확인한 사실

| # | 사실 | 근거 | 확인 방법 |
|---|---|---|---|
| F1 | 연결 직후 첫 메시지가 `input`·`session` 등 hello가 아니어도, origin이 신뢰 목록에 있으면 그 연결이 신뢰된다 | `handle()` — `main`의 `SyncEngine.swift:300-301`, 현재 브랜치 `SyncEngine.swift:347-353`. 같은 로직이며 이번 변경이 만든 것이 아님 | 코드 읽기, `git show main:...`로 대조 |
| F2 | 공개키 검증(해시 일치, 저장된 키 일치)은 hello에서만 실행된다 | `SyncEngine.swift:328-338` | 코드 읽기 |
| F3 | origin(deviceID)은 공개키의 SHA-256 전체(64자리 16진수)이고 **비밀이 아니다** | `SecureIdentity.swift:13`(`deviceID`), `:49`(`deviceID(for:)`) | 코드 읽기 |
| F4 | 직접 연결은 암호화되지 않은 TCP이고 메시지는 평문 JSON이라 origin이 그대로 실린다 | `tunedTCPParams()`의 `NWParameters(tls: nil, tcp:)` (`SyncEngine.swift:617`) | 코드 읽기. **패킷 캡처는 하지 않음** |
| F5 | Bonjour 서비스 이름에는 deviceID 앞 8자리만 들어간다 | `serviceName = "\(host)-\(deviceID.prefix(8))"` (`SyncEngine.swift:160`) | 코드 읽기 |
| F6 | 암호화 릴레이는 다르다. 쌍별 키(Curve25519 합의로 유도)로 ChaChaPoly 봉인하고 sender·recipient·origin 일치, ±120초 타임스탬프, 순서번호를 검사한다 | `RelayChannel.swift:175-187` | 코드 읽기, EndToEndSmoke로 릴레이 왕복 통과 |
| F7 | 신뢰된 직접 연결에는 상태가 **들어오기도 나가기도** 한다. `push()`는 `trustedConnectionKeys`에 있는 모든 연결로 입력·세션 상태를 보낸다 | `push()` (`SyncEngine.swift:307`, 필터 `:314`) | 코드 읽기 |
| F8 | Bonjour로 보인 서비스는 이름이 내 것과 다르면 무조건 내가 먼저 접속한다 | `connectBonjourPeers()` (`SyncEngine.swift:660`, `:663`) | 코드 읽기 |
| F9 | hello는 상대의 신뢰 여부와 무관하게 아무 연결에나 먼저 보낸다(`requiresTrust: false`) | `SyncEngine.swift:374`, `:435`, `:829` | 코드 읽기 |
| F10 | 두 Mac 사이에는 이미 공유 비밀이 있다 | `identity.sharedSecret(with:)`를 릴레이가 쓰고 있음 | 코드 읽기 |

**README와의 관계:** README는 "새 직접 연결은 사용자가 승인한 뒤에만 입력 상태를 주고받음"(`README.md:49-50`)이라고 적는다.
이 승인(6자리 확인 코드)은 **처음 페어링할 때**의 보호다. 이미 신뢰된 Mac으로 **위장하는 것**은 막지 않는다.

## 3. 공격자 모델

**필요한 것**
1. 피해 Mac A와 직접 TCP로 통신할 수 있는 위치: 같은 LAN, 같은 tailnet, 또는 A가 접속하도록 유도할 수 있는 Bonjour 광고(F8).
   방화벽 설정에 따른 도달 가능성은 **확인하지 않았다.**
2. A가 신뢰하는 Mac B의 deviceID(64자리). 얻는 길은 A↔B 직접 통신의 평문 관찰(F4), 또는 과거에 페어링에 관여한 경우.
   Bonjour 이름만으로는 8자리뿐이라 부족하다(F5). 릴레이 통신에서는 얻을 수 없다(F6).

**할 수 있는 일**: A에 접속해 첫 메시지의 origin에 B의 ID를 적는다. A는 그 연결을 신뢰한다(F1).

## 4. 영향

개인키가 필요한 작업(릴레이 복호화, 페어링 승인)은 할 수 없다. 입력 내용·파일에는 접근하지 못한다.

| 가능한 일 | 방법 | 조건 | 평가 |
|---|---|---|---|
| 상태 관찰 | A가 `push()`로 보내는 입력 소스 ID·한/영 상태·세션 활성 신호를 그대로 수신 (F7) | 연결 유지 | 사용자의 활동 시점이 드러남. 내용은 아님 |
| 입력 소스 강제 전환 | `.input` 전송 (`SyncEngine.swift:396`) | A의 `syncAllowed`가 참일 때 | 한/영이 바뀌면 사용자의 입력이 의도와 달라질 수 있다. 직접적인 정보 탈취는 아님 |
| 동기화 게이트 열기 | `.session(active: true)` 전송 (`SyncEngine.swift:382`) | `onlyDuringRemote` 사용 중 | 원격 세션이 아닌데도 신호 하나당 최대 600초(`sessionTTL`) 동기화가 활성화됨. 반복해서 보내면 계속 유지됨 |
| 주소 오염 | `.address` 전송 (`SyncEngine.swift:406`) | 이번 변경으로 생긴 표면. 5장 참고 | 5장 참고 |

## 5. 이번 변경(`.address`)과의 관계

신뢰된 직접 연결로 온 `.address`는 `applyTailscaleAddresses()`(`SyncEngine.swift:759`)가 그대로 받아
`tailscaleIPsByOrigin[B]`를 덮어쓰고 `UserDefaults`에 **영구 저장**한다.
위장한 연결도 신뢰되므로(2장의 F1) 이 경로를 쓸 수 있다.

**이미 있는 완화**
- 주소는 Tailscale 대역(`100.64.0.0/10`, `fd7a:115c:a1e0::/48`)만 허용하고 `100.100.100.100`과 `fd7a:115c:a1e0::53`(quad100)은 거부한다
  (`ProtocolSecurity.tailscaleAddress`). 내부망의 임의 호스트로 접속을 유도할 수는 없다.
- 주소는 최대 4개다.
- 새 주소로 연결해도 hello 검증은 거치지만, F1·F2 때문에 이 검증이 위장을 막지 못한다.

**남는 위험**

| 위험 | 내용 | 확인 수준 |
|---|---|---|
| 가용성 | B의 실제 Tailscale 주소가 가짜 주소로 바뀌면 B로의 직접 경로를 잃고 **릴레이로 대체**된다. 동기화는 유지된다. B가 다시 주소를 알리면 복구된다. 알림 시점은 B의 시작, B의 주소 변화, 일시정지 해제, 새 직접 연결 신뢰이고 **30초 타이머는 다시 알리지 않는다** | 코드로 추정. 실험 안 함 |
| 지속성 | 오염된 주소가 저장되므로 A를 재시작해도 A가 가짜 주소로 접속을 시도한다(A의 Tailscale이 켜져 있을 때) | 코드로 추정. 실험 안 함 |
| 접속 유도 | 공격자가 tailnet 안의 노드이고 A의 Tailscale이 켜져 있으면 A가 공격자 쪽으로 **나가는** 연결을 연다. 단 이 조건이면 공격자는 이미 A의 포트에 직접 접속할 수 있어 추가되는 위협은 제한적이다 | 논리적 추론 |

**설계 결정과의 관계:** 구현 중 추가한 "새 직접 연결이 신뢰되면 그 연결로 내 주소를 보낸다"
(`sendAddresses(onKey:)`, `SyncEngine.swift:800`)는 **인증되지 않은 채널로 주소를 교환하는 경로**를 만든다.
릴레이로만 교환했다면 이 표면은 없다. 이 추가는 "릴레이가 막혀도 같은 LAN의 Mac끼리 주소를 배우게 한다"는 이점이 있었으나
이 이슈가 확인되면서 **이점과 위험을 다시 따져야 하는 항목**이 되었다.

## 6. 해결 옵션

| 옵션 | 내용 | 장점 | 단점·주의 |
|---|---|---|---|
| **A. 직접 연결 상호 인증 (근본 해결)** | 연결 직후 양쪽이 nonce를 교환하고, 공유 비밀에서 HKDF(도메인 분리 문자열 예: `"HangulSync direct-auth v1"`)로 유도한 키로 `HMAC(양쪽 nonce ‖ 양쪽 origin)`을 보내 증명. 검증 전에는 `trustedConnectionKeys`에 넣지 않는다 | 위장 차단. 이미 있는 공유 비밀을 사용(F10) | **구버전 호환**: 구버전은 증명을 보낼 수 없어 신↔구 직접 연결은 신뢰되지 않고 릴레이로만 연결됨. 전환용으로 hello에 프로토콜 버전을 넣고 구버전 허용 여부를 정해야 함 |
| B. 직접 채널 메시지 봉인 | 릴레이와 같은 방식(ChaChaPoly, 쌍별 키)으로 직접 채널의 메시지도 봉인 | 인증과 기밀성(관찰 차단)을 함께 얻음 | A와 같은 호환 문제. 릴레이 키와 직접 채널 키는 도메인 분리 필요 |
| C. TLS-PSK | Network.framework의 TLS에 공유 비밀 기반 PSK 사용 | 표준 기법 | 프로토콜 전체 변경, 구현 복잡도 큼 |
| **D. 이번 브랜치의 임시 완화** | `.address`는 인증된 경로(`relay-` 키)로 온 것만 적용하고 `sendAddresses(onKey:)`를 제거 | 변경이 작고 호환 문제 없음. `.address`로 늘어난 표면이 사라짐 | 릴레이가 막힌 환경에서는 주소를 새로 배우지 못함(이미 저장된 주소와 같은 LAN의 Bonjour는 영향 없음). F1~F9의 기존 결함은 그대로 남음 |

## 7. 권장 순서

1. **이번 브랜치 범위**: 옵션 D를 적용할지 결정한다. 적용하면 `.address`가 새로 만든 위험은 없어진다.
2. **별도 작업**: 옵션 A(또는 B)를 설계한다. 호환 정책(구버전 허용 기간, 버전 필드)을 먼저 정해야 한다.
3. 업스트림 저장소(`catgarret/HangulSync`)에 알리려면 프로토콜 변경이라 별도 이슈로 논의하는 것이 맞다.
   이 환경에서는 `gh`에 로그인되어 있지 않다.

## 8. 아직 확인하지 못한 것

- **실제 위장 접속을 재현하지 않았다.** 설치된 앱이 고정 포트 47820을 쓰고 있고, `SyncEngine`은 사용자의 Keychain 신원과
  `UserDefaults`를 읽는다. 검증 도구를 만들더라도 실제 신원·설정을 건드릴 위험이 있어 코드 분석으로만 확인했다.
- 직접 연결의 평문 노출은 코드(`tls: nil`)로만 확인했고 패킷을 캡처하지 않았다.
- A의 방화벽이 외부에서 오는 연결을 막는지 확인하지 않았다.
- 5장의 "복구 시점"은 코드를 읽은 추정이며 두 Mac으로 확인하지 않았다.

## 9. 수락 기준

- [ ] 신뢰된 Mac의 origin만 알고 있는 연결은 신뢰되지 않는다(옵션 A·B를 채택한 경우).
- [ ] 신뢰된 연결만 `.input`·`.session`·`.address`를 보낼 수 있고, 위장 연결의 `.address`가 저장소(`UserDefaults`)를 바꾸지 못한다.
- [ ] 정상적인 신↔신 연결은 기존처럼 자동 재연결된다.
- [ ] 구버전과의 호환 정책이 문서에 적혀 있다(릴레이 대체인지, 허용 기간인지).
- [ ] 인증 실패·성공을 구분하는 단위 테스트가 있다.

## 10. 관련 코드

줄 번호는 `feature/tailscale-passive-path`의 커밋 `65758f1` 기준이다.

| 위치 | 내용 |
|---|---|
| `Sources/HangulSync/SyncEngine.swift:326-354` | `handle()` — hello 검증(328-338), origin 바인딩(339-346), 신뢰 판정(347-353), 허용 검사(354) |
| `Sources/HangulSync/SyncEngine.swift:307` | `push()` — 신뢰된 연결로 상태 전송 |
| `Sources/HangulSync/SyncEngine.swift:617` | `NWParameters(tls: nil, ...)` |
| `Sources/HangulSync/SyncEngine.swift:660` | `connectBonjourPeers()` |
| `Sources/HangulSync/SyncEngine.swift:759` | `applyTailscaleAddresses()` |
| `Sources/HangulSync/SyncEngine.swift:800` | `sendAddresses(onKey:)` |
| `Sources/HangulSync/SecureIdentity.swift:13` | `deviceID` = SHA-256(공개키) |
| `Sources/HangulSync/RelayChannel.swift:175-187` | 릴레이의 인증 검사 |
| `git show main:Sources/HangulSync/SyncEngine.swift` 의 300-301행 | 변경 전에도 같은 신뢰 판정 |
