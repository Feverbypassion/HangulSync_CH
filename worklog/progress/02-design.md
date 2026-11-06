# 02. 설계

설계는 세 번 바뀌었다. 최종안은 v3이다. 구현 결과는 [03-implementation.md](03-implementation.md)에 있다.

## 1. 설계가 바뀐 과정

| 버전 | 핵심 | 바뀐 이유 |
|---|---|---|
| v1 | Notion 문서를 따라 **Tailscale 탐지 3모드**(Disabled / Manual / Automatic)를 추가. 버그 수정으로 CLI에 `TAILSCALE_BE_CLI=1`, 5초 타임아웃, 중복 실행 방지, "앱이 실행 중일 때만 CLI 호출" 가드를 넣음 | 처음 설계 |
| v2 | v1 + ① `TAILSCALE_BE_CLI=1` 효과를 먼저 검증(Phase 0) ② 자동 탐색이 꺼져 있으면 사용자가 다시 실행하기 전까지 CLI를 임의로 실행하지 않음 ③ 자동 탐색 중 Tailscale이 설치됐지만 꺼져 있으면 **실행 여부를 묻는 팝업** ④ 미설치면 탐색 기능 정지. 설치·실행 감지(`NSWorkspace` 알림)와 순수 정책 함수 도입 | 사용자 요구 세 가지(1) 검증 먼저 (2) 임의 실행 금지 (3) 팝업, 미설치 시 정지 |
| **v3 (최종)** | **HangulSync는 Tailscale의 어떤 구성 요소도 실행하지 않는다.** CLI 호출 전부 제거. Tailscale 주소는 내 Mac의 네트워크 인터페이스에서 읽고, 페어링된 Mac끼리 암호화 채널로 주소를 교환 | 사용자의 최종 요구: "HangulSync와 Tailscale은 **완전히 독립적인 관계**가 되어야 한다" |

사용자의 최종 요구가 나온 배경은 질문 세 가지였다.
1. CLI가 Tailscale 자체를 실행하는 것이라면 그것도 자동으로 실행하지 않기를 원한다.
2. Tailscale이 필수가 아니라면 자동 실행 조건에서 완전히 제거하면 어떤가.
3. Bonjour도 항상 실행되는 서비스가 아니라면 자동 탐지에서 뺄 수 있는가.

조사 결과([01](01-background-and-analysis.md) 5·6장): CLI는 Tailscale 실행 파일 그 자체이고, Tailscale은 필수가 아니며, Bonjour는 OS 데몬이라 HangulSync가 띄우는 것이 아니다.
이에 따라 v2의 **Phase 0(환경변수 검증), CLI 안전장치, 3모드 UI, 실행 팝업, 설치 감지를 모두 폐기**했다.
(팝업은 사용자 동의를 받더라도 결국 HangulSync가 Tailscale을 실행하는 경로이기 때문이다.)

### 검토했으나 채택하지 않은 안

| 안 | 내용 | 채택하지 않은 이유 |
|---|---|---|
| A안 | Tailscale 코드 전부 제거, 다른 네트워크에서는 릴레이만 사용 | 가장 단순하지만 Tailscale이 이미 켜져 있는 사용자의 직접 경로(낮은 지연, ntfy.sh 비의존)를 잃음 |
| v2의 3모드 | Disabled/Manual/Automatic 선택 UI | CLI를 호출하지 않으면 모드가 필요 없음 |
| Bonjour 끄기 토글 | 자동 탐지에서 Bonjour 제거 | Bonjour는 OS 데몬이라 실행 문제가 없고, 같은 네트워크에서 가장 빠른 경로 |
| 릴레이 끄기 토글 | — | 이번 범위 밖 |

## 2. 최종 설계 (v3, B안)

### 2.1 목표와 원칙

**목표:** HangulSync는 Tailscale의 GUI·CLI·시스템 확장 중 어느 것도 실행하거나 재시작하지 않는다.
Tailscale은 **사용자가 켜 두었을 때만 쓰는 네트워크 경로**다. Issue #2는 원인 코드를 없애서 해결한다.

| 원칙 | 내용 |
|---|---|
| P1 | Tailscale 실행 파일(CLI 포함)을 호출하지 않는다 |
| P2 | Tailscale 상태는 내 Mac의 네트워크 인터페이스(OS 조회)로만 판단한다 |
| P3 | 내 Mac에 Tailscale 주소가 없으면 Tailscale 경로로 연결을 시도하지 않는다 |
| P4 | 상대 Mac의 주소는 페어링된 Mac에게서 **암호화 채널로만** 받는다 |
| P5 | Bonjour, 암호화 릴레이, 초대 코드는 그대로 둔다 |
| P6 | 판단 로직은 순수 함수로 분리해 테스트한다 |

### 2.2 현재와 바뀌는 점

| 경로 | 변경 전 | 변경 후 |
|---|---|---|
| Bonjour 직접 연결 | 같은 네트워크 자동 탐지 | 그대로 |
| Tailscale 탐색 | 30초마다 + 페어링 시 CLI `status --json` | **삭제** |
| Tailscale 직접 연결 | CLI가 찾은 IP, 저장된 IP(시작 시 1회) | 상대가 알려준 주소와 저장된 주소. **내 Tailscale 주소가 있을 때만** 시도 |
| 수신 연결 | 모든 인터페이스에서 받음 | 그대로 |
| 암호화 릴레이 | 직접 경로가 없을 때 사용 | 그대로 + 주소 알림 전달 |
| 자동으로 찾기 | Bonjour + Tailscale CLI | Bonjour만. 다른 네트워크는 초대 코드 |

### 2.3 동작 설계

**(1) 내 Tailscale 주소 감지**
- `getifaddrs()`로 인터페이스를 읽는다. 이름이 `utun*`이고 켜져 있으며(UP·RUNNING) `fd7a:115c:a1e0::/48` IPv6 주소가 있는 인터페이스를 Tailscale로 본다.
  그 인터페이스의 `100.64.0.0/10` IPv4와 IPv6를 내 주소로 쓴다.
- **보조 규칙:** IPv6를 끈 tailnet을 위해 `fd7a` 주소가 없는 `utun`의 `100.64.0.0/10`도 채택한다. 이 대역은 통신사 CGNAT와 겹치므로 `en0` 같은 일반 인터페이스는 제외하고 `utun`으로 한정한다.
- Standalone, App Store, tailscaled 모두 `utun`을 쓰므로 설치 형태를 구분하지 않는다.
- 다시 확인하는 시점: 시작, `NWPathMonitor` 경로 변경, 30초 틱(보조). **결과가 바뀔 때만** 후속 동작을 한다.

**(2) 주소 알림 프로토콜**

새 메시지 종류 `.address` — 필드 `addresses: [String]`(0~4개, Tailscale 대역만)와 `wantsReply: Bool`.

| 보내는 시점 | 대상 | `wantsReply` |
|---|---|:-:|
| 앱 시작 직후(릴레이 구성 뒤) | 페어링된 모든 Mac | true |
| 내 주소가 생기거나 바뀌거나 사라짐(사라지면 빈 목록) | 모든 Mac | true |
| 새 Mac과 페어링 완료 | 그 Mac | true |
| 동기화 재개(일시정지 해제) | 모든 Mac | true |
| `wantsReply=true`를 받음 | 보낸 Mac | false (Mac당 30초에 1회) |

- 전송은 기존 `push()`(직접 연결 우선, 없으면 릴레이). 응답은 한 Mac에만 가야 하므로 `RelayChannel`에 단일 대상 전송을 공개한다.
- `wantsReply`가 필요한 이유: ntfy는 꺼져 있는 Mac에 보낸 메시지를 보관하지 않는다(`X-Cache: no`). 나중에 켜진 Mac이 알리면 그 응답으로 상대 주소를 받는다. 응답에는 응답 요청을 넣지 않아 메시지가 무한히 오가지 않는다.

**(3) 수신과 연결**
- `.address`는 신뢰된 Mac에게서만 받는다(`ProtocolSecurity.permits` 규칙 그대로 → 일시정지 중에는 거부, 재개 때 다시 알림).
- 받은 주소는 기존 `TrustedPeerTailscaleIPs`에 저장한다(키 이름을 유지해 기존 저장값을 이어서 쓴다). 빈 목록이면 저장값을 지우고 그 Mac으로의 `ts-` 연결을 끊는다.
- 연결 조건: 내 Tailscale 주소가 있고, 토글이 켜져 있고, 그 주소로 가는 `ts-` 연결이 아직 없을 것.
- 연결 시도 시점: 주소 수신, 내 주소가 생김, 시작, 30초 틱. `connectKnownTailscalePeers()`가 기존 `connectSavedTailscalePeers()`를 대체한다.
- 내 주소가 사라지면 나가는 `ts-` 연결을 모두 끊고 시도를 멈춘다.
- 연결 뒤에는 기존 hello 공개키 검증을 그대로 거친다.

**(4) 페어링 흐름**
- `beginPairingMode()`에서 Tailscale 탐색 호출과 대기 연결 정리 코드를 제거한다. 자동으로 찾기는 Bonjour만 쓴다.
- 다른 네트워크의 첫 페어링은 초대 코드. 페어링이 끝나면 바로 주소를 알리므로 양쪽에 Tailscale이 켜져 있으면 곧바로 직접 경로가 생긴다.
- **잃는 기능:** 페어링하지 않은 Mac을 tailnet에서 자동으로 찾는 기능.
- 안내 문구에 "같은 네트워크"를 명시한다.

**(5) "Tailscale 직접 연결 사용" 토글 (선택)**
- 옵션 카드에 스위치 1개, 기본 켜짐, `UserDefaults` 키 `UseTailscalePath`.
- 끄면 빈 목록을 알리고 `ts-` 연결을 끊고 상대 주소로 연결하지 않는다. Issue #2의 "설정 추가" 요청에 대응.

**(6) 상태 표시:** "Tailscale" 경로 라벨과 우선순위(Bonjour > Tailscale > 수신 > 릴레이)는 그대로.

### 2.4 보안과 호환성

**보안**
- 주소는 페어링된 Mac에게서 종단간 암호화 채널로만 받는다(릴레이 기준). ntfy 서버에는 암호문만 보인다.
- Tailscale 대역이 아닌 주소는 메시지 검증 단계에서 거부한다(임의의 내부망 호스트로 접속 유도 방지).
- 주소 최대 4개, 응답은 Mac당 30초에 1회.

**호환성**
- 구버전은 알 수 없는 `kind`를 해석하지 못해 메시지 전체를 버린다 → 기존 기능 영향 없음.
- 구버전은 여전히 CLI로 신버전을 찾아 연결해 올 수 있다(신버전은 수신 연결로 받음) → 이슈 [01](../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md) 참고.
- 새 필드는 `.address`에서만 허용하므로 기존 메시지는 그대로 해석된다.
- 저장된 Tailscale IP는 이어서 쓴다.

**업데이트 후 정리:** 구버전이 띄운 Tailscale 인스턴스(PID 15592)는 HangulSync를 종료해도 남으므로 한 번 직접 종료해야 한다.

### 2.5 변경 파일 계획

| 파일 | 계획 |
|---|---|
| `SyncEngine.swift` | 삭제 `pollTailscale`, `runTailscaleDiscovery`, `runTailscaleStatus`, 타이머 호출, 페어링 모드의 탐색부. 추가: 주소 감지 반영, `NWPathMonitor`, `.address` 송수신, `connectKnownTailscalePeers`. `startTimer` 유지. 주석 "20초"→30초 |
| `TailscaleAddress.swift` (신규) | `getifaddrs` 래퍼와 순수 판정 함수 `detect(interfaces:)` |
| `ProtocolSecurity.swift` | `.address` kind, 필드, 검증 규칙, 대역 검사 함수 (이 파일 안에 두면 `Tools/EndToEndSmoke.swift`의 컴파일 목록이 안 바뀜) |
| `RelayChannel.swift` | 단일 대상 전송 공개 |
| `main.swift`, `Localization.swift` | (선택) 토글, 8개 언어 문구, 자동으로 찾기 안내 수정 |
| README 8개 언어, 릴리스 노트 | "30초마다 탐지" 문구 교체, 초대 코드 안내 |

### 2.6 테스트 계획

- 신규 `TailscaleAddressTests`: 대역 경계(`100.63.255.255` ✗, `100.64.0.0` ✓, `100.127.255.255` ✓, `100.128.0.0` ✗, `fd7a:115c:a1e0::1` ✓, `fd7a:115c:a1e1::1` ✗), 인터페이스 판정(utun+fd7a+100.x ✓, `en0`의 100.x ✗, 다른 VPN의 10.x ✗, 꺼진 인터페이스 ✗, 보조 규칙).
- `ProtocolSecurityTests` 추가: `.address` 정상, 대역 밖/5개 이상/다른 필드 혼입 ✗, 다른 kind에 `addresses` ✗, 일시정지·미신뢰 거부.
- 응답 제한 순수 함수, (선택) EndToEndSmoke에 `.address` 릴레이 왕복.

### 2.7 단계와 PR 계획

| 단계 | 내용 | PR |
|---|---|---|
| Phase 1 | CLI 호출 전부 제거. 저장된 IP 재연결은 내 Tailscale 주소가 있을 때만 | Issue #2 버그 수정. 이것만으로 GUI 재실행이 사라짐 |
| Phase 2 | 주소 감지·알림·연결 | 기능 PR |
| Phase 3 | (선택) 토글과 다국어 | 기능 PR |
| Phase 4 | README 8개 언어, 릴리스 노트 | 기능 PR |

개인 사용이라면 Phase 1과 2를 함께 적용하는 것을 권장했다(Phase 1만으로는 새로 페어링한 Mac이나 IP가 바뀐 Mac의 주소를 알 방법이 없다).

### 2.8 검증 시나리오 (양쪽 Mac)

관찰: `pgrep -fl Tailscale`, `ps -o ppid`, `lsappinfo`.

1. **(Issue #2 핵심)** Tailscale 종료 / VPN 끊김 / 미설치 각각 1시간 관찰해도 HangulSync가 Tailscale 프로세스를 띄우지 않는다.
2. 같은 네트워크에서는 Bonjour 경로로 동기화된다.
3. 다른 네트워크에서 양쪽 Tailscale이 연결돼 있으면 알림 뒤 몇 초 안에 Tailscale 경로가 된다.
4. 한쪽 Tailscale이 끊기면 릴레이로 전환되고 연결 시도가 멈춘다. 다시 연결되면 직접 경로로 돌아온다.
5. 한쪽 HangulSync를 나중에 켜도 응답 알림으로 양쪽 모두 주소를 얻는다.
6. 초대 코드로 다른 네트워크 첫 페어링을 하면 끝나자마자 Tailscale 경로가 생긴다.
7. 구버전과 섞여 있어도 오류 없이 동작한다.
8. (토글) 끄면 Tailscale 경로가 없어지고 상대도 시도를 멈춘다.
9. Tailscale 미설치 Mac에는 아무 영향이 없다.

구현 중 확인할 것: `NWPathMonitor`가 VPN 연결/해제 때 이벤트를 주는지(주지 않으면 30초 틱이 보완), 이 Mac의 Tailscale 인터페이스 구성(당시 VPN이 끊겨 있어 확인 불가).

## 3. 결정 기록

| 결정 사항 | 결정 | 비고 |
|---|---|---|
| CLI 호출 | 전부 제거 | 사용자의 "완전 독립" 요구 |
| 실행 팝업, 설치 감지 | 제거 | 팝업도 HangulSync가 Tailscale을 실행하는 경로 |
| Bonjour | 유지 | OS 데몬, 같은 네트워크 최속 |
| 토글(Phase 3) | 추가, 기본 켜짐 | 권장안대로 진행 |
| 보조 규칙(`fd7a` 없는 `utun`의 `100.64.0.0/10`) | 채택 | 권장안대로 진행 |
| 브랜치 | 새 브랜치를 `main`에서 만들어 체크아웃 후 구현 | 사용자 지시. 이름은 `feature/tailscale-passive-path` |
| 업스트림(`catgarret/HangulSync`) PR | **미결** | tailnet 자동 찾기가 사라지는 점을 어떻게 다룰지(옵트인 CLI 탐색을 남길지)는 PR을 낼 때 따로 정함. 업스트림 PR에는 fork 필요. 이후 이 저장소의 `origin`은 `Feverbypassion/HangulSync_CH`로 바뀜 |
