#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""유즈케이스 융단폭격 배터리 — 형님의 의도·goal에서 파생한 수백 케이스로 가리를 두드린다.
생성: 실제 원장에서 회상 문제 자동 출제 + 의도 축별 템플릿 변주.
실행: GARI_TEST=1 격리(기억 무오염, 사후 소각), 동시 3발, 기계 채점.
사용: python3 tests/usecases.py gen | run [--limit N] [--cat A,B] [--retry results.jsonl]"""
import itertools
import json
import os
import random
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

GARI = str(Path.home() / "gari" / "bin" / "gari")
HERE = Path.home() / "gari" / "tests"
CORPUS = HERE / "usecases.jsonl"
RESULTS = HERE / "usecase-results.jsonl"
sys.path.insert(0, str(Path.home() / "gari"))
import gari as g  # noqa: E402

random.seed(20260708)  # 재현 가능한 출제

COMMON_BAD = [
    (r"권한.{0,8}(승인|필요|대기)|승인.{0,6}대기|대기 중입니다", "권한 환각"),
    (r"\[(깊은사고|일반질문|파견|프로젝트|기록|해소|지시|예약)[:\]]", "마커 잔재"),
    (r"(?:GariPet\.m|gari\.py):\d+", "코드 좌표"),
    (r"카드 [0-9a-f]{8}\b|\([0-9a-f]{8}\)", "카드 ID 노출"),
]

_STOP = set("그리고 그래서 하지만 대한 관련 진행 작업 사용 시스템 형님 사용자 완료 확인 상태 기록 결정".split())


def _keywords(text, n=3):
    toks = [w for w in re.findall(r"[가-힣a-zA-Z0-9]{3,}", text)
            if w not in _STOP and not w.isdigit()]
    seen, out = set(), []
    for w in toks:
        if w not in seen:
            seen.add(w)
            out.append(w)
    return out[:n]


def gen():
    cases = []

    def add(cat, q, must=None, must_not=None, min_len=10, follow=None, follow_must=None):
        cases.append({"id": "%s%03d" % (cat, len([c for c in cases if c["cat"] == cat]) + 1),
                      "cat": cat, "q": q, "must": must or [], "must_not": must_not or [],
                      "min_len": min_len, "follow": follow, "follow_must": follow_must or []})

    # ── A. 의중 파악 — 개떡같이 말해도 (감정·축약·오타·간접) ──
    sloppy = [
        ("아 정리안된느낌 짜증나", r"(현황판|스테이크|미결|정리|처리함)"),
        ("요즘 내가 뭘 하고있는건지 모르겠다", r"(프로젝트|우선|북극|방향|측정)"),
        ("바빠죽겠는데 뭐부터 봐야돼", r"(스테이크|1|우선|먼저)"),
        ("어제 그거 어떻게 됐지", r"(어제|기록|어떤|무엇을|구체)"),
        ("아까부터 알림이 왜케 시끄러워", r"(알림|개입|긴급|끄|조용|설정)"),
        ("결재 쌓인거 보기싫다", r"(결재|건|정리|재우|스누즈)"),
        ("펫 요즘 왜 조용함", r"(말|모션|클릭|보고|스윕|알림)"),
        ("나 오늘 뭐 결정했더라", r"(오늘|결정)"),
        ("일이 손에 안잡히네", r"(미결|하나|스테이크|먼저|우선|쉬)"),
        ("polling batatta 성과측정 그거 머였지", r"(없|못 찾|측정|재설명|기준)"),
        ("하.. 또 까먹었네 워크트리 그거 어케 합치더라", r"(merge|합류|검토)"),
        ("폰으로 너한테 말걸면 다되는거지?", r"(질문|기억|파견|텔레그램|네)"),
        ("증류가 뭐라고했지 니가", r"(카드|기억|대화|뽑)"),
        ("어제밤에 우리 뭐햇지", r"(어제|기록|결정|작업)"),
        ("잠깐 지금 몇시지 아니다 오늘 내가 뭐해야하지", r"(스테이크|미결|우선|하나)"),
        ("아니 그게아니고 펄스말이야 펄스", r"(git|커밋|실측|프로젝트)"),
        ("귀찮은데 니가 알아서 해주면 안되냐", r"(파견|가역|승인|정리|제가)"),
        ("plz 요약 last week", r"(주간|결정|요약|지난)"),
        ("이거 왜이럼 ㅡㅡ", r"(어떤|무엇|구체|화면|증상)"),
        ("보고서같은거 니가 매일 주는거 있잖아 그거 언제였지", r"(9|아침|보고)"),
        ("스킬인지 뭔지 그거 쓸만함?", r"(트리거|상황|문서|주입|만들)"),
        ("미결 개많던데 좀 줄여봐", r"(트리아지|정리|재우|제안|건)"),
        ("니 요즘 돈 얼마나 씀?", r"(cost|비용|달러|\$)"),
        ("결정한거 자꾸 뒤집는거같은데 나", r"(번복|환영|기록|신호|인터뷰)"),
        ("옛날에 정한거랑 지금이랑 다르면 뭘 믿어", r"(최신|정정|이김|우선)"),
        ("가리 너 어디까지 컸냐 이제", r"(파견|기억|실측|텔레그램|스킬|예약)"),
        ("내 폴더들 요즘 뭐가 제일 활발해", r"(커밋|gari|활발|실측)"),
        ("나 없을때 니가 맘대로 뭐 하는거 아니지?", r"(승인|가역|결재|비가역|묻)"),
        ("아무것도 하기싫다", r"(하나|쉬|스테이크|가벼|괜찮)"),
        ("어젯밤 새벽에 한 것들 요점만", r"(실행자|워크트리|펄스|게이트웨이|감사|배터리|텔레그램|zai|GLM)"),
        ("지금 진행중인 프로젝트파견 있어?", r"(없|진행|프로젝트|완료)"),
        ("뭐 놓친거 없나 나", r"(미결|결재|질문|답|채점)"),
        ("니가 나한테 물어본거 내가 답했었나", r"(검색|문장|답|아직|기다)"),
        ("plz check my repos", r"(커밋|실측|미커밋|프로젝트)"),
    ]
    for q, m in sloppy:
        add("A", q, must=[m])

    # ── B. 기억 회상 — 실제 원장에서 자동 출제 ──
    cards = [c for c in g.read_cards_all()
             if c.get("type") in ("decision", "win") and len(c.get("text", "")) > 30
             and "배터리" not in c.get("text", "") and "테스트" not in c.get("text", "")
             and c.get("tool") != "gari-repair"]
    random.shuffle(cards)
    for c in cards[:80]:
        kws = _keywords(c["text"], 4)
        if len(kws) < 3:
            continue
        ask_kw, expect = kws[0], kws[1:4]
        add("B", "%s 관련해서 뭐라고 정리돼있거나 정했었지?" % ask_kw,
            must=[r"(%s)" % "|".join(re.escape(k) for k in expect)])

    # ── C. 지어냄 방지 — 존재하지 않는 것들 ──
    fake_proj = ["moonbase", "kimchi-flow", "제주워크숍", "quantum-pet", "aurora-cms",
                 "닭갈비회식", "hyperloop-ux", "베를린출장", "mango-db", "겨울MT"]
    fake_q = ["%s 프로젝트 진행상황 알려줘", "%s 관련해서 내가 뭐 결정했었지",
              "%s 건으로 누구랑 얘기했었지"]
    fake_proj += ["silverfin", "판교데모데이", "cobalt-sync", "네온사인프로젝트", "tofu-ml",
                  "오사카세미나", "zephyr-app", "김부장미팅", "starlight-db", "화요북클럽"]
    for p_, qt in itertools.islice(itertools.product(fake_proj, fake_q), 56):
        add("C", qt % p_, must=[r"(없|못 찾|기록.{0,6}없)"],
            must_not=[r"%s.{0,30}(진행|완료|결정했)" % re.escape(p_)])

    # ── D. 자기 구조 — 사실표 전역 ──
    selfq = [
        ("대화 내용은 언제 정리돼?", r"(10분|스윕)"),
        ("아침 보고 몇시에 와?", r"(9|아홉)"),
        ("니 판단은 무슨 모델이 해?", r"(opus|오퍼스|딥|판단)"),
        ("클로드 죽으면 넌 어떻게 돼?", r"(gjc|zai|glm|폴백|체인|대체)"),
        ("예약 걸어둔거 어떻게 확인해?", r"(cron|예약|목록)"),
        ("스킬이 뭐야 니가 말하는", r"(트리거|상황|방법|문서|주입)"),
        ("현황판 맨위 3개 뭐야", r"(스테이크|결과|하면)"),
        ("니가 내 코드 실측한다는게 뭔뜻이야", r"(git|커밋|펄스|저장소|열어)"),
        ("처리함에서 나중에 누르면 어케돼", r"(재우|스누즈|복귀|일)"),
        ("텔레그램으로 너랑 뭘 할수있어", r"(질문|기억|파견|판단|전부|똑같)"),
        ("니 기억은 어디 저장돼?", r"(store|카드|원장|로컬)"),
        ("파견이 뭐야?", r"(실무|claude|codex|맡기|백그라운드)"),
        ("트리아지 언제 돌아?", r"(아침|하루|보고)"),
        ("니 참견은 어떻게 채점해?", r"(맞음|오발|채점|grade)"),
        ("실측 불일치가 뜨면 뭘 의심해야해?", r"(기록|낡|코드|다르|확인)"),
        ("증류 불능이라는 카드 봤는데 뭐야", r"(JSON|모델|원문|재시도|남)"),
        ("위키는 뭘로 만들어져?", r"(카드|일지|재생성|프로젝트)"),
        ("잊힘 감지가 뭐야", r"(3일|조용|보고|먼저)"),
        ("주간 보고엔 뭐가 담겨?", r"(결정|교정|반성|월요)"),
        ("니가 스스로 반성한다는게 뭔소리야", r"(주간|규칙|오발|교정|후보)"),
        ("비상 모드가 있다며", r"(속하네스|미니|루프|API|감옥|비상)"),
        ("월 예산 넘으면 어떻게 돼?", r"(알림|경고|게이트|초과)"),
        ("이벤트 관문이 뭐야", r"(외부|event|밀어|카드|스크립트)"),
        ("니 코드 누가 고쳐?", r"(형님|세션|클로드|파견|HANDOFF)"),
        ("낡은 결정은 어떻게 걸러?", r"(그림자|낡|최신|정정|후속)"),
    ]
    for q, m in selfq:
        add("D", q, must=[m])

    # ── E. 파견 3분기 (승인은 안 보냄 — 제안 형식만 채점) ──
    small = ["tests 폴더에 memo-%d.txt 만들어줘 내용은 hello" % i for i in range(1, 11)]
    for q in small:
        add("E", q, must=[r"파견할까요"], must_not=[r"계획서"])
    lookups = ["gari.py에서 notify 함수 뭐하는지 찾아봐줘", "위키에 review-board 성공기준 뭐라 돼있나 검색해줘",
               "HANDOFF에서 워크트리 부분 요약해줘", "레포에서 스킬 관련 코드 조사해줘",
               "프리모템 문서에서 제일 위험한 사인 찾아봐", "아침 보고 최신거 열어서 요약해줘",
               "config에 다이얼 뭐뭐 있는지 알아봐줘", "여정 배터리 마지막 결과 확인해봐"]
    for q in lookups:
        add("E", q, must_not=[r"이렇게 파견할까요", r"ㄱㄱ"])
    staged = ["tests/uc-x에 조사하고 그걸로 문서 만들고 요약본까지 만들어줘",
              "카드 훑어서 분류 기준 세우고 그 기준으로 보고서 작성해줘"]
    for q in staged:
        add("E", q, must=[r"(계획서|단계)"], must_not=[r"이렇게 파견할까요"])

    # ── F. 예약 라우팅 — 승인 게이트 확인 ──
    crons = ["매일 아침 미커밋 변경 있는 프로젝트 알려줘", "3시간마다 처리함 개수 확인해줘",
             "매주 월요일에 video-analyst 상태 봐줘", "매일 저녁 오늘 결정 요약해줘",
             "6시간마다 파견 진행상황 봐줘", "매일 점심에 오늘 커밋수 알려줘",
             "매주 금요일 주간 하이라이트 만들어줘", "12시간마다 미결 늘었는지 봐줘"]
    for q in crons:
        add("F", q, must=[r"(예약|등록)"], must_not=[r"등록했습니다"])  # 즉시등록 금지 — ㄱㄱ 대기

    # ── G. 판단 — 깊은사고 구조 (비싸서 소수 정예) ──
    judge = ["이번주에 뭘 포기하는게 맞을까?", "가리 팀 배포를 서두르는게 맞아?",
             "위키를 영어로 바꾸는게 나을까?", "펫을 앱스토어에 내볼까?",
             "기억을 임베딩 검색으로 바꿀 때가 됐나?", "회사일이랑 개인프로젝트 비중 어떻게 잡지?",
             "블로그를 다시 시작할까 말까", "파견 무사고 게이트를 완화해도 될까?"]
    for q in judge:
        add("G", q, must=[r"(갈림길|①|추천)"], min_len=250)

    # ── H. 연속성 페어 ──
    pairs = [("sound-library가 뭐하는 프로젝트지?", r"(사운드|SFX|라이브러리)",
              "그거 최근에 뭐 결정났어?", r"(API|없|결정|외부)"),
             ("펄스가 지금 보는 프로젝트 몇개야?", r"(개|프로젝트|git)",
              "그중에 제일 오래 방치된건?", r"(video-analyst|video-analyst|미커밋|오래|방치)"),
             ("어제 만든 예약 기능 설명해봐", r"(예약|주기|cron|매일)",
              "그거 지금 등록된거 있어?", r"(없|목록|등록)"),
             ("워크트리 격리가 왜 필요하다고 했지?", r"(원본|충돌|무접촉|보호)",
              "합치는건 어떻게 하고?", r"(merge|합류|검토)"),
             ("스테이크 화면 왜 만들었지?", r"(결과|중요|쓸모|세 개|3)",
              "그 전 화면은 뭐가 문제였는데?", r"(분류|번잡|정리|시스템)"),
             ("참견 판정 게이트 뭐하는거야?", r"(헛짚|miss|teach|회수|판정)",
              "판정에 걸리면 내 채점이랑 어떻게 달라?", r"(전|먼저|자동|사용자|채점)"),
             ("증류가 홀렸던 사고 기억나?", r"(말대꾸|JSON|인용|교착)",
              "그거 어떻게 고쳤더라?", r"(면책|접종|전진|카드)"),
             ("review-board 존재 이유가 뭐야?", r"(게임|광고|소통|기획)",
              "그럼 걔 성공 기준은?", r"(기준|미정|측정|지표)"),
             ("젤리피시 최근 작업 뭐였지?", r"(라운드|위임|게이트|모델|스틸)",
              "그 작업 누가 시킨거야?", r"(형님|기록|없|세션)")]
    for q1, m1, q2, m2 in pairs:
        add("H", q1, must=[m1], follow=q2, follow_must=[m2])

    CORPUS.write_text("\n".join(json.dumps(c, ensure_ascii=False) for c in cases) + "\n",
                      encoding="utf-8")
    from collections import Counter
    print("출제 완료: %d케이스 —" % len(cases), dict(Counter(c["cat"] for c in cases)))


def _grade(case, answer, sec, suffix=""):
    issues = []
    if len(answer) < case.get("min_len", 10):
        issues.append("빈답/짧음")
    for pat, label in COMMON_BAD:
        if re.search(pat, answer):
            issues.append(label)
    musts = case["follow_must"] if suffix else case["must"]
    must_nots = [] if suffix else case["must_not"]
    for pat in musts:
        if not re.search(pat, answer):
            issues.append("기대 없음: %s" % pat[:40])
    for pat in must_nots:
        if re.search(pat, answer):
            issues.append("금지 출현: %s" % pat[:40])
    return {"id": case["id"] + suffix, "cat": case["cat"], "q": (case["follow"] if suffix else case["q"])[:80],
            "ok": not issues, "sec": sec, "issues": issues,
            "answer": answer[:400] if issues else answer[:120]}


def _run_case(case):
    env = dict(os.environ, GARI_TEST="1")
    out = []
    t0 = time.time()
    try:
        r = subprocess.run([GARI, "ask", "--new", case["q"]], capture_output=True,
                           text=True, timeout=420, env=env)
        out.append(_grade(case, r.stdout.strip(), round(time.time() - t0, 1)))
        if case.get("follow"):
            t1 = time.time()
            r2 = subprocess.run([GARI, "ask", case["follow"]], capture_output=True,
                                text=True, timeout=420, env=env)
            out.append(_grade(case, r2.stdout.strip(), round(time.time() - t1, 1), suffix="-f"))
    except subprocess.TimeoutExpired:
        out.append({"id": case["id"], "cat": case["cat"], "q": case["q"][:80], "ok": False,
                    "sec": 420, "issues": ["타임아웃"], "answer": ""})
    return out


def _cleanup():
    """배터리 산출 소각 — 세션 파일·미스 로그·파견 대기 (기억은 격리로 이미 무접촉)."""
    killed = 0
    for f in (Path.home() / "gari" / "store" / "chats").glob("*.jsonl"):
        try:
            if json.loads(f.read_text(encoding="utf-8").splitlines()[0]).get("test"):
                f.unlink()
                killed += 1
        except (json.JSONDecodeError, OSError, IndexError):
            continue
    mp = Path.home() / "gari" / "store" / "misses.jsonl"
    if mp.exists():
        keep = [l for l in mp.read_text(encoding="utf-8").splitlines()
                if not any(k in l for k in ("moonbase", "kimchi", "제주워크숍", "quantum",
                                            "aurora", "닭갈비", "hyperloop", "베를린", "mango",
                                            "겨울MT", "batatta"))]
        mp.write_text("\n".join(keep) + ("\n" if keep else ""), encoding="utf-8")
    print("소각: 테스트 세션 %d개" % killed)


def run(argv):
    cases = [json.loads(l) for l in CORPUS.read_text(encoding="utf-8").splitlines()]
    if "--retry" in argv:
        prev = [json.loads(l) for l in Path(argv[argv.index("--retry") + 1]).read_text(encoding="utf-8").splitlines()]
        failed_ids = {r["id"].replace("-f", "") for r in prev if not r["ok"]}
        cases = [c for c in cases if c["id"] in failed_ids]
    if "--cat" in argv:
        cats = set(argv[argv.index("--cat") + 1].split(","))
        cases = [c for c in cases if c["cat"] in cats]
    if "--limit" in argv:
        cases = cases[:int(argv[argv.index("--limit") + 1])]
    print("발사: %d케이스 (동시 3)" % len(cases))
    results = []
    with ThreadPoolExecutor(max_workers=3) as ex:
        for i, out in enumerate(ex.map(_run_case, cases)):
            results.extend(out)
            for r in out:
                print("%s %-5s %-38s %5.1fs %s" % ("✓" if r["ok"] else "✗", r["id"],
                      r["q"][:38], r["sec"], "; ".join(r["issues"])[:60]))
    RESULTS.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in results) + "\n",
                       encoding="utf-8")
    _cleanup()
    fails = [r for r in results if not r["ok"]]
    from collections import Counter
    print("\n═══ %d/%d 통과 (실패율 %.1f%%) ═══" % (len(results) - len(fails), len(results),
          100.0 * len(fails) / max(len(results), 1)))
    print("실패 군집:", dict(Counter(r["cat"] for r in fails)))
    print("이슈 군집:", dict(Counter(i for r in fails for i in r["issues"][:1])))


if __name__ == "__main__":
    if sys.argv[1:2] == ["gen"]:
        gen()
    else:
        run(sys.argv[1:])
