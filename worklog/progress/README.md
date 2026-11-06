# 작업 기록 — HangulSync 자동 탐지(Tailscale) 개선

2026-11-06. Issue #2("Tailscale CLI polling relaunches GUI")에서 출발해 **HangulSync가 Tailscale을 실행하지 않도록**
자동 탐지를 다시 설계하고 구현했다.

## 한 문단 요약

HangulSync는 30초마다 `Tailscale status --json`을 환경변수 없이 실행해 왔고, 이 때문에 Tailscale GUI가 종료되지 않는 인스턴스로 떠 있었다.
사용자가 Tailscale을 끄면 다음 틱에 다시 뜨는 것이 Issue #2의 증상이다. 설계를 세 번 고쳐 최종적으로
**Tailscale 실행 파일 호출을 전부 없애고**, 내 Mac의 네트워크 인터페이스에서 Tailscale 주소를 읽어 페어링된 Mac끼리 암호화 채널로 주소를 교환하는 방식(v3)으로 정했다.
`feature/tailscale-passive-path` 브랜치에 구현했고 단위 테스트 29개와 종단간 점검이 통과했다.
커밋은 했지만(푸시하지 않음) 두 Mac에서의 실사용 검증은 아직 하지 않았다.

## 문서

| 문서 | 내용 |
|---|---|
| [01-background-and-analysis.md](01-background-and-analysis.md) | 요청, Notion 문서 이해, Issue #2, 근본 원인 실측, Tailscale·Bonjour와의 관계 조사 |
| [02-design.md](02-design.md) | 설계 v1 → v2 → v3 변천, 최종 설계, 폐기한 안, 결정 기록 |
| [03-implementation.md](03-implementation.md) | 브랜치, 파일별 변경, 설계와 달라진 점, 구현 중 발견한 문제 |
| [04-results.md](04-results.md) | 검증 결과, 미검증 항목, 알려진 한계, 남은 작업 |
| [../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md](../issues/01-toggle-off-still-accepts-incoming-tailscale-connections.md) | 한계 1 — 스위치를 꺼도 구버전이 접속해 오면 수신 연결을 받음 |
| [../issues/02-direct-connection-lacks-peer-authentication.md](../issues/02-direct-connection-lacks-peer-authentication.md) | 한계 2 — 직접 연결에서 신뢰된 Mac인지 증명하지 않음 |

## 진행 순서

1. 요청 접수: Notion 내용을 이해했는지 설명하고 설계한다. 구현은 아직 하지 않는다.
2. Notion 문서를 내장 브라우저로 끝까지 읽고 코드와 대조 → 근본 원인을 이 Mac에서 직접 확인 → **설계 v1** (Tailscale 3모드 + CLI 버그 수정).
3. 사용자 피드백(검증 먼저, 임의 실행 금지, 실행 팝업, 미설치 시 정지) → **설계 v2**.
4. 사용자 질문(CLI는 Tailscale 자체인가, Tailscale은 필수인가, Bonjour는 항상 실행되는가) → 조사 → "완전한 독립" 요구 확정 → **설계 v3**(CLI 제거 + 주소 교환).
5. 구현 지시: `main`에서 새 브랜치를 만들어 체크아웃한 뒤 구현 → Phase 1~4 구현, 빌드·테스트·종단간 점검 통과.
6. 알려진 한계 2건을 코드·실험으로 확인해 이슈 문서로 기록. 이 과정에서 한계 2가 처음 보고보다 넓다는 것을 확인(정정).
7. 저장소 주소를 `Feverbypassion/HangulSync_CH`로 변경하는 것이 작업 트리에 반영되어, 이를 별도 커밋으로 분리하고 기능 변경과 기록을 각각 커밋(푸시하지 않음).

## 현재 상태

| 항목 | 내용 |
|---|---|
| 브랜치 | `feature/tailscale-passive-path` (베이스 `main` `f2d471a`) |
| 커밋 | 3개, 푸시하지 않음 — `8d61a0b` 저장소 주소 변경, `65758f1` Tailscale 개편, 작업 기록 ([04](04-results.md) 1장) |
| 원격 저장소 | `origin` = `Feverbypassion/HangulSync_CH` (업스트림은 `catgarret/HangulSync`) |
| 자동 검증 | `swift test` 29/29, EndToEndSmoke 통과, 새 빌드에 Tailscale 실행 흔적 없음 |
| 실사용 검증 | 미실행 |
| 열린 결정 | 이슈 02 임시 완화 여부, 이슈 01 필터 구현 여부, 업스트림 PR 방식, 호환 정책 ([04](04-results.md) 5.1) |

## 참고 링크

- 업스트림(원본) https://github.com/catgarret/HangulSync
- 이 저장소의 현재 `origin` https://github.com/Feverbypassion/HangulSync_CH
- Issue #2 https://github.com/catgarret/HangulSync/issues/2
- Notion 정리 문서 https://app.notion.com/p/40faf60ad5cf807883d8ecda23f97168
