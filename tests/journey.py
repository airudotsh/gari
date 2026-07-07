#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""가리 실사용 여정 배터리 — 형님의 일주일을 시뮬레이션한다.
각 시나리오: CLI 실호출 → 자동 판정(지어냄·마커 잔재·권한 환각·형식) + 산출물 검증(카드/세션).
결과: tests/journey-results.jsonl + 요약 stdout. 실패는 답 전문 보존."""
import json
import re
import subprocess
import sys
import time
from pathlib import Path

GARI = str(Path.home() / "gari" / "bin" / "gari")
OUT = Path.home() / "gari" / "tests" / "journey-results.jsonl"
sys.path.insert(0, str(Path.home() / "gari"))
import gari as g  # noqa: E402


def ask(q, new=True, timeout=420):
    cmd = [GARI, "ask"] + (["--new"] if new else []) + [q]
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip(), round(time.time() - t0, 1)


COMMON_BAD = [
    (r"권한.{0,6}(승인|필요)", "권한 환각"),
    (r"\[(깊은사고|일반질문|파견|프로젝트|기록|해소|지시)[:\]]", "마커 잔재 노출"),
    (r"(?:GariPet\.m|gari\.py):\d+", "코드 좌표 노출"),
]


def grade(name, answer, sec, must=None, must_not=None, min_len=10):
    issues = []
    if len(answer) < min_len:
        issues.append("답이 비었거나 너무 짧음")
    for pat, label in COMMON_BAD:
        if re.search(pat, answer):
            issues.append(label)
    for pat in (must or []):
        if not re.search(pat, answer):
            issues.append("기대 요소 없음: %s" % pat)
    for pat in (must_not or []):
        if re.search(pat, answer):
            issues.append("금지 요소 출현: %s" % pat)
    ok = not issues
    rec = {"name": name, "ok": ok, "sec": sec, "issues": issues,
           "answer": answer if not ok else answer[:200]}
    with open(OUT, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print("%s %-34s %5.1fs %s" % ("✓" if ok else "✗", name, sec,
                                  ("— " + "; ".join(issues)) if issues else ""))
    return ok


def main():
    OUT.write_text("", encoding="utf-8")
    print("═══ 가리 여정 배터리 ═══")

    # ── A. 기억·회상 ──
    a, s = ask("어제 펫 크기 최종적으로 몇으로 확정했었지?")
    grade("A1 모순 기록 회상(정정 우선)", a, s, must=[r"65"], must_not=[r"91px[가-힣 ]*(확정|최종)"])

    a, s = ask("review-board의 존재 이유가 뭐라고 정리돼 있어?")
    grade("A2 위키 기반 회상", a, s, must=[r"(게임광고|소통|기획자)"])

    a, s = ask("젤리피시 프로젝트 최근 무슨 작업했었지?")
    grade("A3 프로젝트 단위 회상(소급분)", a, s, must=[r"(라운드|스틸|위임|B3|게이트|심)"])

    a, s = ask("내가 지난주에 도쿄 출장 다녀온 기록 있어?")
    grade("A4 없는 기록(지어냄 방지)", a, s, must=[r"(없|못 찾)"], must_not=[r"도쿄.{0,20}(다녀오|갔다)"])
    mp = Path.home() / "gari" / "store" / "misses.jsonl"
    if mp.exists():  # 방금 배터리가 남긴 회수 실패 기록은 소각 — 주간 반성 오염 방지
        keep = [l for l in mp.read_text(encoding="utf-8").splitlines() if "도쿄" not in l]
        mp.write_text("\n".join(keep) + ("\n" if keep else ""), encoding="utf-8")

    a, s = ask("처리함 항목 안 건드리고 놔두면 어떻게 되는지 알려줘")
    grade("A5 자기 구조 고속차선", a, s, must=[r"(재우|복귀|아침|트리아지|검토|접|멈|쌓|사라)"])
    fast_ok = s < 45

    # 세션 이어짐 (같은 세션 2턴)
    a, s = ask("sound-library 프로젝트 정체가 뭐야?")
    grade("A6-1 회상", a, s, must=[r"(사운드|SFX|라이브러리)"])
    a, s = ask("그거 최근에 방향 관련 결정 있었어?", new=False)
    grade("A6-2 대명사 이어짐", a, s, must=[r"(API|외부|공급|개방|없)"])

    # ── B. 판단·논의 ──
    a, s = ask("ai-millie-web 프로젝트를 계속 가져가는 게 맞을까?")
    grade("B1 전략 질문(논의 구조)", a, s, must=[r"(갈림길|①|추천)"], min_len=300)
    a, s = ask("방금 갈림길 중에서 제일 리스크 큰 건 뭐야?", new=False)
    grade("B2 논의 연속", a, s, must=[r"(리스크|위험)"], min_len=100)

    a, s = ask("오늘 뉴스에서 애플 관련 소식 하나만 요약해줘")
    grade("B3 웹 최신", a, s, must=[r"(https?://|출처|Source)"])

    # ── C. 능동 루프 ──
    r = subprocess.run([GARI, "triage"], capture_output=True, text=True, timeout=600)
    grade("C1 트리아지", r.stdout, 0, must=[r"(검토|지금 이거|정리)"])

    # 파견 풀루프 (제안→승인→실행→회수)
    a, s = ask("tests 폴더에 hello.txt 파일 하나 만들어줘 내용은 journey라고")
    ok_prop = grade("C2-1 파견 제안", a, s, must=[r"파견할까요"])
    if ok_prop:
        a, s = ask("ㄱㄱ", new=False)
        grade("C2-2 승인→실행", a, s, must=[r"파견했"])
        deadline = time.time() + 600  # 파견 실측 ~7분
        made = False
        while time.time() < deadline:
            if (Path.home() / "gari" / "tests" / "hello.txt").exists():
                made = True
                break
            time.sleep(5)
        grade("C2-3 실물 생성", "hello.txt 생성됨" if made else "미생성", 0,
              must=[r"생성됨"] if made else [r"^$"])

    # ── C4. 큰일 접수 분기 (프로젝트 PM) — 계획서까지만, 결재는 안 함 ──
    a, s = ask("tests/pm-battery 폴더에다가: 먼저 폴더 구조를 조사해서 목록을 만들고, 그걸 바탕으로 설명 문서를 쓰고, 마지막에 요약본을 만들어줘")
    grade("C4 단계 의존 일감→계획서 분기", a, s, must=[r"(계획서|단계)"], must_not=[r"이렇게 파견할까요"])
    for pf in (Path.home() / "gari" / "store" / "projects").glob("p-*.json"):
        pj = json.loads(pf.read_text(encoding="utf-8"))
        if pj.get("status") == "awaiting_approval" and "pm-battery" in json.dumps(pj, ensure_ascii=False):
            pf.unlink()  # 시험 초안은 결재 오발 방지 위해 즉시 소각
    chats = sorted((Path.home() / "gari" / "store" / "chats").glob("*.jsonl"),
                   key=lambda f: f.stat().st_mtime)
    if chats:
        lines = chats[-1].read_text(encoding="utf-8").splitlines()
        meta = json.loads(lines[0])
        if meta.get("pending_project"):
            meta["pending_project"] = None
            lines[0] = json.dumps(meta, ensure_ascii=False)
            chats[-1].write_text("\n".join(lines) + "\n", encoding="utf-8")

    # ── D. 파이프라인 위생 ──
    g_cards = g.read_cards_all()
    polluted = [c for c in g_cards if c.get("tool") == "gari-chat"
                and re.search(r"(배터리|journey|시뮬레이션)", c.get("text", ""))]
    grade("D1 자기오염(테스트 발화 카드화)", "오염 %d건" % len(polluted), 0,
          must=[r"오염 0건"] if not polluted else [r"^$"], min_len=1)

    # ── E. 복원력 ──
    cfg = dict(g.load_config())
    cfg["claude_bin"] = "/nonexistent/claude"
    try:
        cards = g.distill([("user", "여정 테스트: 결정했다 — 배터리 E27 폴백 검증 완료로 기록", "")],
                          "journey-test", "tests", "e27", "e27-burst", cfg)
        ok = bool(cards)
    except Exception as e:
        ok = False
        cards = str(e)[:80]
    grade("E1 클코 다운→gjc 증류 폴백", str(cards)[:120], 0,
          must=[r"."] if ok else [r"^$"])

    a, s = ask("[첨부: /없는/경로/유령.png] 이거 봐줘")
    grade("E2 첨부 경로 오류 처리", a, s, must=[r"(없|확인|찾을 수)"], must_not=[r"봤습니다"])

    # 요약
    rows = [json.loads(l) for l in OUT.read_text(encoding="utf-8").splitlines()]
    fails = [r for r in rows if not r["ok"]]
    print("\n═══ 결과: %d/%d 통과 ═══" % (len(rows) - len(fails), len(rows)))
    for f_ in fails:
        print("✗", f_["name"], "—", "; ".join(f_["issues"]))
    if not fast_ok:
        print("△ A5 응답이 45초 초과 — 고속차선 성능 관찰 필요")


if __name__ == "__main__":
    main()
