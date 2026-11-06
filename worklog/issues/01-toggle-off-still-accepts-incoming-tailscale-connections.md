# 이슈 01 — "Tailscale 직접 연결 사용"을 꺼도 Tailscale로 들어오는 연결은 받는다

| 항목 | 내용 |
|---|---|
| 상태 | 확인됨(코드·실측), 두 Mac 재현은 아직 안 함 |
| 발견 | 2026-11-06, `feature/tailscale-passive-path` 구현 직후 |
| 종류 | 설계 한계 (결함이라기보다 스위치의 범위가 사용자 기대보다 좁음) |
| 심각도 | 낮음 — 동기화 동작과 보안에는 영향 없음. 스위치가 약속하는 범위의 문제 |
| 영향 범위 | 신버전 Mac(스위치 OFF)과 구버전 Mac(v1.0.12 이하)이 같은 tailnet에 있을 때 |
| 관련 | [진행 기록 04-results](../progress/04-results.md), 이슈 [02](02-direct-connection-lacks-peer-authentication.md)와는 별개 |

## 1. 한 줄 요약

신버전에서 **Tailscale 직접 연결 사용**을 꺼도, 상대가 구버전이면 상대가 먼저 Tailscale 주소로 접속해 오고
신버전은 그 연결을 **수신 연결**로 그대로 받아 동기화한다. 스위치는 "내가 Tailscale로 먼저 거는 것"만 막는다.

## 2. 스위치가 실제로 하는 일

`SyncEngine.useTailscalePath`(`Sources/HangulSync/SyncEngine.swift:117`)를 끄면 다음이 일어난다.

1. `tailscalePathAllowed`가 `false`가 되고 `refreshLocalTailscaleAddresses()`가 실행된다.
2. 내 Tailscale 주소 목록이 **빈 목록**으로 바뀐다(`detected = tailscalePathAllowed ? ... : []`).
3. 빈 목록이 되면 `cancelTailscaleConnections()`가 키가 `ts-`로 시작하는 **내가 건 연결**을 모두 끊는다.
4. 빈 목록을 `.address` 메시지로 페어링된 Mac에 알린다(`announceAddresses`).
5. `connectKnownTailscalePeers()`는 `localTailscaleAddresses`가 비어 있으면 아무것도 하지 않는다.
   따라서 이후 Tailscale로 먼저 거는 연결은 없다.

**건드리지 않는 것:** 수신 대기(`NWListener`)와 `in-` 키로 들어온 연결.

## 3. 확인한 사실

| # | 사실 | 확인 방법 | 결과 |
|---|---|---|---|
| F1 | 수신 대기는 특정 인터페이스에 묶여 있지 않다 | **실측** — 이 Mac에서 실행 중인 설치본에 `lsof -nP -iTCP:47820 -sTCP:LISTEN` | `HangulSyn PID 15591 ... TCP *:47820 (LISTEN)` (와일드카드 바인딩) |
| F2 | 리스너 생성 코드에 인터페이스 제한이 없다 | **코드** — `startListener()` (`SyncEngine.swift:626`) | `NWListener(using: params, on: port)`. `params`는 `tunedTCPParams()`이고 `requiredInterface`·`prohibitedInterfaces`를 쓰지 않음 |
| F3 | 들어온 연결은 무조건 채택된다 | **코드** — `newConnectionHandler` (`SyncEngine.swift:631`) | 원격 주소를 보지 않고 `adopt(conn, key: "in-<UUID>")` |
| F4 | `in-` 연결도 신뢰될 수 있고 신뢰되면 동기화가 동작한다 | **코드** — `handle()` (`SyncEngine.swift:347`) | 신뢰 판정은 연결 키의 종류와 무관하게 `trustedOrigins.contains(msg.origin)`로 한다 |
| F5 | 스위치를 끌 때 정리되는 것은 `ts-` 연결뿐이다 | **코드** — `cancelTailscaleConnections()` (`SyncEngine.swift:749`) | `key.hasPrefix("ts-")`만 대상. `in-` 연결은 그대로 유지 |
| F6 | 구버전은 `.address`를 이해하지 못하고 조용히 버린다 | **실험 A** — `git show main:...ProtocolSecurity.swift`를 컴파일해 디코드 | `.address` JSON → `nil (dropped)`, 대조군 `.session` JSON → `accepted` |
| F7 | 구버전은 Tailscale CLI로 온라인 피어를 찾아 먼저 접속한다 | **코드**(`main`의 `pollTailscale`·`runTailscaleDiscovery`·`connectSavedTailscalePeers`)와 **실측**(설치본 실행 파일의 문자열에 CLI 경로 3개 존재) | 구버전은 상대 스위치 상태를 알 방법이 없다 |
| F8 | 수락한 연결에서 원격 주소를 읽을 수 있다 | **실험 B** — 루프백에서 `NWListener`로 연결을 받아 `.ready` 시점에 `currentPath?.remoteEndpoint` 조회 | `127.0.0.1:55897`처럼 읽힘 |

**실험 B의 한계:** 루프백이 아닌 주소(LAN 주소 두 개)로 건 연결은 이 실행 환경에서
`Connection reset by peer`로 끝나서 비-루프백 경로의 값은 확인하지 못했다. 원인은 조사하지 않았고
(실행 환경의 제약일 가능성이 있다), 이 결과는 어떤 결론의 근거로도 쓰지 않았다.
F1의 와일드카드 바인딩은 별도로 `lsof`로 확인했으므로 F2·F3의 근거는 유지된다.

## 4. 발생 시나리오 (코드 분석으로 도출, 두 Mac으로 재현하지 않음)

- Mac A: 신버전, **Tailscale 직접 연결 사용 = 꺼짐**, Tailscale은 켜져 있음.
- Mac B: 구버전(v1.0.12 이하), Tailscale 켜짐, 이전에 A와 페어링됨.

1. B의 30초 타이머(`pollTailscale`)가 CLI로 tailnet 피어를 조회하고 A가 온라인임을 알게 된다.
2. B가 A의 Tailscale 주소 `:47820`에 접속한다.
3. A의 리스너가 연결을 받는다(F2, F3). 키는 `in-<UUID>`다.
4. B가 hello를 보내면 A는 B의 공개키를 확인하고 신뢰된 연결로 등록한다(F4).
5. A의 설정 창에는 B가 **수신 연결**(`viaIncoming`)로 표시되고 입력 동기화는 정상 동작한다.
6. A가 보낸 빈 목록 `.address`는 B가 버린다(F6). B는 계속 같은 방식으로 접속한다.

신버전끼리라면 A의 빈 목록을 받은 B가 `applyTailscaleAddresses`로 저장된 주소를 지우고
`ts-` 연결을 끊으므로 이 현상은 생기지 않는다.

## 5. 영향

- **동기화·보안:** 영향 없음. 신뢰된 Mac과의 정상 연결이고, 연결이 끊기면 암호화 릴레이로 대체된다.
- **Issue #2의 목표(HangulSync가 Tailscale을 실행하지 않음):** 영향 없음.
  A는 Tailscale 프로그램을 실행하지 않는다. 구버전 B가 B의 Tailscale을 띄우는 것은 B의 문제이고 B를 업데이트하면 사라진다.
- **스위치 문구와의 관계:** 힌트 문구는 "Connects directly when Tailscale is already on for both Macs"
  (`Localization.swift:52`)로 **끄면 모든 Tailscale 통신이 없어진다고 약속하지 않는다.**
  다만 사용자가 "끄면 Tailscale로는 아무것도 오가지 않는다"고 기대할 수 있다.
- **스위치를 끄는 순간:** 이미 들어와 있던 수신 연결(F5)은 끊기지 않고 연결이 끊어질 때까지 유지된다.

## 6. 해결 옵션

| 옵션 | 내용 | 장점 | 단점 |
|---|---|---|---|
| A. 문구만 정리 | 힌트에 "상대가 구버전이면 상대가 먼저 연결해 올 수 있음"을 추가하거나 README에 한계로 명시 | 코드 변경 없음 | 사용자가 막고 싶으면 방법이 없음 |
| **B. 수신 연결 필터링 (권장)** | 수신 연결이 `.ready`가 되면 원격 주소를 읽고, Tailscale 대역이고 `tailscalePathAllowed == false`이면 연결을 취소. 스위치를 끌 때 이미 연결된 Tailscale 수신 연결도 함께 취소 | 스위치의 의미가 "Tailscale 경로 전체 차단"으로 명확해짐. 구버전 Mac은 릴레이로 자동 대체되어 동기화는 유지됨 | 아래 B-1~B-3 확인 필요 |
| C. 리스너 파라미터로 차단 | `prohibitedInterfaceTypes` 등으로 Tailscale 인터페이스 제외 | — | Tailscale의 `utun`은 인터페이스 종류가 `.other`라 다른 VPN·AWDL과 구분이 안 됨. **채택하지 않음** |

**옵션 B 구현 시 확인할 것**
- B-1. 판정 함수는 순수 함수로 분리해 테스트한다. 기존 `ProtocolSecurity.tailscaleAddress(_:)`를 재사용할 수 있다.
- B-2. 듀얼 스택 리스너가 IPv4 클라이언트를 IPv4-mapped IPv6 형태(`::ffff:100.x.y.z`)로 보여 줄 가능성이 있다.
  **이 형태는 확인하지 못했다.** 필터가 이 형태를 놓치면 차단되지 않으므로, 정규화하거나 실제 연결로 확인해야 한다.
- B-3. IPv6 링크 로컬 주소의 범위 표기(`%utun4`)처럼 `tailscaleAddress`가 거부하는 형태가 있다. 거부 = "Tailscale 아님"으로 취급해도 안전한지 확인한다.

## 7. 권장 순서

1. 두 Mac으로 4장 시나리오를 먼저 재현해 "수신 연결로 표시되고 동기화됨"을 확인한다.
2. 옵션 B를 구현하고, 2장의 5번 항목처럼 스위치를 끄는 순간 기존 수신 연결도 정리한다.
3. 판정 순수 함수 테스트(대역 경계, IPv4-mapped, 범위 표기)를 추가한다.
4. 구현하지 않기로 하면 옵션 A로 문구와 README에 한계를 남긴다.

## 8. 수락 기준

- [ ] 스위치 OFF 상태에서 구버전 Mac이 Tailscale 주소로 접속해도 신버전 Mac에 `in-` 연결이 남지 않는다(또는 문서에 한계로 명시되어 있다).
- [ ] 같은 상황에서 구버전과의 동기화는 암호화 릴레이로 계속 동작한다.
- [ ] 스위치를 끌 때 이미 연결된 Tailscale 수신 연결이 정리된다.
- [ ] 스위치 ON일 때의 동작(수신 연결 허용)은 바뀌지 않는다.
- [ ] 판정 함수 단위 테스트가 있다.

## 9. 관련 코드

줄 번호는 `feature/tailscale-passive-path`의 커밋 `65758f1` 기준이다.

| 위치 | 내용 |
|---|---|
| `Sources/HangulSync/SyncEngine.swift:117` | `useTailscalePath` |
| `Sources/HangulSync/SyncEngine.swift:626` | `startListener()` — 인터페이스 제한 없음 |
| `Sources/HangulSync/SyncEngine.swift:631` | `newConnectionHandler` — 원격 주소 검사 없음 |
| `Sources/HangulSync/SyncEngine.swift:347` | 신뢰 판정 (키 종류와 무관) |
| `Sources/HangulSync/SyncEngine.swift:749` | `cancelTailscaleConnections` — `ts-`만 정리 |
| `Sources/HangulSync/Localization.swift:52` | 스위치 힌트 문구(en) |
