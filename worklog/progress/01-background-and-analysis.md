# 01. 배경과 분석

작성일 2026-11-06. 설계에 들어가기 전에 확인한 내용을 정리한다.

## 1. 작업 요청

- 대상 저장소는 두 Mac을 화면 공유로 연결했을 때 한/영 입력 상태를 동기화하는 메뉴바 앱 HangulSync이다.
  원본(업스트림)은 `https://github.com/catgarret/HangulSync`이고, 작업을 시작할 때는 로컬 `origin`도 원본이었으며 fork는 없었다.
  이후 사용자가 이 저장소의 GitHub 주소를 `https://github.com/Feverbypassion/HangulSync_CH`로 바꾸도록 지시해 `origin`이 새 저장소로 바뀌었다
  (README·앱 내 링크·업데이트 확인 주소·`deploy.sh`도 함께 변경, 별도 커밋). 업스트림은 계속 `catgarret/HangulSync`다.
- 요청 내용은 **"자동 탐지" 기능 개선**이다. 정리 문서는 Notion 공개 페이지(`40faf60ad5cf807883d8ecda23f97168`)에 있다.
- 처음 지시는 "Notion 내용을 이해했는지 먼저 설명하고, 코드를 확인해 설계한다. 구현은 아직 하지 않는다"였다.
- 작업 시작 시점의 저장소는 `main`, 최신 커밋 `f2d471a 자동 페어링 안내와 재연결 안정성 개선`, 작업 트리는 깨끗했다.

## 2. Notion 문서에서 이해한 내용

Notion 페이지는 가상 스크롤이라 `get_page_text`가 일부만 돌려주었다(WebFetch는 JS 렌더링 때문에 본문을 못 가져왔다).
내장 브라우저로 스크롤하며 끝까지 읽었다.

| 절 | 내용 |
|---|---|
| 결론 | 자동 탐지는 필수 기능이 아니다. 최초 수동 페어링 후 저장된 정보를 재사용할 수 있고, MIT 라이선스라 수정·빌드해도 된다 |
| §1 | 자동 탐지(상대 Mac 찾기)와 입력 상태 동기화는 별개 기능이다. 새 수동 페어링 시스템은 필요 없고 **Tailscale 탐색만 선택적으로 끄는 것**이 합리적이다 |
| §2 | `startTimer()`가 30초마다 `pollTailscale()`을 실행한다. `beginPairingMode()`도 `runTailscaleDiscovery()`를 호출하므로 타이머만 제거해서는 부족하다. `connectSavedTailscalePeers()`는 CLI 없이 저장된 IP로 접속하므로 별도 설계가 필요하다 |
| §3 | 설정 제안은 Bonjour ON/OFF, Tailscale `Disabled`/`Manual Only`/`Automatic`, Encrypted Relay ON/OFF (현재 존재하지 않는 UI). 추천 조합은 Bonjour ON, Manual, Relay ON |
| §4 | 수정·재배포는 허용되나 저작권 고지는 삭제할 수 없다. `install.sh`는 기존 앱을 삭제하므로 백업이 필요하고 Bundle ID는 유지해야 하며, 서명이 바뀌면 Keychain 재요청이나 재페어링이 생길 수 있다 |
| §5 | 변경 대상은 `SyncEngine`, `main`, `Localization`, `Tests`. 1단계는 `TAILSCALE_BE_CLI=1` 버그 수정, 2단계는 모드 추가 |
| 맺음 | 자동 탐지를 꺼도 연결이 항상 복구되지는 않는다. IP가 바뀌거나 네트워크를 옮기면 수동 재탐색이 필요하고, 암호화 릴레이와는 구분해야 한다. 테스트 후 Issue #2와 연결해 PR을 낼 수 있다 |

## 3. Issue #2

- 제목 "[Bug / Feature Request] Tailscale CLI polling relaunches GUI — option to disable peer discovery"
- 2026-11-06 등록, Open, Tailscale Standalone 1.104.5. 등록자는 이 작업을 요청한 사용자 본인으로 보이는 계정이다.
- 증상: Tailscale을 종료해도 HangulSync가 다시 띄운다.
- 제안: `TAILSCALE_BE_CLI=1` 설정, 타임아웃, "Enable Tailscale Peer Discovery" 설정 추가.

## 4. 코드 대조 결과

### 4.1 Notion 주장은 모두 코드와 일치 (`main` 기준)

| 주장 | 확인 위치 |
|---|---|
| 30초 타이머가 `pollTailscale()` 호출 | `SyncEngine.swift:617`, `:632` |
| `beginPairingMode()`가 `runTailscaleDiscovery(includeOfflineMacs: true)` 호출 — **초대 코드 만들기·입력도 이 함수를 거치므로 수동 방식에서도 CLI가 실행됨** | `:371` |
| `connectSavedTailscalePeers()`는 CLI 없이 시작 시 1회만 호출 | `:186`, `:679` |

### 4.2 Notion에 없던 발견

1. **근본 원인을 이 Mac에서 직접 확인했다.**
   - `runTailscaleStatus()`는 환경변수 없이 `Tailscale.app/Contents/MacOS/Tailscale status --json`을 실행한다(`:702`).
   - 이 바이너리는 `TERM`, `SHLVL` 같은 터미널 환경변수로 GUI/CLI 모드를 판단한다. GUI 앱의 하위 프로세스에는 이 변수가 없어 **GUI 앱이 한 번 더 뜬다.**
   - 실제로 PID 15592가 HangulSync(PID 15591)의 자식으로 떠 있고, 이름만 `status --json`이다. 한 시간 넘게 살아 있었다.
   - 타임아웃이 없어서 `readDataToEndOfFile()`이 반환되지 않는다. 그래서 탐색 결과도 얻지 못한다.
   - 사용자가 Quit하면 프로세스가 끝나 읽기가 풀리고, 다음 30초 틱에서 GUI가 다시 뜬다 → Issue #2 증상과 정확히 일치.
   - `/usr/local/bin/tailscale`은 같은 바이너리를 부르는 `sh` 래퍼라 후보 경로 순서를 바꿔도 해결되지 않는다.
2. 이전 호출이 끝나지 않아도 다음 틱이 또 호출한다(중복 실행 방지 없음).
3. 주석은 "20초"(`:611`)지만 실제 타이머는 30초다.
4. 온라인인 모든 tailnet 기기(iPhone, Linux 등)에 47820 포트 접속을 시도하며 OS 필터가 없다(범위 밖으로 기록).
5. `startTimer()`는 Bonjour 재연결·세션 유지·만료 정리도 하므로 **타이머를 지우면 안 되고** Tailscale 호출만 제거해야 한다.

## 5. Tailscale과 HangulSync의 관계 (사용자 질문 1·2에 대한 조사)

### 5.1 Tailscale CLI는 GUI와 독립적인가?

이 Mac의 Tailscale은 세 부분이다(읽기 전용 명령으로 확인).

| 구성 요소 | 하는 일 | 누가 실행하나 | 이 Mac의 상태 |
|---|---|---|---|
| GUI 앱 `Tailscale.app` | 메뉴바 화면 | 사용자 또는 로그인 항목 | HangulSync가 띄운 인스턴스 하나만 있음 (PID 15592, 12:07 시작) |
| 시스템 확장 (백엔드) | 실제 VPN 터널·tailnet 연결, root 권한 | macOS | PID 13693, 11:34 시작, VPN은 `Disconnected` |
| CLI | 백엔드에 상태를 묻거나 명령을 보냄 | 호출하는 쪽 | 별도 프로그램이 아님 |

- 백엔드는 GUI와 별개의 프로세스다. 확장은 11:34에 이미 떠 있었고 GUI 인스턴스는 33분 뒤 HangulSync가 띄웠다.
- **CLI는 GUI와 같은 실행 파일**이다. 환경변수를 보고 GUI로 뜰지 CLI로 동작할지 정한다. 판정이 맞으면 백엔드에 묻는 짧은 클라이언트, 어긋나면 GUI가 그대로 뜬다.
- CLI 호출이 백엔드나 VPN을 깨울 수 있는지는 문서에 없어 확인하지 못했다.
- **결론:** HangulSync가 CLI를 부르는 것은 곧 Tailscale의 실행 파일을 실행하는 것이다. "완전히 독립"이 목표라면 조건부로 막을 것이 아니라 **호출 자체를 없애야 한다.**

### 5.2 Tailscale은 HangulSync의 필수 조건인가? → 아니오

| 경로 | 방식 | Tailscale 필요 |
|---|---|:-:|
| ① Bonjour 직접 연결 | 같은 네트워크에서 서로를 찾아 TCP 연결 | 아니오 |
| ② Tailscale IP 직접 연결 | CLI로 찾은 IP 또는 저장된 IP로 TCP 연결 | **예** |
| ③ 수신 연결 | 모든 인터페이스에서 상대의 연결을 받음 | 아니오 |
| ④ 암호화 릴레이 | ntfy.sh를 거쳐 종단간 암호화 | 아니오 |

근거:
- 동기화 동작 조건 `syncAllowed`는 일시정지 여부와 원격 데스크탑 앱 실행 여부만 본다(`SyncEngine.swift:98`).
- `push()`는 직접 경로로 보내고 직접 경로가 없는 페어링된 Mac에는 릴레이로 보낸다(`:272`).
- 직접 경로가 없어도 페어링된 Mac은 "암호화 릴레이"로 연결된 것으로 표시된다(`:7`).
- 다른 네트워크 간 첫 페어링의 초대 코드는 ntfy 기반이라 Tailscale을 쓰지 않는다(`PairingRendezvous.swift`).
- CLI 경로를 못 찾으면 그냥 아무것도 하지 않고 나머지 기능은 정상이다(`:708`).

Tailscale의 실제 역할은 **두 Mac이 다른 네트워크에 있을 때 릴레이 대신 직접 경로를 제공하는 것** 하나뿐이다
(지연이 짧고 ntfy.sh에 의존하지 않는다). 이 Mac은 VPN이 끊겨 있어 탐색이 성공해도 쓸 경로가 없었으므로 부작용만 남아 있었다.

## 6. Bonjour 조사 (사용자 질문 3)

- Bonjour는 macOS 시스템 데몬 `mDNSResponder`(이 Mac에서 PID 507, 부팅 때 시작)가 담당한다. DNS 조회 전체도 처리하므로 항상 떠 있고 끌 수 없다.
- HangulSync는 Bonjour를 실행·재시작하지 않는다. OS에 서비스(`_hangulsync._tcp`)를 등록·검색할 뿐이다(`SyncEngine.swift:569`, `:585`). Tailscale 같은 독립성 문제가 없다.
- 멀티캐스트는 같은 네트워크 안에서만 전달되므로 다른 네트워크에서는 쓸모가 없다.
- 비용은 작지만 0은 아니다: 작은 멀티캐스트 패킷, 첫 실행 시 로컬 네트워크 권한 요청, `includePeerToPeer`로 켜는 AWDL(`:558`, `:587`).
  AWDL이 Wi-Fi 지연을 튀게 하는 사례가 알려져 있으나 HangulSync에서 직접 측정하지는 않았다.
- **결정:** Bonjour 유지. 같은 네트워크에서 가장 빠르고 인터넷 없이 동작하는 유일한 경로이며 같은 네트워크의 "자동으로 찾기"도 Bonjour를 쓴다.

## 7. 참고한 외부 자료

- Tailscale CLI 문서 — https://tailscale.com/kb/1080/cli?tab=macos
- macOS에서 Tailscale을 실행하는 세 가지 방법 — https://tailscale.com/kb/1065/macos-app/
- Issue #2 — https://github.com/catgarret/HangulSync/issues/2
