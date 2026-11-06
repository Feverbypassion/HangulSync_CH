# 작업 기록 — HangulSync 자동 탐지(Tailscale) 개선

2026-11-06. Issue #2("Tailscale CLI polling relaunches GUI")에서 출발해 **HangulSync가 Tailscale을 실행하지 않도록**
자동 탐지를 다시 설계하고 구현했다.

## 한 문단 요약

HangulSync는 30초마다 `Tailscale status --json`을 환경변수 없이 실행해 왔고, 이 때문에 Tailscale GUI가 종료되지 않는 인스턴스로 떠 있었다.
사용자가 Tailscale을 끄면 다음 틱에 다시 뜨는 것이 Issue #2의 증상이다. 설계를 세 번 고쳐 최종적으로
**Tailscale 실행 파일 호출을 전부 없애고**, 내 Mac의 네트워크 인터페이스에서 Tailscale 주소를 읽어 페어링된 Mac끼리 암호화 채널로 주소를 교환하는 방식(v3)으로 정했다.
`feature/tailscale-passive-path` 브랜치에 구현해 단위 테스트 29개와 종단간 점검을 통과했고 PR #1로 올렸다.
새 빌드를 설치해 구버전 원격 Mac과 **같은 네트워크에서** 한/영 동기화가 작동하는 것까지 확인했다.
다른 네트워크(Tailscale) 경로와 주소 교환은 아직 검증하지 못했다.
설치 중에는 Keychain 허용 창 하나가 승인되지 않아 신원 키가 새로 만들어지는 문제가 실제로 발생했고, 재페어링으로 복구했다.

## 문서

| 문서 | 내용 |
|---|---|
| [01-background-and-analysis.md](01-background-and-analysis.md) | 요청, Notion 문서 이해, Issue #2, 근본 원인 실측, Tailscale·Bonjour와의 관계 조사 |
| [02-design.md](02-design.md) | 설계 v1 → v2 → v3 변천, 최종 설계, 폐기한 안, 결정 기록 |
| [03-implementation.md](03-implementation.md) | 브랜치, 파일별 변경, 설계와 달라진 점, 구현 중 발견한 문제 |
| [04-results.md](04-results.md) | 검증 결과, 시나리오 진행, 알려진 한계, 남은 작업 |
| [05-installation-and-field-test.md](05-installation-and-field-test.md) | 새 빌드 설치, 동기화가 멈춘 사건의 타임라인과 조사, 복구, 동기화 관찰 |
| [../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md](../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md) | 한계 1 — 스위치를 꺼도 구버전이 접속해 오면 수신 연결을 받음 |
| [../issues/02-direct-connection-lacks-peer-authentication.md](../issues/02-direct-connection-lacks-peer-authentication.md) | 한계 2 — 직접 연결에서 신뢰된 Mac인지 증명하지 않음 |
| [../issues/03-keychain-identity-reset-on-reinstall.md](../issues/03-keychain-identity-reset-on-reinstall.md) | 문제 3 — 재설치 때 Keychain 읽기에 실패하면 신원 키가 조용히 새로 만들어짐(실제 발생) |
| [../issues/04-pairing-error-dialog-on-ntfy-429.md](../issues/04-pairing-error-dialog-on-ntfy-429.md) | 문제 4 — 초대 코드 페어링 중 429 오류 창이 먼저 뜸 |

## 진행 순서

1. 요청 접수: Notion 내용을 이해했는지 설명하고 설계한다. 구현은 아직 하지 않는다.
2. Notion 문서를 내장 브라우저로 끝까지 읽고 코드와 대조 → 근본 원인을 이 Mac에서 직접 확인 → **설계 v1** (Tailscale 3모드 + CLI 버그 수정).
3. 사용자 피드백(검증 먼저, 임의 실행 금지, 실행 팝업, 미설치 시 정지) → **설계 v2**.
4. 사용자 질문(CLI는 Tailscale 자체인가, Tailscale은 필수인가, Bonjour는 항상 실행되는가) → 조사 → "완전한 독립" 요구 확정 → **설계 v3**(CLI 제거 + 주소 교환).
5. 구현 지시: `main`에서 새 브랜치를 만들어 체크아웃한 뒤 구현 → Phase 1~4 구현, 빌드·테스트·종단간 점검 통과.
6. 알려진 한계 2건을 코드·실험으로 확인해 이슈 문서로 기록. 이 과정에서 한계 2가 처음 보고보다 넓다는 것을 확인(정정).
7. 저장소 주소를 `Feverbypassion/HangulSync_CH`로 변경하는 것이 작업 트리에 반영되어, 이를 별도 커밋으로 분리하고 기능 변경과 기록을 각각 커밋. 작성자를 사용자가 지정한 값으로 수정.
8. 브랜치를 푸시하고 PR #1을 만듦. CI(`macos-14` 러너 미지원)는 시작되지 못해 로컬 클린 빌드로 대체 확인.
9. 새 빌드를 빌드·설치. 설치 직후 동기화가 멈춤 → 조사 → Keychain 신원 초기화가 원인(이슈 03) → 재실행·"항상 허용"·재페어링으로 복구 → 동기화 작동 확인.
10. 재페어링 중 본 429 오류 창을 조사(이슈 04). 현장 시험 결과와 이슈 03·04를 기록하고 커밋.

## 현재 상태

| 항목 | 내용 |
|---|---|
| 브랜치 | `feature/tailscale-passive-path` (베이스 `main` `f2d471a`) |
| 푸시·PR | 앞의 3개 커밋은 푸시했고 [PR #1](https://github.com/Feverbypassion/HangulSync_CH/pull/1)이 열려 있다. 현장 시험 기록 커밋은 아직 푸시하지 않았다 |
| 원격 저장소 | `origin` = `Feverbypassion/HangulSync_CH` (업스트림은 `catgarret/HangulSync`) |
| 자동 검증 | `swift test` 29/29, 로컬 클린 빌드·`build.sh`·EndToEndSmoke 통과. GitHub Actions는 러너 미지원으로 취소됨 |
| 실사용 검증 | 새 빌드 + 구버전 원격, 같은 네트워크에서 동기화 확인. 다른 네트워크·Tailscale 경로는 미실행 |
| 설치 | 이 Mac은 새 빌드로 교체됨. 원격 Mac은 구버전 |
| 열린 결정 | 이슈 02 임시 완화, 이슈 01 필터, 이슈 03 수정 범위, 업스트림 PR 방식, 호환 정책, CI 러너 ([04](04-results.md) 5.1) |

## 참고 링크

- 업스트림(원본) https://github.com/catgarret/HangulSync
- 이 저장소의 현재 `origin` https://github.com/Feverbypassion/HangulSync_CH
- Issue #2 https://github.com/catgarret/HangulSync/issues/2
- Notion 정리 문서 https://app.notion.com/p/40faf60ad5cf807883d8ecda23f97168
- ntfy 요청 제한 문서 https://docs.ntfy.sh/config/#rate-limiting
