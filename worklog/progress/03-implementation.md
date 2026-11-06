# 03. 구현 진행

2026-11-06. 설계 v3([02-design.md](02-design.md))를 Phase 1~4까지 한 번에 구현했다.
구현하는 동안에는 커밋하지 않았고 모든 변경이 하나의 작업 트리에 있었다. 이후 커밋할 때 Phase별로 나누지 않고
기능 변경 전체를 커밋 하나(`65758f1`)로 묶었다. 같은 파일을 여러 Phase가 함께 고쳤기 때문이다([04](04-results.md) 1장).

## 1. 브랜치

사용자 지시: "새로운 브랜치를 만들어 진행하고, 해당 브랜치는 main을 베이스로 하며, 새로 생성된 브랜치로 체크아웃한 다음 진행한다."

```bash
git fetch origin main                                  # origin/main == main == f2d471a
git checkout -b feature/tailscale-passive-path main    # 작업 트리가 깨끗한 것을 확인한 뒤 생성·체크아웃
```

- 베이스: `main` (`f2d471a 자동 페어링 안내와 재연결 안정성 개선`)
- 작업 브랜치: `feature/tailscale-passive-path`
- 변경 규모: 추적 중인 15개 파일 +401/−137, 신규 3개 파일(80줄 + 105줄 + 14줄)

## 2. 변경 내용

### 2.1 프로토콜 — `Sources/HangulSync/ProtocolSecurity.swift`

- `SyncMessageKind.address` 추가. `SyncMessage`에 `addresses: [String]?`, `wantsReply: Bool?` 추가(없으면 JSON에 나타나지 않아 기존 메시지 모양은 그대로).
- `maxAddressCount = 4`.
- `tailscaleAddress(_:) -> String?`: Tailscale 대역 주소면 정규화한 문자열을, 아니면 `nil`.
  - IPv4 `100.64.0.0/10`(첫 바이트 100, 둘째 바이트 상위 2비트 `01`), IPv6 `fd7a:115c:a1e0::/48`.
  - **Tailscale 자체 서비스 주소(quad100) `100.100.100.100`, `fd7a:115c:a1e0::53`은 거부.**
  - 입력은 숫자 표기 문자(16진수·`.`·`:`)만 허용한다. Darwin의 `inet_pton`이 `%utun3` 같은 범위 표기를 받아들이기 때문이다(5장 참고).
- `validate`: `addresses`·`wantsReply`는 `.address`에서만 허용. `.address`는 두 필드가 모두 있고, 주소 4개 이하, 전부 Tailscale 대역이며, 다른 필드는 모두 `nil`이어야 한다.
- 이 파일 안에 두었으므로 `Tools/EndToEndSmoke.swift` 컴파일 파일 목록은 바뀌지 않았다.

### 2.2 주소 감지 — `Sources/HangulSync/TailscaleAddress.swift` (신규)

- `detect(interfaces:)` 순수 함수: **켜져 있는(UP·RUNNING) `utun*` 인터페이스**의 Tailscale 대역 주소만 고른다. `en0` 같은 일반 인터페이스의 `100.x`(통신사 CGNAT)와 다른 VPN의 사설 주소는 제외한다.
  IPv4 → IPv6 순으로 정렬하고 중복을 제거하며 4개로 제한해 같은 상태에서는 항상 같은 목록이 나온다.
- `current()`: `getifaddrs()` + `getnameinfo(NI_NUMERICHOST)`로 인터페이스 목록을 읽어 `detect`에 넘긴다. **Tailscale 프로그램은 실행하지 않는다.**
- `preferred(_:)`: 상대가 알려 준 주소 중 연결에 쓸 하나(IPv4 우선).
- `AddressReplyPolicy.shouldReply(wantsReply:lastReply:now:)`: 응답 요청이 있고 같은 Mac에 마지막 응답 후 30초가 지났을 때만 응답. 시계가 뒤로 바뀌면 오래 막히지 않게 허용한다.

### 2.3 엔진 — `Sources/HangulSync/SyncEngine.swift`

**삭제:** `pollTailscale`, `runTailscaleDiscovery`, `runTailscaleStatus`(CLI 실행), `connectSavedTailscalePeers`, `rememberTailscaleIP`, 타이머의 `pollTailscale()` 호출, `beginPairingMode()`의 대기 `ts-` 연결 정리와 탐색 호출.

**추가:**

| 구성 | 역할 |
|---|---|
| `NWPathMonitor` + `startPathMonitor()` | 네트워크 경로가 바뀔 때 내 주소를 다시 확인. 인터페이스에 주소가 늦게 붙을 수 있어 2초 뒤 한 번 더 확인 |
| `refreshLocalTailscaleAddresses()` | 주소가 **바뀌었을 때만** 로그 출력, 사라지면 `ts-` 연결 정리, 변화를 알림, 연결 시도 |
| `connectKnownTailscalePeers()` | 내 주소가 있을 때만, 신뢰된 Mac의 저장된 주소로 `ts-<ip>` 연결 |
| `cancelTailscaleConnections(for:)` | `ts-` 연결 취소(정리는 상태 콜백에 맡김) |
| `applyTailscaleAddresses(_:from:)` | 받은 주소 저장·갱신. 바뀌면 기존 연결 정리, 빈 목록이면 저장값 삭제 |
| `announceAddresses` / `sendAddresses(toOrigin:)` / `sendAddresses(onKey:)` | 모든 Mac / 한 Mac / 방금 신뢰된 직접 연결 하나에 알림 |
| `useTailscalePath` | 토글. 변경 시 `UserDefaults`에 저장하고 `netQueue`의 사본을 갱신 |

**알림이 나가는 시점(구현 결과)**

| 시점 | 방법 |
|---|---|
| 앱 시작 3초 뒤 | `announceAddresses(wantsReply: true)` — 릴레이 구독이 자리 잡을 시간을 준다 |
| 내 주소 변화 | `refreshLocalTailscaleAddresses` → `announceAddresses(wantsReply: true)` |
| 동기화 재개 | `enabled`의 `didSet` |
| 승인창으로 페어링 완료 | `sendAddresses(toOrigin:, wantsReply: true)` |
| 초대 코드 페어링 완료 | 3초 뒤 `sendAddresses(toOrigin:, wantsReply: true)` |
| 새 직접 연결이 신뢰됨 | `sendAddresses(onKey:)` (응답 요청 없음) |
| 응답 요청을 받음 | `AddressReplyPolicy` 통과 시 `sendAddresses(toOrigin:, wantsReply: false)` |

**기타:** 시작할 때 저장된 주소는 Tailscale 대역이고 **아직 신뢰하는 Mac의 것만** 불러온다. `forgetPeer`·`resetPairings`는 응답 시각 기록도 지운다.
`startTimer`는 유지하되 틱에서 주소 확인 → Bonjour 재연결 → Tailscale 재연결을 `netQueue`에서 수행한다. 주석 "20초"는 30초로 고쳤다.

### 2.3.1 `RelayChannel.swift`

`publish(_:to:)`를 `private`에서 기본(internal) 접근으로 바꿔 한 Mac에만 보낼 수 있게 했다.

### 2.4 UI와 다국어 — `main.swift`, `Localization.swift`

- 옵션 카드에 **Tailscale 직접 연결 사용** 스위치 1행(제목 + 부제)을 추가하고 `refresh()`와 액션 `toggleTailscalePath`를 연결했다(`main.swift` +12줄).
- 새 키 `useTailscalePath`, `useTailscalePathHint`를 8개 언어에 추가했다.
- **쓰이지 않던 키 `nearbyPairing`을 삭제**했다(한국어 값이 "자동 연결 / Tailscale"이었음). 사용처가 없음을 `grep`으로 확인했다.
- 문구 수정(8개 언어): `searchStartedBody`에 "같은 네트워크의 Mac만 찾으며 다른 네트워크는 초대 코드를 사용"을 추가,
  `pairingRelayErrorBody`의 "Tailscale에서 자동으로 찾기" 안내를 "같은 네트워크에서 자동으로 찾기"로 변경.
- `L10n.t`는 영어 표를 강제 언래핑하므로 영어 표에 모든 새 키를 넣었다.

### 2.5 문서

- `README.md`와 `docs/README.{en,ja,zh-CN,zh-TW,th,ru,it}.md`: "같은 tailnet의 피어를 30초마다 탐지" 문구를 "두 Mac에 Tailscale이 이미 켜져 있으면 페어링된 Mac끼리 주소를 교환해 직접 연결. HangulSync는 Tailscale을 실행하지 않으며 설정에서 끌 수 있음"으로 교체.
  한국어·영어판에는 첫 페어링 절차에 "자동으로 찾기는 같은 네트워크만, 다른 네트워크는 초대 코드"도 추가.
- `.github/release-notes/v1.0.13.md` 신규(가장 최근 태그가 `v1.0.12`라서 다음 번호로 정함. 실제 릴리스 번호는 태그를 만들 때 정해야 한다).

### 2.6 테스트

| 파일 | 변경 | 테스트 수 |
|---|---|:-:|
| `Tests/HangulSyncTests/TailscaleAddressTests.swift` (신규) | 대역 경계(IPv4/IPv6), 정규화, quad100·범위 표기·잘못된 문자열 거부, 인터페이스 판정(utun, CGNAT, 다른 VPN, 꺼진 인터페이스, IPv4 전용 tailnet), 정렬·개수 제한, `preferred`, 응답 제한 | 11 |
| `Tests/HangulSyncTests/ProtocolSecurityTests.swift` | `.address` 정상/대역 밖·개수 초과/모양 규칙(필수·금지 필드, 다른 kind 혼입)/기존 메시지 와이어 형식 유지/일시정지·미신뢰 거부 | 7 → 12 |
| `Tests/HangulSyncTests/SecurePairingTests.swift` | 변경 없음 | 6 |
| `Tools/EndToEndSmoke.swift` | `.address` 메시지가 실제 ntfy 릴레이를 왕복하는지 확인하는 단계 추가 | — |

## 3. 설계와 달라진 점

| # | 달라진 점 | 이유 | 비고 |
|---|---|---|---|
| 1 | **새 직접 연결이 신뢰되면 그 연결로 내 주소를 보내는 경로(`sendAddresses(onKey:)`)를 추가** | 릴레이가 막혀도 같은 네트워크에서 만난 Mac끼리 주소를 배우게 하려고 | 이 경로가 인증되지 않은 채널로 주소를 교환한다는 점이 이후 확인됨 → 이슈 [02](../issues/02-direct-connection-lacks-peer-authentication.md) 5장 |
| 2 | `tailscaleAddress`가 quad100(`100.100.100.100`, `fd7a:115c:a1e0::53`)도 거부 | 이 주소는 기기 주소가 아니라 Tailscale 서비스 주소 | 테스트 포함 |
| 3 | 감지 규칙을 단순화: 켜진 `utun`의 Tailscale 대역 주소는 `fd7a` 주소 유무와 관계없이 채택 | 설계의 "주 규칙 + 보조 규칙"을 합치면 같은 결과 | 설계의 보조 규칙(결정 2)을 채택한 것과 동일한 효과 |
| 4 | 저장된 주소를 읽을 때 Tailscale 대역 검사 + 신뢰 중인 Mac만 남김 | 이전 버전이 저장한 값을 그대로 믿지 않으려고 | |
| 5 | 시작·페어링 직후 알림을 3초 지연, 경로 이벤트 뒤 2초 재확인 | 릴레이 구독이 자리 잡기 전에 보내면 응답을 놓칠 수 있고, 인터페이스에 주소가 늦게 붙을 수 있음 | 3초·2초는 실측하지 않은 값 |
| 6 | 쓰이지 않던 `nearbyPairing` 키 삭제 | 설계의 "정리 필요" 항목 | |
| 7 | 남은 결정 중 토글(기본 켜짐, 1번)과 보조 규칙(2번)은 권장안대로 진행 | 사용자의 별도 지시가 없어 권장안 채택 | 브랜치(4번)는 사용자가 지시했고, 원본 PR(3번)은 미결 |

## 4. 단계별 매핑

| 단계 | 구현 내용 | 위치 |
|---|---|---|
| Phase 1 | CLI 호출 전부 제거 | `SyncEngine.swift` 삭제 목록(2.3) |
| Phase 2 | 주소 감지·알림·연결 | `TailscaleAddress.swift`, `ProtocolSecurity.swift`, `SyncEngine.swift`, `RelayChannel.swift` |
| Phase 3 | 토글과 다국어 | `main.swift`, `Localization.swift` |
| Phase 4 | README 8개 언어, 릴리스 노트 | `README.md`, `docs/`, `.github/release-notes/v1.0.13.md` |

## 5. 구현 중 발견한 문제

| 문제 | 증상 | 원인 | 해결 |
|---|---|---|---|
| `inet_pton`이 범위 표기를 받아들임 | `testServiceAddressesAndMalformedTextAreRejected` 실패. `fd7a:115c:a1e0::1%utun3`이 거부되지 않음 | Darwin의 `inet_pton`은 `%` 뒤 범위 표기를 허용 | 숫자 표기 문자(16진수·`.`·`:`)만 통과시키는 사전 검사 추가 → 29개 전부 통과 |
| EndToEndSmoke 실행 | `timeout: command not found` | macOS에 `timeout` 명령 없음 | 바이너리를 직접 실행 |

## 6. 구현 중 사용한 확인 방법

```bash
swift build                       # 디버그 빌드
swift test                        # 단위 테스트
swiftc Tools/EndToEndSmoke.swift Sources/HangulSync/{PairingRendezvous,RelayChannel,SecureIdentity,ProtocolSecurity}.swift -o <출력 경로>
<출력 경로>                        # 실제 ntfy.sh를 사용한 종단간 점검
swift build -c release            # 릴리스 빌드
strings <바이너리> | grep -iE "Tailscale.app|/bin/tailscale|status --json|MacOS/Tailscale"   # CLI 경로 잔존 여부
nm -u <바이너리> | grep -iE "NSTask|posix_spawn|execv"                                          # 프로세스 실행 함수 잔존 여부
```
