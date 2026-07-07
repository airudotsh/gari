# 가리 확장 지도 — 어디를 고치면 무엇이 되나 (2026-07-08, Fable 건설기 봉인판)

> 용도: Fable 이후의 유지보수자(사람이든 모델이든)를 위한 지도.
> 원칙: **코드 수술 전에 이 표에서 "설정/템플릿으로 되는 일"인지 먼저 확인하라** — 가리의 확장 지점 대부분은 코드 밖에 있다.

## 1. 코드 안 고치고 되는 것 (설정·템플릿 층)

| 하고 싶은 것 | 고치는 곳 | 방법 |
|---|---|---|
| 뇌(모델) 교체 | `config.json` | `ask_model`(접수·기억·증류·검수) / `ask_fallback_model`(위키·일반) / `deep_model`(판단 6좌석) |
| 새 API 뇌 추가 (중국모델 등) | `config.json` `executors` | `{"이름": {"type":"api","base_url":"...","key_env":"...","model":"..."}}` + 환경변수에 키. `gari doctor`로 확인 |
| 뇌 폴백 순서 | `config.json` `brain_chain` | `["claude","gjc","deepseek"]` — 접수가 이 순서로 생존 시도 |
| 가리 말투·규칙·라우팅 | `templates/ask-prompt.txt` | 접수 페르소나. 마커 계약([깊은사고] 등)은 유지할 것 |
| 사고의 깊이·방법론 | `templates/thinking-depth.md`, `thinking-lenses.txt` | 원전 교체·렌즈 추가 |
| 증류 기준 (뭘 기억할까) | `templates/distill-prompt.txt` | 카드 타입·규칙. JSON 배열 계약 유지 |
| 파견 실무자 규율 | `templates/do-prompt.txt` | 역할 경계·렌즈 점검 |
| 멘토의 눈높이 | `templates/mentor-review.txt` + 북극성 문서 | 우선순위는 북극성에서 자동 상속 |
| 지속 지시 | 채팅에 "앞으로 ~해줘" | `store/prefs.md`에 자동 축적 |
| 수집 범위 | `config.json` `collect_all`/`denylist_paths` | |
| 보고 시각·주기 | `config.json` + launchd plist | |

## 2. 코드 확장 지점 (gari.py — 함수 단위로 갈아끼우게 설계됨)

| 층 | 진입 함수 | 확장 방법 |
|---|---|---|
| 뇌 호출 | `run_brain()` → `run_claude()`/`run_api()` | 새 실행자 type은 `run_brain`의 분기 하나 추가 |
| 비상 속하네스 | `run_agent_loop()` + `AGENT_TOOLS` | 도구 추가 = AGENT_TOOLS에 스키마 + `_agent_tool_exec`에 분기. **감옥(_jail)을 우회하는 도구 금지** |
| 수집 어댑터 | `TOOL_ADAPTERS` 근방 (claude/codex/gjc 파서) | 새 CLI 수집 = 로그 위치 + 파서 함수 |
| PM 상태머신 | `project_tick()` | 상태 추가 시 그래프 판정(`_ms_ready`)과 완주 판정 둘 다 갱신 |
| 화면 문법 | `compose_stakes()` + `hud_data()` | 스테이크 재료 추가는 compose_stakes 재료 블록에 |
| 학습 루프 | `compose_reflection()`(L1) `grade_feedback()`(L2) `log_miss()`(L3) `judge_nag()`(게이트) | 새 신호 = 로그 파일 + reflection 입력에 합류 |
| 실측 | `collect_pulse()` | git 외 신호(CI·배포) 추가는 여기에 |

## 3. 불변 조항 (깨면 가리가 아님)

- **원장 append-only** — 카드 삭제 금지, 정정·해소·그림자(읽기 시점 표식)로만 덮는다.
- **fail-loud** — 실패를 폴백으로 숨기지 않는다. 폴백은 명시적 체인(brain_chain)뿐.
- **검증 없는 완료 없음** — 파견은 실물 검수를 통과해야 done.
- **자동 머지·푸시 없음** — 격리 브랜치까지만, 합류는 `gari merge`(사용자 지시).
- **역할 경계** — 가리 프롬프트는 가리 안에만. 타 CLI 자동 주입 금지 (2026-07-08 확정).
- **GARI_INTERNAL 표식** — 가리의 내부 뇌 호출에 항상 부착 (수집 재귀 방지).
- **경로 감옥** — 비상 속하네스의 도구는 작업 폴더 밖을 못 만진다.

## 4. 재건 절차 (최악의 날)

1. 이 레포 clone → `./install.sh` → `gari init` → `gari doctor`
2. 검증: `python3 tests/journey.py` (여정 배터리 18 시나리오)
3. 뇌가 없으면: config `brain_chain`에 살아있는 실행자를 넣고 `executors`에 API 키 등록 — 접수·증류·판단은 API 뇌로도 돌고, 파견 실무는 `run_agent_loop`(비상 속하네스)가 최소한을 받친다.
4. 맥락 복원: `HANDOFF.md`(수리 이력) → `docs/premortem.md`(죽음 시나리오) → 북극성 문서(방향).
