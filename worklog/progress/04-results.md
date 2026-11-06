# 04. 결과

2026-11-06 기준. 설계 v3는 구현되어 빌드와 자동 테스트를 통과했고 PR #1로 올렸다.
이 Mac(새 빌드)과 구버전 원격 Mac을 **같은 네트워크에서** 연결해 한/영 동기화가 작동하는 것까지 실사용으로 확인했다([05](05-installation-and-field-test.md)).
**다른 네트워크(Tailscale) 경로와 주소 교환은 아직 검증하지 못했다.**

## 1. 현재 상태

| 항목 | 내용 |
|---|---|
| 브랜치 | `feature/tailscale-passive-path` (베이스 `main` = `f2d471a`) |
| 푸시·PR | 3개 커밋을 `origin`에 푸시했고 [PR #1](https://github.com/Feverbypassion/HangulSync_CH/pull/1)(초안 아님, 기준 `main`)을 만들었다. **이 기록을 추가한 커밋은 아직 푸시하지 않았다** |
| 커밋 작성자 | 사용자가 지정한 작성자(Chris Hong)로 정했고, 이 저장소의 로컬 git 설정에도 같은 값이 들어 있다. 처음에는 임시 값으로 커밋해 작성자를 한 번 고쳤고, 그래서 아래 해시는 수정 후의 값이다. 업스트림 커밋 `f2d471a`는 건드리지 않았다 |
| 원격 저장소 | `origin` = `Feverbypassion/HangulSync_CH`(공개). 이 저장소의 `main`은 `f2d471a`로 로컬 베이스와 같다. 업스트림은 `catgarret/HangulSync` |
| CI | GitHub Actions `build-test`는 코드를 실행하기 전에 "The configuration 'macos-14-arm64-us-default' is not supported"로 **취소**되었다(`ci.yml`의 `runs-on: macos-14`). 대신 로컬에서 같은 단계를 재현했다(2.4) |
| 설치 | 이 Mac의 `/Applications/HangulSync.app`을 새 빌드로 교체했다(사용자 지시로 백업 없이). 원격 Mac은 구버전이다 |

| 커밋 | 내용 |
|---|---|
| `8d61a0b` | 저장소 주소를 `Feverbypassion/HangulSync_CH`로 변경 — README 8개, 앱 내 링크, 업데이트 확인 주소, `deploy.sh` (11개 파일, +22/−22) |
| `65758f1` | Tailscale 프로그램을 실행하지 않고 직접 경로를 쓰도록 자동 탐지 개편 — 소스, 테스트, 문구, README 문구, 릴리스 노트 (18개 파일, +600/−137) |
| `c3b055b` | 작업 기록 `worklog/`(배경, 설계, 구현, 결과, 이슈 01·02) |
| (이 커밋) | 설치와 현장 시험 기록, 이슈 03·04, 이 문서 갱신 |

저장소 주소 변경은 작업 트리에 이미 반영되어 있었다. 같은 파일(README 8개, `main.swift`)이 기능 변경과 섞여 있어, 주소 치환만 적용한 버전을 먼저 커밋하고 그 위에 기능 변경을 커밋했다.
이슈 01·02의 줄 번호 참조는 `65758f1` 기준이다.

## 2. 검증 결과

### 2.1 자동 검증 (모두 통과)

| 검증 | 결과 |
|---|---|
| `swift build` (디버그) | 통과, 경고 출력 없음 |
| `swift build -c release` | 통과 |
| `swift test` | **29개 통과, 실패 0** — `ProtocolSecurityTests` 12, `SecurePairingTests` 6, `TailscaleAddressTests` 11 |
| EndToEndSmoke (실제 ntfy.sh) | `END_TO_END_PASS`. 초대 교환, 상호 승인, 암호화 릴레이 입력 메시지 왕복에 더해 **`.address` 메시지의 릴레이 왕복** 확인 |

실패한 시도 하나: 처음 `swift test`에서 `testServiceAddressesAndMalformedTextAreRejected`가 실패했다(`fd7a:115c:a1e0::1%utun3`이 거부되지 않음).
원인은 Darwin `inet_pton`이 범위 표기를 허용하는 것이었고, 입력 문자 사전 검사로 고친 뒤 29개가 전부 통과했다([03](03-implementation.md) 5장).

### 2.2 "HangulSync가 Tailscale을 실행하지 않는다"의 코드 수준 확인

같은 패턴으로 설치되어 있던 구버전과 새 release 빌드를 비교했다.

| 검사 | 구버전 | 새 빌드 |
|---|:-:|:-:|
| `strings`에서 `Tailscale.app/Contents` 또는 `/bin/tailscale` 경로 문자열 | 3개 | **0개** |
| `nm -u`에서 `NSTask`·`posix_spawn`·`execv` 참조 | 1개 (`_OBJC_CLASS_$_NSTask`) | **0개** |

새 빌드에는 Tailscale 실행 파일을 가리키는 문자열도, 프로세스를 실행하는 클래스 참조도 없다.
실행 중인 Mac에서는 설치 직후 약 50초(표본 11회) 동안만 관찰했고, 그동안 HangulSync의 자식 프로세스와 Tailscale 앱 프로세스는 없었다([05](05-installation-and-field-test.md) 2장). 사용자가 중단해 **끝까지 하지 못했다.**

### 2.3 이슈 조사 중 수행한 실험

| 실험 | 내용 | 결과 |
|---|---|---|
| A. 구버전 호환 | `git show main:...ProtocolSecurity.swift`를 컴파일해 `.address` JSON을 디코드 | `nil (dropped)`. 대조군 `.session` JSON은 정상 수락 → 구버전은 `.address`를 조용히 버림 |
| B. 수신 연결의 원격 주소 | 루프백에서 `NWListener`로 받은 연결의 `currentPath?.remoteEndpoint` 조회 | `127.0.0.1:<포트>`로 읽힘. **비-루프백 주소로 건 연결은 이 실행 환경에서 `Connection reset by peer`로 끝나 확인하지 못했고, 원인은 조사하지 않았다** |
| C. 실제 앱의 수신 대기 | 설치된 앱에 `lsof -nP -iTCP:47820 -sTCP:LISTEN` | `*:47820 (LISTEN)` — 특정 인터페이스에 묶이지 않음 |
| D. 신·구 메시지 해석 | 같은 소스를 구버전·신버전 `ProtocolSecurity.swift`와 각각 컴파일해 서로의 메시지를 읽힘 | hello(2종)·세션(2종)·입력(2종)은 양방향 모두 수락. `.address`만 구버전이 거부 |

### 2.4 PR 이후 로컬 클린 빌드 (CI 대체)

PR의 헤드 커밋 `c3b055b`를 임시 디렉터리에 새로 클론해 CI 단계를 재현했다.

| 확인 | 결과 |
|---|---|
| `swift build` / `swift build -c release` | 통과, 오류 0·경고 0 |
| `swift test` | 29개 통과, 실패 0 |
| `./build.sh` | 통과. ad-hoc 서명 유효, 번들 ID `com.local.hangulsync`, 번들 실행 파일에 Tailscale 경로 문자열 0개 |
| `Tools/EndToEndSmoke.swift` | 컴파일 통과(네트워크 실행은 하지 않음) |
| 쉘 스크립트 4개 | `bash -n` 문법 오류 없음. **ShellCheck는 설치되어 있지 않아 실행하지 못했다** |

로컬 툴체인은 Swift 6.4.2·macOS 26이고 CI 설정은 `macos-14`다. 더 낮은 버전에서의 빌드는 확인하지 못했다.

### 2.5 실사용 확인 요약

새 빌드(이 Mac) + 구버전(원격 Mac), 같은 네트워크에서 원격 → 로컬 한/영 동기화가 작동했다. 상세와 한계는 [05](05-installation-and-field-test.md).
설치 직후 동기화가 멈춘 문제는 Keychain 신원 초기화가 원인이었다([이슈 03](../issues/03-keychain-identity-reset-on-reinstall.md)).

## 3. 설계의 검증 시나리오 진행 상황

| # | 시나리오 | 상태 |
|---|---|---|
| 1 | Tailscale 종료·VPN 끊김·미설치 각각 1시간 관찰해도 HangulSync가 Tailscale 프로세스를 띄우지 않는다 | **부분.** 코드·바이너리 수준 확인(2.2), 설치 직후 약 50초 관찰(중단됨). 1시간 관찰은 미실행 |
| 2 | 같은 네트워크에서 Bonjour 경로로 동기화 | **확인(구버전 원격과의 구성).** 재페어링 후 원격 한/영 전환 7번이 같은 초에 반영됨 |
| 3 | 다른 네트워크, 양쪽 Tailscale 연결 → 알림 뒤 Tailscale 경로 | 미실행 |
| 4 | 한쪽 Tailscale 끊김 → 릴레이 전환·연결 시도 중단, 재연결 → 직접 경로 복귀 | 미실행 |
| 5 | 한쪽을 나중에 켜도 응답 알림으로 양쪽이 주소 확보 | 미실행 (릴레이 왕복 자체는 Smoke로 확인) |
| 6 | 초대 코드로 다른 네트워크 첫 페어링 → 직후 Tailscale 경로 | 미실행. 초대 코드 페어링 자체는 같은 네트워크에서 사용됨(이슈 04) |
| 7 | 구버전과 섞어 써도 오류 없이 동작 | **부분.** 같은 네트워크 구성에서 동작 확인, 메시지 호환은 실험 D로 확인. 다른 경로에서의 동작은 미확인 |
| 8 | (토글) 끄면 Tailscale 경로가 없어지고 상대도 시도 중단 | 미실행. 구버전 상대의 경우 이슈 01 |
| 9 | Tailscale 미설치 Mac에 영향 없음 | 미실행 |

## 4. 알려진 한계 (각각 별도 이슈 문서)

| 이슈 | 요약 | 종류·심각도 |
|---|---|---|
| [01 — 토글을 꺼도 Tailscale로 들어오는 연결은 받는다](../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md) | 구버전 Mac이 CLI로 찾아 접속해 오면 신버전은 스위치가 꺼져 있어도 수신 연결로 받는다. 스위치는 "내가 먼저 거는 것"만 막는다 | 설계 한계, 낮음 |
| [02 — 직접 연결은 신뢰된 Mac인지 증명하지 않는다](../issues/02-direct-connection-lacks-peer-authentication.md) | 신뢰 판정이 메시지 안의 `origin` 문자열만 본다. hello 위조도 필요 없다. 이번 변경의 `.address`가 이 약점의 영향 범위를 넓혔다 | 기존 결함 + 확대, 낮음~중간 |
| [03 — 재설치 때 Keychain 읽기에 실패하면 신원 키가 조용히 새로 만들어진다](../issues/03-keychain-identity-reset-on-reinstall.md) | 서명이 바뀌는 재설치에서 허용 창이 승인되지 않으면 신원이 바뀌어 동기화가 멈춘다. **실제로 발생했고 재페어링으로 복구했다** | 기존 결함 + 설치 절차, 중간 |
| [04 — 초대 코드 페어링 중 429 오류 창](../issues/04-pairing-error-dialog-on-ntfy-429.md) | 공용 ntfy 요청 제한에 걸리면, 중복 전송 중 일부만 실패해도 오류 창이 먼저 뜬다. 페어링은 이후 완료됨 | 사용성, 낮음 |

**이슈 02는 처음 보고보다 범위가 넓다.** 완료 보고에서는 "hello가 서명이 아니라 공개키만 보낸다"고만 적었으나, 확인해 보니 hello가 아닌 메시지도 `origin`만 맞으면 신뢰된다.
이 판정은 변경 전 `main`(`SyncEngine.swift:300-301`)에도 있었다. 실제 공격은 재현하지 않았다.

## 5. 남은 작업

### 5.1 결정이 필요한 것

1. **이슈 02의 임시 완화(옵션 D)를 이번 브랜치에 넣을지.** `.address`를 릴레이(인증된 경로)로 온 것만 받고 `sendAddresses(onKey:)`를 제거한다. 대가는 릴레이가 막힌 환경에서 주소를 새로 배우지 못하는 것.
2. **이슈 01의 수신 연결 필터(옵션 B)를 구현할지**, 문구·README에 한계로만 남길지.
3. **업스트림(`catgarret/HangulSync`) PR 방식.** 이 저장소의 푸시 대상은 새 저장소다. 업스트림에 기여하려면 tailnet 자동 찾기가 사라지는 점을 옵트인으로 남길지 따로 정해야 하고, 업스트림 PR에는 fork가 필요하다.
4. 직접 연결 상호 인증(이슈 02 옵션 A·B)의 호환 정책.
5. **이슈 03의 `loadOrCreate` 수정을 이 PR에 넣을지**, 별도 PR로 할지. 실제로 동기화를 멈춘 결함이다.
6. **CI의 `macos-14` 러너 설정**을 바꿀지. 현재 이 저장소에서는 CI가 시작되지 않는다.

### 5.2 실행 순서 제안

1. 위 결정을 반영한 추가 커밋과 푸시(푸시는 사용자가 요청할 때만).
2. 원격 Mac에 새 빌드를 설치하려면 이 Mac에서 겪은 것과 같은 Keychain 창이 뜨므로 **모두 "항상 허용"으로 승인**한다(이슈 03 7장). 설치 뒤 재페어링이 필요할 수 있다.
3. 두 Mac에서 3장의 미실행 시나리오를 실행한다. 특히 1(Issue #2 핵심)과 3·4(Tailscale 경로), 이슈 01의 재현.
4. 구현 중 확인할 것으로 남긴 두 가지:
   - `NWPathMonitor`가 Tailscale 연결·해제 때 이벤트를 주는지(주지 않으면 30초 틱이 보완). **미확인**
   - 이 Mac의 Tailscale 인터페이스 이름·주소 구성. 당시 VPN이 끊겨 있어 **미확인** — `detect`의 `utun` 가정이 실제와 맞는지 이때 확인해야 한다.

### 5.3 미검증 항목 요약

- 다른 네트워크·Tailscale 구성의 모든 실사용 시나리오(3장의 3~6, 8, 9)와 1시간 관찰
- `NWPathMonitor` 이벤트 발생 여부, 실제 Tailscale 인터페이스 구성
- 알림 지연값(시작·페어링 후 3초, 경로 이벤트 후 2초)의 적절성
- 이슈 01의 IPv4-mapped IPv6 표기, 이슈 02의 실제 위장 접속·패킷 평문 노출·방화벽 영향
- 이슈 03의 재부팅 후 동작과 원격 Mac 설치 시 동작, 이슈 04의 요청 제한 값과 소진 요청
- 이 Mac의 신뢰 목록이 재페어링 중 잠시 0개로 보인 이유([05](05-installation-and-field-test.md) 7장)

## 6. 이 작업에서 만든 기록과 파일

| 위치 | 내용 |
|---|---|
| `worklog/progress/` | 배경·설계·구현·결과·설치와 현장 시험 |
| `worklog/issues/` | 알려진 한계와 현장에서 확인된 문제 상세(01~04) |
| `.github/release-notes/v1.0.13.md` | 릴리스 노트 초안 |
| 임시 파일 | 실험·관찰 코드는 세션 스크래치 디렉터리에만 있고 저장소에는 넣지 않았다 |
