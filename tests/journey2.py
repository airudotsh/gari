#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""배터리 2부: 1부 실패 재시험(A1·A3) + 미실행(C2·D·E)"""
import sys
sys.path.insert(0, "~/gari/tests")
sys.path.insert(0, str(__import__("pathlib").Path.home() / "gari"))
import journey as J
import subprocess, time, json, re
from pathlib import Path
import gari as g

J.OUT.write_text("", encoding="utf-8")
print("═══ 배터리 2부 ═══")

a, s = J.ask("어제 펫 크기 최종적으로 몇으로 확정했었지?")
J.grade("A1 모순 기록 회상(재시험)", a, s, must=[r"65"], must_not=[r"91px[가-힣 ]*(확정|최종)"])

a, s = J.ask("젤리피시 프로젝트 최근 무슨 작업했었지?")
J.grade("A3 프로젝트 회상(재시험)", a, s, must=[r"(라운드|스틸|위임|B3|게이트|턴|오케)"])

# C2 파견 풀루프
a, s = J.ask("tests 폴더에 hello.txt 파일 하나 만들어줘 내용은 journey라고")
ok = J.grade("C2-1 파견 제안", a, s, must=[r"파견할까요"])
if ok:
    a, s = J.ask("ㄱㄱ", new=False)
    J.grade("C2-2 승인→실행", a, s, must=[r"파견했"])
    deadline = time.time() + 300
    made = False
    while time.time() < deadline:
        f = Path.home() / "gari" / "tests" / "hello.txt"
        if f.exists() and "journey" in f.read_text(encoding="utf-8", errors="ignore"):
            made = True
            break
        time.sleep(6)
    J.grade("C2-3 실물 생성+내용", "OK" if made else "미생성", 0,
            must=[r"OK"] if made else [r"^$"])

# E1 클코 다운 → gjc 폴백
cfg = dict(g.load_config())
cfg["claude_bin"] = "/nonexistent/claude"
try:
    cards = g.distill([("user", "여정2: E1 폴백 검증용 결정 — gjc 경유 증류 확인", "")],
                      "journey-test", "tests", "e1", "e1-burst", cfg)
    ok = bool(cards)
except Exception as e:
    ok, cards = False, str(e)[:100]
J.grade("E1 gjc 증류 폴백", str(cards)[:140], 0, must=[r"."] if ok else [r"^$"])

a, s = J.ask("[첨부: /없는/경로/유령.png] 이거 봐줘")
J.grade("E2 첨부 오류 처리", a, s, must=[r"(없|확인|찾을 수|경로)"], must_not=[r"봤습니다"])

rows = [json.loads(l) for l in J.OUT.read_text(encoding="utf-8").splitlines()]
fails = [r for r in rows if not r["ok"]]
print("\n═══ 2부: %d/%d 통과 ═══" % (len(rows) - len(fails), len(rows)))
for f_ in fails:
    print("✗", f_["name"], "—", "; ".join(f_["issues"]))
