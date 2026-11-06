# 04. 결과

2026-11-06 기준. 설계 v3는 구현되어 빌드와 자동 테스트를 통과했다.
**커밋은 했지만 푸시하지 않았고, 두 Mac에서의 실사용 검증은 아직 하지 않았다.**

## 1. 현재 상태

| 항목 | 내용 |
|---|---|
| 브랜치 | `feature/tailscale-passive-path` (베이스 `main` = `f2d471a`) |
| 커밋 | 3개, **푸시하지 않음** (아래 표) |
| 커밋 작성자 | 사용자가 지정한 작성자(Chris Hong)로 커밋 3개의 작성자·커미터를 수정했고, 이 저장소의 로컬 git 설정(`user.name`·`user.email`)에도 같은 값을 넣었다. 처음에는 이 Mac에 git 사용자 정보가 없어 임시 값으로 커밋했고, 그래서 아래 해시는 수정 후의 값이다. 작성 날짜와 파일 내용(트리 해시)은 그대로다. 업스트림 커밋 `f2d471a`는 건드리지 않았다 |
| 원격 저장소 | `origin` = `https://github.com/Feverbypassion/HangulSync_CH.git`. `git branch -vv`에 `main`이 `[origin/main: gone]`으로 표시된다. 새 저장소에 `main`이 있는지는 확인하지 않았다 |
| 설치 | **하지 않음.** 이 Mac의 `/Applications/HangulSync.app`은 여전히 구버전이다 |
| 이 Mac의 프로세스 | 구버전 HangulSync PID 15591이 실행 중이며, 그 자식 `Tailscale status --json`(PID 15592, 12:07 시작)이 아직 남아 있다. 시스템 확장 PID 13693 |

| 커밋 | 내용 |
|---|---|
| `8d61a0b` | 저장소 주소를 `Feverbypassion/HangulSync_CH`로 변경 — README 8개, 앱 내 링크, 업데이트 확인 주소, `deploy.sh` (11개 파일, +22/−22) |
| `65758f1` | Tailscale 프로그램을 실행하지 않고 직접 경로를 쓰도록 자동 탐지 개편 — 소스, 테스트, 문구, README 문구, 릴리스 노트 (18개 파일, +600/−137) |
| (이 커밋) | 작업 기록 `worklog/` |

저장소 주소 변경은 작업 트리에 이미 반영되어 있었다. 같은 파일(README 8개, `main.swift`)이 기능 변경과 섞여 있어, 주소 치환만 적용한 버전을 먼저 커밋하고 그 위에 기능 변경을 커밋했다.
각 커밋의 줄 번호 참조는 `65758f1` 기준이다.

## 2. 검증 결과

### 2.1 자동 검증 (모두 통과)

| 검증 | 결과 |
|---|---|
| `swift build` (디버그) | 통과, 경고 출력 없음 |
| `swift build -c release` | 통과. 이후 `Sources/`와 `Package.swift`는 수정하지 않아 이 바이너리가 현재 코드와 같음 |
| `swift test` | **29개 통과, 실패 0** — `ProtocolSecurityTests` 12, `SecurePairingTests` 6, `TailscaleAddressTests` 11 |
| EndToEndSmoke (실제 ntfy.sh) | `END_TO_END_PASS`. 초대 교환, 상호 승인, 암호화 릴레이 입력 메시지 왕복에 더해 **`.address` 메시지의 릴레이 왕복** 확인 |

실패한 시도 하나: 처음 `swift test`에서 `testServiceAddressesAndMalformedTextAreRejected`가 실패했다(`fd7a:115c:a1e0::1%utun3`이 거부되지 않음).
원인은 Darwin `inet_pton`이 범위 표기를 허용하는 것이었고, 입력 문자 사전 검사로 고친 뒤 29개가 전부 통과했다([03](03-implementation.md) 5장).

### 2.2 "HangulSync가 Tailscale을 실행하지 않는다"의 코드 수준 확인

같은 패턴으로 설치된 구버전과 새 release 빌드를 비교했다.

| 검사 | 구버전(`/Applications`) | 새 빌드 |
|---|:-:|:-:|
| `strings`에서 `Tailscale.app/Contents` 또는 `/bin/tailscale` 경로 문자열 | 3개 | **0개** |
| `nm -u`에서 `NSTask`·`posix_spawn`·`execv` 참조 | 1개 (`_OBJC_CLASS_$_NSTask`) | **0개** |

새 빌드에는 Tailscale 실행 파일을 가리키는 문자열도, 프로세스를 실행하는 클래스 참조도 없다.
**이것은 코드·바이너리 수준의 확인이다.** 실행 중인 Mac에서 관찰한 것이 아니다(아래 3장 시나리오 1).

### 2.3 이슈 조사 중 수행한 실험

| 실험 | 내용 | 결과 |
|---|---|---|
| A. 구버전 호환 | `git show main:...ProtocolSecurity.swift`를 컴파일해 `.address` JSON을 디코드 | `nil (dropped)`. 대조군 `.session` JSON은 정상 수락 → 구버전은 `.address`를 조용히 버림 |
| B. 수신 연결의 원격 주소 | 루프백에서 `NWListener`로 받은 연결의 `currentPath?.remoteEndpoint` 조회 | `127.0.0.1:<포트>`로 읽힘. **비-루프백 주소로 건 연결은 이 실행 환경에서 `Connection reset by peer`로 끝나 확인하지 못했고, 원인은 조사하지 않았다** |
| C. 실제 앱의 수신 대기 | 설치된 앱에 `lsof -nP -iTCP:47820 -sTCP:LISTEN` | `*:47820 (LISTEN)` — 특정 인터페이스에 묶이지 않음 |

## 3. 설계의 검증 시나리오 진행 상황

| # | 시나리오 | 상태 |
|---|---|---|
| 1 | Tailscale 종료·VPN 끊김·미설치 각각 1시간 관찰해도 HangulSync가 Tailscale 프로세스를 띄우지 않는다 | **실기 관찰 미실행.** 코드·바이너리 수준에서는 2.2로 확인 |
| 2 | 같은 네트워크에서 Bonjour 경로로 동기화 | 미실행 |
| 3 | 다른 네트워크, 양쪽 Tailscale 연결 → 알림 뒤 Tailscale 경로 | 미실행 |
| 4 | 한쪽 Tailscale 끊김 → 릴레이 전환·연결 시도 중단, 재연결 → 직접 경로 복귀 | 미실행 |
| 5 | 한쪽을 나중에 켜도 응답 알림으로 양쪽이 주소 확보 | 미실행 (릴레이 왕복 자체는 Smoke로 확인) |
| 6 | 초대 코드로 다른 네트워크 첫 페어링 → 직후 Tailscale 경로 | 미실행 |
| 7 | 구버전과 섞어 써도 오류 없이 동작 | 일부 — 구버전이 `.address`를 버리는 것만 실험 A로 확인 |
| 8 | (토글) 끄면 Tailscale 경로가 없어지고 상대도 시도 중단 | 미실행. 구버전 상대의 경우 이슈 01 |
| 9 | Tailscale 미설치 Mac에 영향 없음 | 미실행 |

## 4. 알려진 한계 (각각 별도 이슈 문서)

| 이슈 | 요약 | 종류·심각도 |
|---|---|---|
| [01 — 토글을 꺼도 Tailscale로 들어오는 연결은 받는다](../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md) | 구버전 Mac이 CLI로 찾아 접속해 오면 신버전은 스위치가 꺼져 있어도 수신 연결로 받는다. 스위치는 "내가 먼저 거는 것"만 막는다 | 설계 한계, 낮음 |
| [02 — 직접 연결은 신뢰된 Mac인지 증명하지 않는다](../issues/02-direct-connection-lacks-peer-authentication.md) | 신뢰 판정이 메시지 안의 `origin` 문자열만 본다. hello 위조도 필요 없다. 이번 변경의 `.address`가 이 약점의 영향 범위를 넓혔다 | 기존 결함 + 확대, 낮음~중간 |

**이슈 02는 처음 보고보다 범위가 넓다.** 완료 보고에서는 "hello가 서명이 아니라 공개키만 보낸다"고만 적었으나, 확인해 보니 hello가 아닌 메시지도 `origin`만 맞으면 신뢰된다.
이 판정은 변경 전 `main`(`SyncEngine.swift:300-301`)에도 있었다. 실제 공격은 재현하지 않았다.

## 5. 남은 작업

### 5.1 결정이 필요한 것

1. **이슈 02의 임시 완화(옵션 D)를 이번 브랜치에 넣을지.** `.address`를 릴레이(인증된 경로)로 온 것만 받고 `sendAddresses(onKey:)`를 제거한다. 대가는 릴레이가 막힌 환경에서 주소를 새로 배우지 못하는 것.
2. **이슈 01의 수신 연결 필터(옵션 B)를 구현할지**, 문구·README에 한계로만 남길지.
3. **업스트림(`catgarret/HangulSync`) PR 방식.** 이 저장소의 푸시 대상은 새 저장소로 바뀌었다. 업스트림에 기여하려면 tailnet 자동 찾기가 사라지는 점을 옵트인으로 남길지 따로 정해야 하고, 업스트림 PR에는 fork가 필요하다.
4. 직접 연결 상호 인증(이슈 02 옵션 A·B)의 호환 정책.

### 5.2 실행 순서 제안

1. ~~커밋~~ — 완료(위 표, 푸시 안 함). 결정 1·2를 반영하면 추가 커밋이 필요하다. 푸시는 사용자가 요청할 때만 한다.
2. 설치 전에 `/Applications/HangulSync.app`을 별도 위치로 백업한다. `install.sh`는 기존 앱을 `rm -rf` 한 뒤 복사한다.
   `build.sh`는 ad-hoc 서명이라 빌드마다 서명이 바뀌어 Keychain 접근 허용 창이 다시 뜨거나 재페어링이 필요할 수 있다. **Bundle ID는 바꾸지 않는다.**
3. 두 Mac에서 3장의 시나리오를 실행한다. 특히 1(Issue #2 핵심)과 이슈 01의 재현.
4. 업데이트 후 구버전이 남긴 Tailscale 인스턴스(PID 15592)를 한 번 직접 종료한다. HangulSync를 종료해도 남는다.
5. 구현 중 확인할 것으로 남긴 두 가지:
   - `NWPathMonitor`가 Tailscale 연결·해제 때 이벤트를 주는지(주지 않으면 30초 틱이 보완). **미확인**
   - 이 Mac의 Tailscale 인터페이스 이름·주소 구성. 당시 VPN이 끊겨 있어 **미확인** — `detect`의 `utun` 가정이 실제와 맞는지 이때 확인해야 한다.

### 5.3 미검증 항목 요약

- 두 Mac에서의 모든 실사용 시나리오(3장)
- `NWPathMonitor` 이벤트 발생 여부, 실제 Tailscale 인터페이스 구성
- 알림 지연값(시작·페어링 후 3초, 경로 이벤트 후 2초)의 적절성
- 이슈 01의 IPv4-mapped IPv6 표기, 이슈 02의 실제 위장 접속·패킷 평문 노출·방화벽 영향

## 6. 이 작업에서 만든 기록과 파일

| 위치 | 내용 |
|---|---|
| `worklog/progress/` | 이 기록 (배경·설계·구현·결과) |
| `worklog/issues/` | 알려진 한계 상세 |
| `.github/release-notes/v1.0.13.md` | 릴리스 노트 초안 |
| 임시 파일 | 실험 코드는 세션 스크래치 디렉터리에만 있고 저장소에는 넣지 않았다 |
