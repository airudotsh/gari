#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""가리 v1 — 전 도구 대화 적재·증류·아침 결재 에이전트.

구조 (데몬 없음):
  훅(Claude/Codex Stop) → `gari enqueue`  : 큐에 세션 경로만 기록 (비차단)
  launchd 10분 주기     → `gari sweep`    : 새 턴 수집 → 묶음 판정 → 증류(haiku) → 카드
  launchd 매일 09:00    → `gari report --morning` : 아침 보고 + 알림
  Claude SessionStart 훅 → `gari brief`   : 브리핑 주입 (stdout)

설계 계약: fail-loud (조용한 스킵 금지 — 실패는 세고, 알리고, 보고에 남긴다),
원본 무복사 (커서만 전진), 모든 동작 기준은 config.json에 노출.
스펙: ~/roadmap/gari-spec.md
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

GARI_HOME = Path(os.environ.get("GARI_HOME", str(Path.home() / "gari")))
CONFIG_PATH = GARI_HOME / "config.json"
STORE = GARI_HOME / "store"
CARDS_DIR = STORE / "cards"
CURSORS_PATH = STORE / "cursors.json"
BRIEFING_PATH = STORE / "briefing.md"
HEALTH_PATH = STORE / "health.json"
QUEUE_DIR = GARI_HOME / "queue"
REPORTS_DIR = GARI_HOME / "reports"
TEMPLATES = GARI_HOME / "templates"
DISTILL_MARKER = "[GARI-DISTILL]"  # 증류용 하위 호출 표식 — 자기 대화 재수집(무한루프) 방지


# ---------------------------------------------------------------- 공용

def personalize(text, cfg):
    """호칭·이름 치환 — 모든 프롬프트·보고의 단일 관문 (기본값이면 무변화)."""
    return (text.replace("형님", cfg.get("honorific", "형님"))
                .replace("아이루", cfg.get("user_name", "아이루")))


def load_config():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        cfg = json.load(f)
    # claude 경로 자동 해결 — 설정 경로가 죽었으면 PATH에서 찾는다 (기기 이식성)
    if not Path(cfg.get("claude_bin", "")).exists():
        found = shutil.which("claude")
        if found:
            cfg["claude_bin"] = found
    return cfg


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path, data):
    tmp = Path(str(path) + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def notify(title, message, cfg=None):
    """macOS 알림. cfg.notify=false면 stdout으로만."""
    if cfg is not None and not cfg.get("notify", True):
        print("[알림 생략] %s: %s" % (title, message))
        return
    sound = (cfg or {}).get("notify_sound", "")
    script = 'display notification "{}" with title "{}"{}'.format(
        message.replace('"', "'"), title.replace('"', "'"),
        ' sound name "%s"' % sound if sound else "")
    try:
        subprocess.run(["osascript", "-e", script], check=True,
                       capture_output=True, timeout=10)
    except Exception as e:  # 알림 실패는 치명적이지 않지만 숨기지 않는다
        print("[알림 실패] %s" % e, file=sys.stderr)


def health_update(**kv):
    h = load_json(HEALTH_PATH, {})
    h.update(kv)
    save_json(HEALTH_PATH, h)
    return h


def health_incr(key):
    h = load_json(HEALTH_PATH, {})
    h[key] = h.get(key, 0) + 1
    save_json(HEALTH_PATH, h)
    return h[key]


def append_cards(cards):
    if not cards:
        return
    day_file = CARDS_DIR / (datetime.now().strftime("%Y-%m-%d") + ".jsonl")
    with open(day_file, "a", encoding="utf-8") as f:
        for c in cards:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")


PROJECT_ALIASES = {"review-board": "review-board", "review-board": "review-board",
                   "review-board": "review-board", "sound-library": "sound-library",
                   "sound-library": "sound-library", "젤리피시": "jellyfish",
                   "뇌클론": "brain-clone", "브레인클론": "brain-clone",
                   "video-analyst": "video-analyst", "video-analyst": "video-analyst"}


def canonical_project(name):
    if not name:
        return name
    return PROJECT_ALIASES.get(str(name).strip().lower(), PROJECT_ALIASES.get(str(name).strip(), name))


def read_cards_all():
    """카드 원장 전체 (자정 넘김에 안전 — '전체' 의도는 반드시 이걸 쓸 것)."""
    return read_cards(3650)


def read_cards(days_back):
    """최근 N일 카드 전부 (오래된 것 → 최신 순)."""
    cards = []
    today = datetime.now().date()
    for d in range(days_back, -1, -1):
        day = today - timedelta(days=d)
        p = CARDS_DIR / (day.strftime("%Y-%m-%d") + ".jsonl")
        if not p.exists():
            continue
        with open(p, encoding="utf-8") as f:
            for line in f:
                try:
                    cards.append(json.loads(line))
                except json.JSONDecodeError:
                    health_incr("card_parse_failures")
    return cards


def open_pendings(cards, include_snoozed=False):
    """미결 중 아직 해소 안 된 것 — 브리핑·보고·resolve가 같은 목록과 번호를 봐야 한다.
    재워둔 것(snooze)은 기한 전까지 목록에서 숨긴다 — '지금 결정 안 함'도 유효한 처리다."""
    resolved_ids = {c.get("resolves") for c in cards if c.get("resolves")}
    resolved_texts = {c.get("resolves_text") for c in cards if c.get("resolves_text")}
    snoozed = {}
    for c in cards:
        if c.get("type") == "snooze" and c.get("snoozes"):
            snoozed[c["snoozes"]] = c.get("until", "")
    today = datetime.now().strftime("%Y-%m-%d")
    out = []
    for c in cards:
        if c["type"] != "pending" or c.get("resolved"):
            continue
        if c.get("id") in resolved_ids or c["text"] in resolved_texts:
            continue
        if not include_snoozed and snoozed.get(c.get("id"), "") > today:
            continue
        out.append(c)
    return out


def cmd_snooze(args):
    """gari snooze <ID> [일수=7] — 미결을 재운다 (기한 지나면 자동 복귀)."""
    if not args:
        print("사용법: gari snooze <ID> [일수]")
        return 1
    key, days = args[0], int(args[1]) if len(args) > 1 else 7
    cards = read_cards_all()
    target = next((c for c in open_pendings(cards, include_snoozed=True)
                   if c.get("id") == key), None)
    if not target:
        print("해당 ID의 미결 없음: %s" % key)
        return 1
    until = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
    append_cards([{"id": hashlib.md5(("snooze" + key + until).encode()).hexdigest()[:8],
                   "ts": now_iso(), "tool": "gari", "project": target.get("project"),
                   "type": "snooze", "snoozes": key, "until": until,
                   "text": "(재움 %s까지) %s" % (until, target["text"][:60])}])
    print("재웠습니다 — %s까지: %s" % (until, target["text"][:60]))
    return 0


def in_allowlist(cwd, cfg):
    if not cwd:
        return False
    cwd = str(cwd)
    if cfg.get("collect_all"):
        # 전량 수집 (2026-07-06 사용자 지시: "내가 하는 모든 일") — denylist만 제외
        return not any(cwd == p or cwd.startswith(str(p).rstrip("/") + "/")
                       for p in cfg.get("denylist_paths", []))
    return any(cwd == p or cwd.startswith(p.rstrip("/") + "/")
               for p in cfg["allowlist_paths"])


# ---------------------------------------------------------------- 수집: 턴 추출 어댑터

def _claude_text(content):
    """Claude message.content → 사람이 읽는 텍스트 (도구 소음 제거)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(item.get("text", ""))
        return "\n".join(parts)
    return ""


def extract_turns_claude(path, offset):
    """Claude 세션 JSONL에서 (offset 이후) 턴 추출.
    반환: (turns, new_offset, meta, skipped_lines)"""
    turns, skipped = [], 0
    meta = {}
    with open(path, encoding="utf-8") as f:
        f.seek(offset)
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            t = d.get("type")
            if d.get("cwd"):
                meta.setdefault("cwd", d["cwd"])
            if d.get("sessionId"):
                meta.setdefault("session", d["sessionId"])
            if t == "user" and not d.get("isSidechain"):
                text = _claude_text(d.get("message", {}).get("content"))
                # 도구 결과(내용이 list라 text가 빈다)·태그 래퍼는 사용자 발화가 아니다
                if text and not text.startswith("<"):
                    turns.append(("user", text, d.get("timestamp", "")))
            elif t == "assistant" and not d.get("isSidechain"):
                text = _claude_text(d.get("message", {}).get("content"))
                if text:
                    turns.append(("assistant", text, d.get("timestamp", "")))
        new_offset = f.tell()
    return turns, new_offset, meta, skipped


CODEX_WRAPPER_STARTS = ("# AGENTS.md", "<INSTRUCT", "<ENVIRONMENT",
                        "<environment", "<user_instructions")


def _strip_codex_wrappers(text):
    """Codex user 메시지에서 주입 래퍼(AGENTS.md·환경 블록)를 벗기고 실제 발화만 남긴다.
    래퍼 닫는 태그 뒤에 본문이 붙은 형태면 꼬리를 살리고, 전체가 래퍼면 빈 문자열."""
    if not text.startswith(CODEX_WRAPPER_STARTS):
        return text
    tail = text
    for tag in ("</INSTRUCTIONS>", "</ENVIRONMENT_CONTEXT>",
                "</environment_context>", "</user_instructions>"):
        idx = tail.rfind(tag)
        if idx != -1:
            tail = tail[idx + len(tag):]
    tail = tail.strip()
    return "" if tail.startswith(CODEX_WRAPPER_STARTS) else tail


def extract_turns_codex(path, offset):
    """Codex rollout JSONL에서 턴 추출."""
    turns, skipped = [], 0
    meta = {}
    with open(path, encoding="utf-8") as f:
        f.seek(offset)
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            t = d.get("type")
            p = d.get("payload", {})
            if t == "session_meta":
                meta["cwd"] = p.get("cwd")
                meta["session"] = p.get("session_id") or p.get("id")
            elif t == "response_item" and p.get("type") == "message":
                role = p.get("role")
                parts = []
                for item in p.get("content", []):
                    if isinstance(item, dict):
                        txt = item.get("text") or ""
                        if txt:
                            parts.append(txt)
                text = "\n".join(parts)
                # Codex는 지시문·환경 정보도 user 메시지로 기록한다 — 래퍼를 벗기되
                # 같은 메시지 뒤에 실제 요청이 붙어 있으면 그 부분은 살린다 (통짜 스킵 금지)
                if role == "user":
                    text = _strip_codex_wrappers(text)
                if text and role in ("user", "assistant"):
                    turns.append((role, text, d.get("timestamp", "")))
        new_offset = f.tell()
    return turns, new_offset, meta, skipped


def extract_turns_gjc(path, offset):
    """gjc 세션 JSONL — Claude와 같은 콘텐츠 블록 구조라 _claude_text 재사용."""
    turns, skipped = [], 0
    meta = {}
    with open(path, encoding="utf-8") as f:
        f.seek(offset)
        for line in f:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            t = d.get("type")
            if t == "session":
                meta["cwd"] = d.get("cwd")
                meta["session"] = d.get("id")
            elif t == "message":
                m = d.get("message", {})
                role = m.get("role")
                text = _claude_text(m.get("content"))
                if text and role in ("user", "assistant"):
                    turns.append((role, text, d.get("timestamp", "")))
        new_offset = f.tell()
    return turns, new_offset, meta, skipped


SOURCES = {
    # tool: (세션 파일 글롭 루트들, 추출 함수)
    "claude": ([Path.home() / ".claude" / "projects"], extract_turns_claude),
    "codex": ([Path.home() / ".codex" / "sessions"], extract_turns_codex),
    "gjc": ([Path.home() / ".gjc" / "agent" / "sessions"], extract_turns_gjc),
}


def find_session_files(cfg):
    """최근 backfill_hours 내 수정된 세션 파일 나열."""
    horizon = time.time() - cfg["backfill_hours"] * 3600
    found = []  # (tool, path)
    for tool, (roots, _fn) in SOURCES.items():
        for root in roots:
            if not root.exists():
                continue
            for p in root.rglob("*.jsonl"):
                try:
                    if p.stat().st_mtime >= horizon:
                        found.append((tool, p))
                except OSError:
                    continue
    return found


# ---------------------------------------------------------------- 증류

def build_distill_input(turns, cfg):
    """턴들을 증류 입력 텍스트로.

    상한 초과 시 원칙: **사용자 발화는 전량 보존** (결정·교정·미결의 원천),
    AI 발화를 가운데부터 탈락시킨다. 사용자 발화만으로도 초과하면
    머리+꼬리 샘플링으로 최후 절단하되 절단 사실을 명시한다."""
    cap = cfg["max_distill_chars"]
    items = []
    for role, text, ts in turns:
        limit = cfg["user_turn_chars"] if role == "user" else cfg["assistant_turn_chars"]
        items.append((role, text[:limit]))

    def render(sel):
        return "\n\n".join("[%s] %s" % ("사용자" if r == "user" else "AI", t)
                           for r, t in sel)

    blob = render(items)
    if len(blob) <= cap:
        return blob, False
    kept = list(items)
    while len(render(kept)) > cap:
        assistant_idx = [i for i, (r, _) in enumerate(kept) if r == "assistant"]
        if not assistant_idx:
            break
        kept.pop(assistant_idx[len(assistant_idx) // 2])  # 가운데 AI 발화부터 탈락
    blob = render(kept)
    if len(blob) > cap:
        blob = (blob[:int(cap * 0.6)]
                + "\n\n…(중략 — 사용자 발화만으로도 상한 초과, 절단됨)…\n\n"
                + blob[-int(cap * 0.35):])
    return blob, True


def distill(turns, tool, project, session, burst_id, cfg):
    """묶음 → 카드 목록. LLM(claude -p, 저가 모델) 1콜. 실패 시 예외 (조용한 빈손 금지)."""
    prompt = (TEMPLATES / "distill-prompt.txt").read_text(encoding="utf-8")
    blob, truncated = build_distill_input(turns, cfg)
    extra = ""
    if tool == "gari-chat":
        known = {wf.stem for wf in WIKI_DIR.glob("*.md")} if WIKI_DIR.exists() else set()
        known |= {Path(pth).name for pth in cfg["allowlist_paths"]}
        names = ", ".join(sorted(known))
        extra = ("\n추가 규칙 (가리와의 대화 발췌임):\n"
                 "- 이미 기록된 사실의 단순 회상·확인 문답은 카드로 만들지 마라 — 새로운 결정·미결·의견·계획만.\n- 카드의 근거는 형님의 발화만이다. 가리(비서) 답변 속 사실 주장·상태 단정은 절대 카드로 만들지 마라 — 비서의 오답이 기억으로 굳는 것 방지.\n"
                 "- 각 카드에 \"project\" 필드를 넣어라: 내용이 어느 프로젝트 얘기인지 (%s 중 하나, 모르면 \"대화\").") % names
    full = "%s %s%s\n\n=== 대화 발췌 (%s, %s) ===\n%s" % (
        DISTILL_MARKER, prompt, extra, tool, project or "?", blob)
    out, rc = run_claude(full, cfg["distill_model"], cfg, "distill",
                         timeout=cfg["distill_timeout_sec"])
    if (rc != 0 or not out) and Path(cfg.get("gjc_bin", "/nonexistent")).exists():
        # 공급선 이중화: 클로드 불능이어도 기억 적재는 멈추지 않는다
        rg = subprocess.run([cfg["gjc_bin"], "-p", "--no-session", "--no-tools", full],
                            capture_output=True, text=True,
                            timeout=cfg["distill_timeout_sec"])
        if rg.returncode == 0 and rg.stdout.strip():
            out, rc = rg.stdout.strip(), 0
            metric("distill_fallback_gjc")
    if rc != 0 or not out:
        raise RuntimeError("증류 호출 실패 rc=%s" % rc)
    # 모델이 코드펜스로 감싸는 경우 벗긴다
    if out.startswith("```"):
        out = out.strip("`")
        out = out[out.find("["):out.rfind("]") + 1]
    start, end = out.find("["), out.rfind("]")
    if start == -1 or end == -1:
        raise RuntimeError("증류 출력에 JSON 배열 없음: %s" % out[:200])
    items = json.loads(out[start:end + 1])
    cards = []
    for it in items:
        if not isinstance(it, dict) or "type" not in it or "text" not in it:
            continue
        if it["type"] not in ("decision", "pending", "correction",
                              "violation", "repeat", "win"):
            continue
        item_proj = it.get("project")
        cards.append({
            "id": hashlib.md5((burst_id + it["text"]).encode()).hexdigest()[:8],
            "ts": now_iso(), "tool": tool,
            "project": item_proj if isinstance(item_proj, str) and 0 < len(item_proj) < 40 else project,
            "session": (session or "")[:12], "burst": burst_id,
            "type": it["type"], "text": it["text"][:500],
            "quote": (it.get("quote") or "")[:200],
            "shadow": it["type"] in ("violation", "repeat") and cfg.get("shadow_mode", True),
            "resolved": False,
            "truncated_input": truncated,
        })
    return cards


# ---------------------------------------------------------------- sweep (핵심 파이프라인)

def load_cursors_strict():
    """커서는 필수 상태 파일 — 손상 시 조용한 전체 재처리(중복 카드) 대신 즉시 실패."""
    if not CURSORS_PATH.exists():
        return {}
    try:
        with open(CURSORS_PATH, encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        notify("가리 — 이상", "커서 파일 손상 — 스윕 중단. store/cursors.json 확인 필요.")
        raise RuntimeError("cursors.json 손상: %s" % e)


def peek_meta(tool, path, max_lines=100):
    """본문을 읽지 않고 파일 머리에서 cwd·세션만 캔다 — 스코프(allowlist) 선판정용.
    비허용 프로젝트의 대화 내용이 메모리에 올라가지 않게 하는 격리 장치."""
    meta = {}
    try:
        with open(path, encoding="utf-8") as f:
            for i, line in enumerate(f):
                if i >= max_lines or ("cwd" in meta and "session" in meta):
                    break
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if tool == "codex" and d.get("type") == "session_meta":
                    p = d.get("payload", {})
                    meta["cwd"] = p.get("cwd")
                    meta["session"] = p.get("session_id") or p.get("id")
                elif tool == "gjc" and d.get("type") == "session":
                    meta["cwd"] = d.get("cwd")
                    meta["session"] = d.get("id")
                elif tool == "claude":
                    if d.get("cwd"):
                        meta.setdefault("cwd", d["cwd"])
                    if d.get("sessionId"):
                        meta.setdefault("session", d["sessionId"])
    except OSError:
        pass
    return meta


def acquire_sweep_lock(cfg):
    """스윕 겹침 방지 (launchd 주기 vs 수동 done의 동시 실행 → 중복 카드 차단)."""
    lock = STORE / "sweep.lock"
    if lock.exists():
        age = time.time() - lock.stat().st_mtime
        if age < cfg["sweep_lock_stale_min"] * 60:
            return None
        print("[경고] %d초 묵은 스윕 락 회수 (죽은 스윕 잔재)" % age, file=sys.stderr)
        lock.unlink()
    lock.write_text(str(os.getpid()))
    return lock


def cmd_sweep(args):
    cfg = load_config()
    lock = acquire_sweep_lock(cfg)
    if lock is None:
        print("다른 스윕이 진행 중 — 이번 회차 건너뜀")
        return 0
    try:
        return _sweep_inner(args, cfg)
    finally:
        try:
            lock.unlink()
        except OSError:
            pass


def _sweep_inner(args, cfg):
    cursors = load_cursors_strict()
    now = time.time()
    idle_sec = cfg["idle_minutes"] * 60
    force = "--force" in args  # `gari done` 경유: 유휴 무시하고 지금 닫기
    closed, receipts, errors = 0, [], []

    for tool, path in find_session_files(cfg):
        key = str(path)
        cur = cursors.get(key, {"offset": 0})
        try:
            st = path.stat()
        except OSError:
            continue
        if st.st_size <= cur["offset"]:
            continue  # 새 내용 없음
        if not force and (now - st.st_mtime) < idle_sec:
            continue  # 묶음 아직 열려 있음 — 다음 스윕에서

        # 1) 스코프 선판정 — 비허용(회사 등) 프로젝트는 본문을 읽지 않는다
        meta = cur.get("meta") or peek_meta(tool, path)
        if meta.get("cwd") and not in_allowlist(meta["cwd"], cfg):
            health_incr("out_of_scope_bursts")
            cursors[key] = {"offset": st.st_size, "meta": meta}
            continue

        # 2) 허용 프로젝트만 본문 추출
        _fn = SOURCES[tool][1]
        try:
            turns, new_offset, extracted_meta, skipped = _fn(path, cur["offset"])
        except Exception as e:
            errors.append("%s 파싱 실패: %s" % (path.name, e))
            n = health_incr("parse_failures_%s" % tool)
            if n >= cfg["parse_failure_alert_after"]:
                notify("가리 — 이상", "%s 로그 파싱 연속 실패 %d회. 형식 변경 의심." % (tool, n), cfg)
            continue
        if skipped:
            health_incr("skipped_lines")
        # 커서 이후 구간에 meta가 없을 수 있다(Codex 증분) — 캐시와 병합해 유실 방지
        meta = dict(extracted_meta, **{k: v for k, v in meta.items() if v})
        project = meta.get("cwd")
        # 자기 증류 대화 재수집 방지
        if any(DISTILL_MARKER in t[1] or "[GARI-DO]" in t[1] for t in turns[:2]):
            cursors[key] = {"offset": new_offset, "meta": meta}
            continue
        if not in_allowlist(project, cfg):  # peek이 못 찾았던 드문 경우의 재판정
            health_incr("out_of_scope_bursts")
            cursors[key] = {"offset": new_offset, "meta": meta}
            continue
        user_turns = [t for t in turns if t[0] == "user"]
        if not user_turns:
            cursors[key] = {"offset": new_offset, "meta": meta}
            continue
        burst_id = "%s-%s" % ((meta.get("session") or path.stem)[:8],
                              datetime.now().strftime("%H%M"))
        try:
            cards = distill(turns, tool, project, meta.get("session"),
                            burst_id, cfg)
        except Exception as e:
            errors.append("%s 증류 실패: %s" % (burst_id, str(e)[:200]))
            health_incr("distill_failures")
            cursors[key] = dict(cur, meta=meta)  # 커서 유지 — 다음 스윕 재시도
            continue
        if not cards and len(user_turns) > cfg["empty_distill_max_user_turns"]:
            # 알맹이 있는 묶음이 빈손 — 유실 방지: 1회 재시도 후에만 수용
            if cur.get("empty_retries", 0) < 1:
                cursors[key] = dict(cur, empty_retries=1, meta=meta)
                errors.append("%s 증류 빈손(사용자 턴 %d개) — 재시도 예약" % (burst_id, len(user_turns)))
                continue
            health_incr("empty_distill_accepted")
        append_cards(cards)
        cursors[key] = {"offset": new_offset, "meta": meta}
        closed += 1
        receipts.append((project, cards))

    # 아침 보고 만회 — 9시에 맥이 꺼져 있었으면 예약이 증발한다 (잠자기는 자동 만회되지만 종료는 아님)
    try:
        now_dt = datetime.now()
        rp = REPORTS_DIR / (now_dt.strftime("%Y-%m-%d") + ".md")
        if (not rp.exists()
                and now_dt.hour * 60 + now_dt.minute >= cfg["report_hour"] * 60 + 30):
            metric("morning_makeup")
            cmd_report(["--morning"])   # 부팅이 늦었어도 그날 보고는 반드시 온다
    except Exception as e:
        errors.append("아침 보고 만회 실패: %s" % str(e)[:120])

    # 가리와의 대화도 1급 기억이다 — 유휴 지난 챗 세션을 증류해 카드로
    if CHATS_DIR.exists():
        for sp in CHATS_DIR.glob("*.jsonl"):
            key = "chat:" + sp.stem
            cur = cursors.get(key, {"offset": 0})
            try:
                st = sp.stat()
            except OSError:
                continue
            if st.st_size <= cur["offset"]:
                continue
            if not force and (now - st.st_mtime) < idle_sec:
                continue
            turns, skipped = [], 0
            with open(sp, encoding="utf-8") as f:
                f.seek(cur["offset"])
                for line in f:
                    try:
                        d = json.loads(line)
                    except json.JSONDecodeError:
                        skipped += 1
                        continue
                    if d.get("_meta"):
                        continue
                    if d.get("q"):
                        turns.append(("user", d["q"], d.get("ts", "")))
                    if d.get("a"):
                        turns.append(("assistant", d["a"], d.get("ts", "")))
                new_off = f.tell()
            if not [t for t in turns if t[0] == "user"]:
                cursors[key] = {"offset": new_off}
                continue
            burst_id = "chat-%s-%s" % (sp.stem[:8], datetime.now().strftime("%H%M"))
            try:
                cards = distill(turns, "gari-chat", "대화", sp.stem, burst_id, cfg)
            except Exception as e:
                errors.append("%s 증류 실패: %s" % (burst_id, str(e)[:200]))
                health_incr("distill_failures")
                continue
            append_cards(cards)
            cursors[key] = {"offset": new_off}
            closed += 1
            receipts.append(("가리 대화", cards))

    # 오래 잠잠한 대화 세션은 보관함으로 (30일 — 업계 수렴값. 삭제 아님)
    if CHATS_DIR.exists():
        arch = CHATS_DIR / "archive"
        cutoff_ts = now - cfg["chat_archive_after_days"] * 86400
        for sp in CHATS_DIR.glob("*.jsonl"):
            if sp.stat().st_mtime < cutoff_ts:
                arch.mkdir(exist_ok=True)
                sp.rename(arch / sp.name)

    save_json(CURSORS_PATH, cursors)
    health_update(last_sweep=now_iso(), last_sweep_errors=errors)
    for evt in QUEUE_DIR.glob("evt-*"):  # 큐 소비 — 이번 스윕이 반영함
        try:
            evt.unlink()
        except OSError:
            pass

    if receipts:
        total = sum(len(c) for _, c in receipts)
        dec = sum(1 for _, cs in receipts for c in cs if c["type"] == "decision")
        pen = sum(1 for _, cs in receipts for c in cs if c["type"] == "pending")
        notify("가리 — 적재 영수증",
               "묶음 %d개 정리 — 카드 %d (결정 %d · 미결 %d)" % (closed, total, dec, pen), cfg)
        rebuild_briefing(cfg)
    if errors:
        print("[sweep 오류]\n" + "\n".join(errors), file=sys.stderr)
    print("sweep 완료: 닫은 묶음 %d, 오류 %d" % (closed, len(errors)))
    return 0 if not errors else 1


# ---------------------------------------------------------------- 브리핑 (세션 주입)

def rebuild_briefing(cfg):
    cards = read_cards(cfg["briefing_days"])
    pend = open_pendings(cards)
    dec = [c for c in cards if c["type"] == "decision"][-cfg["briefing_max_items"]:]
    lines = ["<가리 브리핑 — %s 갱신>" % now_iso()]
    if dec:
        lines.append("최근 결정:")
        for c in dec:
            lines.append("- [%s/%s] %s" % (c["tool"], _proj_short(c), c["text"]))
    if pend:
        lines.append("미결 (해결되면 gari resolve <ID>):")
        for c in pend[-cfg["briefing_max_items"]:]:
            lines.append("- (%s) [%s] %s" % (c.get("id", "?"), _proj_short(c), c["text"]))
    if MENTOR_PATH.exists():
        for _l in MENTOR_PATH.read_text(encoding="utf-8").splitlines():
            if _l.startswith("오늘의 훈련:"):
                lines.append("멘토의 오늘 훈련: " + _l.split(":", 1)[1].strip())
                break
    nag_file = STORE / "nag.txt"
    if nag_file.exists() and nag_file.read_text(encoding="utf-8").strip():
        lines.append("가리의 참견: " + nag_file.read_text(encoding="utf-8").strip())
    next_step_file = STORE / "next-step.txt"
    if next_step_file.exists():
        lines.append("오늘의 한 칸 (아침 산출): "
                     + next_step_file.read_text(encoding="utf-8").strip().replace("\n", " · "))
    if len(lines) == 1:
        lines.append("(전할 것 없음 — 조용한 게 정상)")
    lines.append("과거 맥락 질문('어제/아까/지난번/하던 거')이 나오면 ~/gari/store/cards/ 를 검색할 것.")
    BRIEFING_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    metric("brief_served")   # 세션 하나가 재설명 대신 브리핑을 받음


def _proj_short(card):
    p = card.get("project") or "?"
    return Path(p).name


def cmd_brief(args):
    cfg = load_config()
    if not BRIEFING_PATH.exists():
        rebuild_briefing(cfg)
    sys.stdout.write(BRIEFING_PATH.read_text(encoding="utf-8"))
    return 0


# ---------------------------------------------------------------- 코치: 다음 한 칸 (K1)

def compose_next_step(cards, cfg):
    """북극성·미결·로드맵에서 '오늘의 한 칸' 하나를 산출 (아침 1콜). 결과는 브리핑에도 실린다."""
    pend = open_pendings(cards)
    roadmap_items = []
    roadmap = Path(cfg["roadmap_path"])
    if roadmap.exists():
        roadmap_items = [l.strip() for l in roadmap.read_text(encoding="utf-8").splitlines()
                         if l.strip().startswith("- [ ]")][:6]
    north_head = ""
    north = Path(cfg["north_star_path"])
    if north.exists():
        north_head = "\n".join(north.read_text(encoding="utf-8").splitlines()[:30])
    prompt = ("%s 너는 가리다. 아래 북극성·미결·로드맵을 보고 세 가지를 산출하라: "
              "① 형님이 오늘 잡아야 할 '다음 한 칸' 하나 ② 답이 다음 행동을 바꾸는 '질문' 하나 (미결을 좁히는, 예/아니오가 아닌 질문) "
              "③ '참견' 하나 — 디자인씽킹/PM 렌즈(사용자·문제 정의 부재, 성공지표 없음, 검증 계획 없음, 엣지 미고려, 스코프 팽창, 비가역 결정)로 "
              "형님이 지금 놓치고 있는 것 딱 하나를 구체적으로.\n"
              "출력 형식 (다른 말 금지):\n한 칸: <행동 한 문장>\n이유: <한 문장>\n질문: <한 문장>\n참견: <한두 문장>\n\n"
              "[북극성]\n%s\n\n[미결]\n%s\n\n[로드맵 미완 항목]\n%s") % (
        DISTILL_MARKER, north_head,
        "\n".join("- " + c["text"] for c in pend[:6]) or "(없음)",
        "\n".join(roadmap_items) or "(없음)")
    gaps = wiki_gaps()
    if gaps:
        gap_txt = ", ".join("%s의 '%s'" % (g[0], g[1]) for g in gaps[:6])
        prompt += ("\n\n[시스템이 아는 자기 무지 — 위키 빈칸]\n%s\n"
                   "②의 '질문'은 **반드시 이 빈칸 중 첫 번째 것을 겨냥해라** (더 긴급한 차단 사안이 있을 때만 예외) — "
                   "형님이 입력창에 답하는 순간 그 빈칸이 기록으로 채워진다. 한 번에 하나만, 구체적으로.") % gap_txt
    prompt += "\n\n" + (TEMPLATES / "thinking-lenses.txt").read_text(encoding="utf-8")
    _prefs = load_prefs()
    if _prefs:
        prompt += "\n\n" + _prefs
    r = subprocess.run([cfg["claude_bin"], "-p", prompt, "--model", cfg["ask_fallback_model"]],
                       capture_output=True, text=True,
                       timeout=cfg["distill_timeout_sec"], cwd=str(GARI_HOME))
    if r.returncode != 0:
        raise RuntimeError(r.stderr[:150])
    text = r.stdout.strip()
    question, nag = "", ""
    kept = []
    for line in text.splitlines():
        if line.startswith("질문:"):
            question = line[3:].strip()
        elif line.startswith("참견:"):
            nag = line[3:].strip()
        else:
            kept.append(line)
    (STORE / "next-step.txt").write_text("\n".join(kept) + "\n", encoding="utf-8")
    (STORE / "question.txt").write_text(question + "\n", encoding="utf-8")
    (STORE / "nag.txt").write_text(nag + "\n", encoding="utf-8")
    return "\n".join(kept)


# ---------------------------------------------------------------- 아침 보고

def cmd_report(args):
    cfg = load_config()
    morning = "--morning" in args
    cards = read_cards(1)  # 어제 + 오늘
    if not cards and morning:
        notify("가리 — 아침 보고", "형님, 어제는 적재된 대화가 없습니다. 오늘도 대기하겠습니다.", cfg)
        return 0
    by = lambda t: [c for c in cards if c["type"] == t]
    pend = open_pendings(cards)
    tmpl = (TEMPLATES / "morning-report.md.tmpl").read_text(encoding="utf-8")

    def fmt(cs, empty="- (없음)", cap=10):
        if not cs:
            return empty
        shown = cs[-cap:]
        out = "\n".join("- [%s/%s] %s" % (c["tool"], _proj_short(c), c["text"])
                         for c in shown)
        if len(cs) > cap:
            out += "\n- …외 %d건 (전량은 프로젝트 위키·카드 원장에)" % (len(cs) - cap)
        return out

    health = load_json(HEALTH_PATH, {})
    shadow = [c for c in cards if c.get("shadow") and c.get("id") not in graded_ids(cards)]
    shadow_txt = "\n".join(
        "- [%s] %s — «%s» (채점: gari grade %s right|wrong)" % (c.get("id", "?"), c["text"], c.get("quote", ""), c.get("id", "?"))
        for c in shadow) or "- (없음 — 채점할 것 없음)"
    repeats_week = [c for c in read_cards(7) if c["type"] == "repeat"]
    watchlist = "\n".join([
        "- W3 조용한 실패: %s" % ("이상 없음" if not health.get("distill_failures") else "증류 실패 %d회" % health["distill_failures"]),
        "- W4 수동 지시 회귀: 이번 주 반복 신호 %d건%s" % (len(repeats_week), " — 규칙화 검토 필요" if len(repeats_week) >= 2 else ""),
        "- W1 claude-mem 시범: 판정일 ~07-12 (수동 확인)",
    ])
    issues = []
    if health.get("distill_failures"):
        issues.append("- 증류 실패 %d회 (재시도 큐에 있음)" % health["distill_failures"])
    counter_labels = {
        "skipped_lines": "형식 미상 줄 스킵",
        "card_parse_failures": "카드 파일 파싱 실패",
        "empty_distill_accepted": "빈손 증류 수용",
        "out_of_scope_bursts": "수집 제외(스코프 밖) 묶음",
    }
    for k, v in sorted(health.items()):
        if not v:
            continue
        if k.startswith("parse_failures_"):
            issues.append("- %s 로그 파싱 실패 %d회" % (k.split("_")[-1], v))
        elif k in counter_labels:
            issues.append("- %s %d건" % (counter_labels[k], v))
    pending_setup = load_json(GARI_HOME / "pending-approvals.json", [])
    approvals = "\n".join("- [ ] %s" % a for a in pending_setup) or "- (없음)"
    try:
        next_step = compose_next_step(cards, cfg)
    except Exception as e:
        fallback = pend[0]["text"] if pend else "(미결 없음)"
        next_step = "산출 실패(%s) — 미결 1순위로 대체: %s" % (str(e)[:60], fallback)

    report = tmpl.format(
        date=datetime.now().strftime("%Y-%m-%d"),
        decisions=fmt(by("decision")),
        pendings="\n".join("- (%s) [%s/%s] %s" % (c.get("id", "?"), c["tool"], _proj_short(c), c["text"])
                           for c in pend) or "- (없음)",
        corrections=fmt(by("correction")),
        wins=fmt(by("win"), empty="- (오늘은 조용했습니다)"),
        shadow=shadow_txt,
        issues="\n".join(issues) or "- 파이프라인 정상",
        watchlist=watchlist,
        approvals=approvals,
        next_step=next_step,
        card_total=len(cards),
    )
    # 프로젝트 위키 갱신 — 카드(일지) → 현재 상태 문서 (증분: 새 카드 있는 프로젝트만)
    try:
        regen, kept = regenerate_wikis(cfg)
        if regen:
            report += "\n## 위키 갱신\n\n- 오늘 다시 쓴 프로젝트: %s (전체 %d개 유지 중 — store/wiki/)\n" % (
                ", ".join(regen), kept)
    except (RuntimeError, OSError) as e:
        report += "\n## 위키 갱신\n\n- 실패: %s\n" % str(e)[:100]

    # 잊힘 자가 감지 — 프리모템 1번 사인(방치사)의 알람: 죽어가면 먼저 말한다
    ms3 = metrics_summary(3)
    if ms3.get("brief_served", 0) == 0 and ms3.get("ask_answered", 0) == 0:
        report += ("\n> **저 잊히고 있습니다, 형님.** 3일째 브리핑도 질문도 0회예요. "
                   "바쁘셨다면 좋고요 — 다만 이 보고 하나만 열어주시면 저는 삽니다. "
                   "가리가 성가셔진 거라면 그것도 말해주세요, 고치겠습니다.\n")
        notify("가리 — 잊힘 감지", "형님, 3일째 조용하네요. 아침 보고 한 번만 열어주세요.", cfg)

    # 가리가 어제 대신 한 일 — 측정 루프의 표면 (기준선: 재설명 없이 굴러간 양)
    ms = metrics_summary(1)
    if ms:
        repeat_y = len([c for c in read_cards(1) if c.get("type") == "repeat"])
        report += ("\n## 가리가 어제 대신 한 일\n\n"
                   "- 세션 브리핑 주입(재설명 대체): %d회\n"
                   "- 질문 응답: %d건 (심층 논의 %d · 일반/웹 %d)\n"
                   "- 자가 정정: %d건 · 감지된 재설명(repeat) 카드: %d건\n") % (
            ms.get("brief_served", 0), ms.get("ask_answered", 0),
            ms.get("ask_deep", 0), ms.get("ask_general", 0),
            ms.get("self_correct", 0), repeat_y)

    # 멘토 리뷰 — 직업 이상향 기준의 거울 (2026-07-06 사용자: "멘토처럼 느낄 수 있게")
    try:
        mentor = compose_mentor_review(cfg)
        if mentor:
            report += "\n## 멘토 리뷰 — 시니어 프로덕트 리더의 눈\n\n" + mentor + "\n"
    except (RuntimeError, OSError) as e:
        report += "\n## 멘토 리뷰\n\n- 산출 실패: %s\n" % str(e)[:100]

    # 큐 정리 제안 — 병목 인간이 큐의 사서가 되지 않게 (제안만, 자동 해소 없음)
    try:
        tdata = run_triage(cfg)
        tlines = triage_summary_lines(tdata, {c["id"]: c for c in open_pendings(read_cards_all()) if c.get("id")})
        if tlines:
            report += "\n## 큐 정리 제안 (가리가 검토함)\n\n" + "\n".join("- " + l for l in tlines) + "\n"
    except (RuntimeError, json.JSONDecodeError) as e:
        report += "\n## 큐 정리 제안\n\n- 검토 실패: %s\n" % str(e)[:100]

    report = personalize(report, cfg)
    out = REPORTS_DIR / (datetime.now().strftime("%Y-%m-%d") + ".md")
    out.write_text(report, encoding="utf-8")
    if morning:
        notify("가리 — 아침 보고",
               "형님, 어제 카드 %d장 정리했습니다. `gari` 로 보고 확인하십시오." % len(cards), cfg)
        # 카운터는 보고에 실렸으니 리셋 — 어제의 실패가 오늘의 경고로 계속 뜨지 않게 (데이터는 보고서에 보존)
        h = load_json(HEALTH_PATH, {})
        volatile = ("distill_failures", "skipped_lines", "card_parse_failures",
                    "empty_distill_accepted", "out_of_scope_bursts")
        for k in list(h):
            if k in volatile or k.startswith("parse_failures_"):
                h[k] = 0
        save_json(HEALTH_PATH, h)
    print(report)
    return 0


def cmd_weekly(args):
    """주간 종합보고 — 지난 7일 카드의 추세·결정·교정·연승 집계 (월 09:30 launchd)."""
    cfg = load_config()
    cards = read_cards(7)
    if not cards:
        notify("가리 — 주간 보고", "형님, 이번 주는 적재된 대화가 없습니다.", cfg)
        return 0

    # 번복 신호: 같은 계열 재설명 3회+ → 인터뷰 제안 (헌법 규칙의 자동화)
    from collections import Counter
    rep_keys = Counter(c["text"][:24] for c in cards if c.get("type") == "repeat")
    interview_flags = ["- 같은 재설명 %d회: \"%s…\" — 결정 재료 부족 신호. 5분 인터뷰로 근본 원인을 잡을까요?" % (n, k)
                       for k, n in rep_keys.most_common(3) if n >= 3]
    import random
    audit_lines = ["- [%s/%s] %s" % (c["tool"], _proj_short(c), c["text"][:70])
                   for c in random.sample(cards, min(3, len(cards)))]
    wk_metrics = metrics_summary(7)
    # (해소) 카드는 미결 정리용 북키핑 — 결정 목록에선 제외
    by = lambda t: [c for c in cards
                    if c["type"] == t and not c["text"].startswith("(해소)")]
    pend = open_pendings(cards)

    per_day = {}
    for c in cards:
        per_day.setdefault(c["ts"][:10], 0)
        per_day[c["ts"][:10]] += 1
    daily = "\n".join("- %s: %s %d장" % (d, "█" * min(n // 2 + 1, 25), n)
                      for d, n in sorted(per_day.items()))

    def fmt(cs, cap=15, empty="- (없음)"):
        if not cs:
            return empty
        lines = ["- [%s/%s] %s" % (c["tool"], _proj_short(c), c["text"]) for c in cs[-cap:]]
        if len(cs) > cap:
            lines.insert(0, "- (총 %d건 중 최근 %d건)" % (len(cs), cap))
        return "\n".join(lines)

    shadow = [c for c in cards if c.get("shadow")]
    shadow_summary = ("- 위반 후보 %d · 반복 후보 %d — 아침 보고에서 채점 부탁드립니다"
                      % (len([c for c in shadow if c["type"] == "violation"]),
                         len([c for c in shadow if c["type"] == "repeat"]))
                      if shadow else "- (이번 주 그림자 판정 없음)")
    try:
        next_step = compose_next_step(cards, cfg)
    except Exception as e:
        next_step = "산출 실패(%s) — 미결 1순위: %s" % (
            str(e)[:60], pend[0]["text"] if pend else "(없음)")

    week_label = datetime.now().strftime("%G-W%V")
    # goal 판정 지표: 반복 신호(재설명) 추이 — 줄어드는가
    rep_this = len([c for c in read_cards(7) if c["type"] == "repeat"])
    rep_prev = len([c for c in read_cards(14) if c["type"] == "repeat"]) - rep_this
    repeat_trend = "이번 주 %d건 (지난주 %d건) — %s" % (
        rep_this, rep_prev,
        "감소 ↓" if rep_this < rep_prev else ("동일" if rep_this == rep_prev else "증가 ↑ (규칙화 검토)"))
    tmpl = (TEMPLATES / "weekly-report.md.tmpl").read_text(encoding="utf-8")
    report = tmpl.format(
        repeat_trend=repeat_trend,
        week_label=week_label, card_total=len(cards),
        daily_avg=round(len(cards) / max(len(per_day), 1), 1),
        daily_counts=daily,
        decision_count=len(by("decision")), decisions=fmt(by("decision")),
        pending_count=len(pend), pendings=fmt(pend, cap=10),
        correction_count=len(by("correction")), corrections=fmt(by("correction"), cap=20),
        wins=fmt(by("win"), empty="- (기록된 연승 없음)"),
        shadow_summary=shadow_summary, next_step=next_step)
    report += "\n## 이끌림 신호 (주간 실측)\n\n"
    report += ("- 가리가 대신 한 일: 브리핑 %d회 · 응답 %d건 (심층 %d) · 자가 정정 %d건\n" % (
        wk_metrics.get("brief_served", 0), wk_metrics.get("ask_answered", 0),
        wk_metrics.get("ask_deep", 0), wk_metrics.get("self_correct", 0)))
    if interview_flags:
        report += "\n**번복·재설명 패턴 (인터뷰 후보)**\n" + "\n".join(interview_flags) + "\n"
    report += ("\n**기억 감사 표본 3장** — 원문과 다르게 적힌 게 보이면 알려주세요 (정정 카드로 덮습니다)\n"
               + "\n".join(audit_lines) + "\n")
    report = personalize(report, cfg)
    out = REPORTS_DIR / ("weekly-%s.md" % week_label)
    out.write_text(report, encoding="utf-8")
    notify("가리 — 주간 종합보고", "형님, %s 주간 정리 나왔습니다. `gari weekly`로 확인." % week_label, cfg)
    print(report)
    return 0


# ---------------------------------------------------------------- 상태·조작

def cmd_status(args):
    cfg = load_config()
    h = load_json(HEALTH_PATH, {})
    cards_today = read_cards(0)
    q = list(QUEUE_DIR.glob("*"))
    loaded = subprocess.run(["launchctl", "list"], capture_output=True,
                            text=True).stdout
    print("가리 상태 — %s" % now_iso())
    la = Path.home() / "Library" / "LaunchAgents"
    sweep_plist = la / "com.airu.gari-sweep.plist"
    if sweep_plist.exists() and (
            "<integer>%d</integer>" % (cfg["sweep_interval_min"] * 60)
            not in sweep_plist.read_text()):
        print("  ⚠ config의 스윕 주기(%d분)와 launchd plist 불일치 — plist 재복사+reload 필요"
              % cfg["sweep_interval_min"])
    morning_plist = la / "com.airu.gari-morning.plist"
    if morning_plist.exists() and (
            "<key>Hour</key>\n    <integer>%d</integer>" % cfg["report_hour"]
            not in morning_plist.read_text()):
        print("  ⚠ config의 보고 시각(%d시)과 launchd plist 불일치 — plist 재복사+reload 필요"
              % cfg["report_hour"])
    print("  마지막 스윕: %s" % h.get("last_sweep", "(아직 없음)"))
    print("  오늘 카드: %d장 | 큐: %d건" % (len(cards_today), len(q)))
    print("  launchd 스윕 잡: %s" % ("등록됨" if "gari-sweep" in loaded else "❌ 미등록"))
    print("  launchd 아침 잡: %s" % ("등록됨" if "gari-morning" in loaded else "❌ 미등록"))
    for k, v in sorted(h.items()):
        if ("failure" in k or k == "out_of_scope_bursts") and v:
            print("  ⚠ %s: %s" % (k, v))
    errs = h.get("last_sweep_errors") or []
    for e in errs:
        print("  ⚠ %s" % e)
    return 0


def cmd_enqueue(args):
    """훅에서 호출 — stdin(JSON) 또는 인자에서 경로 힌트를 받아 큐에 터치. 즉시 종료."""
    payload = ""
    if not sys.stdin.isatty():
        payload = sys.stdin.read()
    ts = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    tmp = QUEUE_DIR / (".evt-" + ts + ".tmp")
    tmp.write_text(payload[:2000], encoding="utf-8")
    tmp.rename(QUEUE_DIR / ("evt-" + ts))  # 원자적 완성 — 쓰다 만 이벤트가 소비되지 않게
    return 0


def cmd_done(args):
    """수동 묶음 마감: 유휴 대기 없이 지금 정리."""
    return cmd_sweep(["--force"])


def cmd_resolve(args):
    """미결 해소: gari resolve <카드ID(8자리)|브리핑 번호>. ID가 정답 — 번호는 목록이 바뀌면 오발 위험."""
    cfg = load_config()
    if not args:
        print("사용법: gari resolve <카드ID|번호>")
        return 1
    key = args[0]
    cards = read_cards(cfg["briefing_days"])
    pend = open_pendings(cards)
    target = None
    if len(key) == 8 and not key.isdigit():
        target = next((c for c in pend if c.get("id") == key), None)
        if target is None:
            print("해당 ID의 열린 미결이 없습니다: %s" % key)
            return 1
    else:
        idx = int(key)
        window = pend[-cfg["briefing_max_items"]:]
        if idx < 0 or idx >= len(window):
            print("번호 범위 밖: %d (열린 미결 %d건)" % (idx, len(window)))
            return 1
        target = window[idx]
    resolution = {**target, "type": "decision", "ts": now_iso(),
                  "text": "(해소) " + target["text"], "resolved": True,
                  "resolves": target.get("id"), "resolves_text": target["text"]}
    append_cards([resolution])
    rebuild_briefing(cfg)
    print("해소 처리: %s" % target["text"])
    return 0


def graded_ids(cards):
    return {c.get("grades") for c in cards if c.get("grades")}


def cmd_grade(args):
    """그림자 코치 채점: gari grade <카드ID> right|wrong — 코치 발화 개시의 근거 데이터."""
    cfg = load_config()
    if len(args) < 2 or args[1] not in ("right", "wrong"):
        print("사용법: gari grade <카드ID> right|wrong")
        return 1
    cid, verdict = args[0], args[1]
    cards = read_cards(cfg["briefing_days"])
    target = next((c for c in cards if c.get("id") == cid and c.get("shadow")), None)
    if target is None:
        print("해당 ID의 그림자 카드가 없습니다: %s" % cid)
        return 1
    append_cards([{"id": hashlib.md5(("grade" + cid).encode()).hexdigest()[:8],
                   "ts": now_iso(), "tool": "gari", "project": target.get("project"),
                   "session": "", "burst": "grade",
                   "type": "grade", "text": "채점 %s: %s" % ("맞음" if verdict == "right" else "오발", target["text"][:80]),
                   "quote": "", "shadow": False, "resolved": False,
                   "grades": cid, "verdict": verdict}])
    print("채점 기록: %s → %s" % (cid, verdict))
    return 0


def cmd_log(args):
    n = int(args[0]) if args else 20
    for c in read_cards(2)[-n:]:
        print("%s %-10s %-8s %s" % (c["ts"][5:16], c["type"], c["tool"], c["text"]))
    return 0


CHATS_DIR = STORE / "chats"          # 세션당 파일 1개: <id>.jsonl (1행 = 문답 1개)
CHAT_CURRENT = STORE / "chat-current" # 현재 세션 id


def _chat_path(sid):
    return CHATS_DIR / (sid + ".jsonl")


def chat_new_session(first_q=""):
    """새 대화 세션 — 제목은 첫 질문 요약(40자)."""
    CHATS_DIR.mkdir(exist_ok=True)
    sid = hashlib.md5((now_iso() + first_q).encode()).hexdigest()[:8]
    title = (first_q[:40] + ("…" if len(first_q) > 40 else "")) or "새 대화"
    with open(_chat_path(sid), "w", encoding="utf-8") as f:
        f.write(json.dumps({"_meta": True, "title": title, "created": now_iso()},
                           ensure_ascii=False) + "\n")
    CHAT_CURRENT.write_text(sid, encoding="utf-8")
    return sid


def chat_current_session(cfg, first_q=""):
    """현재 세션 id — 이어하기가 기본, 새 세션은 명시적(--new/버튼)으로만.
    (리서치 2026-07-06: Claude Code·Codex·Gemini CLI·ChatGPT 전부 타이머 분절 없음 — 세션=작업 단위)"""
    if CHAT_CURRENT.exists():
        sid = CHAT_CURRENT.read_text(encoding="utf-8").strip()
        if _chat_path(sid).exists():
            return sid
    return chat_new_session(first_q)


def _chat_set_meta(sid, key, value):
    """세션 메타(1행)에 키 갱신 — 파견 대기 등."""
    p = _chat_path(sid)
    if not p.exists():
        return
    lines = p.read_text(encoding="utf-8").splitlines()
    if not lines:
        return
    try:
        meta = json.loads(lines[0])
        if not meta.get("_meta"):
            return
    except json.JSONDecodeError:
        return
    if value is None:
        meta.pop(key, None)
    else:
        meta[key] = value
    lines[0] = json.dumps(meta, ensure_ascii=False)
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")


def chat_read(sid):
    """세션의 (meta, turns)."""
    meta, turns = {"title": "대화"}, []
    p = _chat_path(sid)
    if not p.exists():
        return meta, turns
    for line in p.read_text(encoding="utf-8").splitlines():
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("_meta"):
            meta = d
        else:
            turns.append(d)
    return meta, turns


def chat_sessions():
    """세션 목록 (최근 갱신순)."""
    if not CHATS_DIR.exists():
        return []
    out = []
    for p in CHATS_DIR.glob("*.jsonl"):
        meta, turns = chat_read(p.stem)
        out.append({"id": p.stem, "title": meta.get("title", "대화"),
                    "updated": p.stat().st_mtime, "turns": len(turns)})
    return sorted(out, key=lambda s: -s["updated"])


def load_chat_history(cfg, sid):
    _, turns = chat_read(sid)
    return turns[-cfg["chat_history_turns"]:]


def append_chat(sid, question, answer):
    meta, turns = chat_read(sid)
    if not turns and meta.get("title") in ("새 대화", "대화", "", None):
        _chat_set_meta(sid, "title", question[:40])   # 첫 질문 = 제목
    with open(_chat_path(sid), "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": now_iso(), "q": question, "a": answer},
                           ensure_ascii=False) + "\n")


def cmd_chat(args):
    """대화 세션 관리: gari chat(목록) / chat new / chat use <id> / chat show [id]"""
    cfg = load_config()
    if not args:
        cur = CHAT_CURRENT.read_text(encoding="utf-8").strip() if CHAT_CURRENT.exists() else ""
        sessions = chat_sessions()
        if not sessions:
            print("대화 세션이 아직 없습니다 — gari ask 로 시작하십시오.")
            return 0
        for s in sessions[:12]:
            mark = "▶" if s["id"] == cur else " "
            print("%s %s  %s  (%d문답, %s)" % (
                mark, s["id"], s["title"], s["turns"],
                datetime.fromtimestamp(s["updated"]).strftime("%m/%d %H:%M")))
        return 0
    if args[0] == "new":
        sid = chat_new_session()
        print("새 대화 시작: %s" % sid)
        return 0
    if args[0] == "archive" and len(args) > 1:
        src_p = _chat_path(args[1])
        if not src_p.exists():
            print("해당 세션 없음: %s" % args[1])
            return 1
        arch = CHATS_DIR / "archive"
        arch.mkdir(exist_ok=True)
        src_p.rename(arch / src_p.name)
        print("보관함으로 이동 (삭제 아님): %s" % args[1])
        return 0
    if args[0] == "use" and len(args) > 1:
        if not _chat_path(args[1]).exists():
            print("해당 세션 없음: %s" % args[1])
            return 1
        CHAT_CURRENT.write_text(args[1], encoding="utf-8")
        print("대화 전환: %s" % args[1])
        return 0
    if args[0] == "show":
        sid = args[1] if len(args) > 1 else (
            CHAT_CURRENT.read_text(encoding="utf-8").strip() if CHAT_CURRENT.exists() else "")
        meta, turns = chat_read(sid)
        print("[%s] %s" % (sid, meta.get("title", "")))
        for t in turns:
            print("나: %s\n가리: %s\n" % (t["q"], t["a"]))
        return 0
    print("사용법: gari chat [new|use <id>|show [id]|archive <id>]")
    return 1


USAGE_LOG = STORE / "usage.jsonl"
PREFS_PATH = STORE / "prefs.md"


def load_prefs():
    """형님의 지속 지시 — 모든 산출 프롬프트에 주입 (최근 30줄)."""
    if not PREFS_PATH.exists():
        return ""
    lines = [l for l in PREFS_PATH.read_text(encoding="utf-8").splitlines() if l.strip()]
    if not lines:
        return ""
    return "=== 형님의 지속 지시 (모든 답과 산출에서 반드시 따를 것) ===\n" + "\n".join(lines[-30:])
ASK_STATUS = STORE / "ask-status.txt"
METRICS_LOG = STORE / "metrics.jsonl"


def metric(kind, note=""):
    """가치 계측 이벤트 — 아침 보고의 '가리가 어제 대신 한 일'과 주간 추세의 원자료."""
    try:
        with open(METRICS_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": now_iso(), "kind": kind, "note": note[:80]},
                               ensure_ascii=False) + "\n")
    except OSError:
        pass


def metrics_summary(days=1):
    if not METRICS_LOG.exists():
        return {}
    cutoff = (datetime.now().astimezone() - timedelta(days=days)).isoformat()
    from collections import Counter
    cnt = Counter()
    for line in METRICS_LOG.read_text(encoding="utf-8").splitlines():
        try:
            d = json.loads(line)
            if d["ts"] >= cutoff:
                cnt[d["kind"]] += 1
        except (json.JSONDecodeError, KeyError):
            continue
    return dict(cnt)


def set_ask_status(text):
    try:
        ASK_STATUS.write_text(text, encoding="utf-8")
    except OSError:
        pass


CLAUDE_ENV = dict(os.environ, CLAUDE_CODE_MAX_OUTPUT_TOKENS="16000")  # 긴 논의 답변 잘림 방지


def run_claude(prompt, model, cfg, kind, tools=None, timeout=None, cwd=None, max_out=None):
    """claude -p 호출 단일 관문 — JSON 출력으로 비용·시간을 계측해 usage.jsonl에 남긴다 (fail-loud)."""
    prompt = personalize(prompt, cfg)
    cmd = [cfg["claude_bin"], "-p", prompt, "--model", model, "--output-format", "json"]
    if tools:
        cmd += ["--allowedTools", tools]
    t0 = time.time()
    env = dict(CLAUDE_ENV, CLAUDE_CODE_MAX_OUTPUT_TOKENS=str(max_out)) if max_out else CLAUDE_ENV
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout or cfg["distill_timeout_sec"],
                           cwd=cwd or str(GARI_HOME), env=env)
    except OSError:
        # 실행파일 자체가 죽어 있음 — 정상 실패로 변환해 폴백 경로가 잡게 한다
        return "", 1
    dur = round(time.time() - t0, 1)
    text, cost, tokens = "", None, None
    if r.returncode == 0 and r.stdout.strip():
        try:
            j = json.loads(r.stdout)
            # 형태: 이벤트 배열 (마지막에 type=result) 또는 단일 딕셔너리 — 둘 다 수용
            res = None
            if isinstance(j, list):
                res = next((x for x in reversed(j)
                            if isinstance(x, dict) and x.get("type") == "result"), None)
            elif isinstance(j, dict):
                res = j
            if res:
                text = (res.get("result") or "").strip()
                cost = res.get("total_cost_usd")
                u = res.get("usage") or {}
                tokens = {"in": u.get("input_tokens"), "out": u.get("output_tokens"),
                          "cache_read": u.get("cache_read_input_tokens")}
        except json.JSONDecodeError:
            text = r.stdout.strip()   # JSON 미지원 폴백 — 계측만 빠짐
    try:
        with open(USAGE_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": now_iso(), "kind": kind, "model": model,
                                "cost_usd": cost, "sec": dur, "tokens": tokens,
                                "ok": r.returncode == 0}, ensure_ascii=False) + "\n")
    except OSError:
        pass
    return text, r.returncode


_TOOL_KR = {"Read": "읽는 중", "Grep": "뒤지는 중", "Glob": "훑는 중",
            "WebSearch": "웹 검색", "WebFetch": "웹 페이지 확인"}


def _tool_status(name, inp):
    """도구 호출 이벤트 → 사람이 읽는 진행 문구 (실제 활동만 — 흉내 금지)."""
    if name == "ToolSearch":
        return None
    verb = _TOOL_KR.get(name, name + " 실행 중")
    detail = ""
    if name == "Read":
        detail = Path(str(inp.get("file_path", ""))).name
    elif name == "Grep":
        detail = "'%s' (%s)" % (inp.get("pattern", ""), Path(str(inp.get("path", "") or "~")).name)
    elif name == "Glob":
        detail = str(inp.get("pattern", ""))
    elif name == "WebSearch":
        detail = "'%s'" % inp.get("query", "")
    elif name == "WebFetch":
        u = str(inp.get("url", ""))
        detail = u.split("/")[2] if "://" in u else u[:40]
    return ("%s — %s" % (verb, detail[:70])) if detail else verb


def run_claude_stream(prompt, model, cfg, kind, tools, timeout=None, cwd=None):
    """도구를 쓰는 뇌 호출 — 이벤트를 줄 단위로 받아 실제 진행 상황을 ask-status에 중계한다."""
    prompt = personalize(prompt, cfg)
    cmd = [cfg["claude_bin"], "-p", prompt, "--model", model,
           "--output-format", "stream-json", "--include-partial-messages",
           "--allowedTools", tools]
    t0 = time.time()
    deadline = t0 + (timeout or cfg["do_timeout_sec"])
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, cwd=cwd or str(GARI_HOME), env=CLAUDE_ENV)
    text, cost, rc, tokens = "", None, 1, None
    buf, last_beat = "", t0
    base = "%s 생각 중 (%s)" % ("깊이" if "deep" in kind else "답", model)
    try:
        for line in proc.stdout:
            if time.time() > deadline:
                proc.kill()
                break
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            et = ev.get("type")
            if et == "stream_event":   # 실제 집필 실황 — 지금 쓰고 있는 섹션을 그대로 중계
                delta = (ev.get("event", {}).get("delta") or {})
                if delta.get("type") == "text_delta":
                    buf += delta.get("text", "")
                    if "\n" in delta.get("text", ""):
                        heads = [l.lstrip("# ").strip() for l in buf.splitlines()
                                 if l.startswith("##")]
                        if heads:
                            set_ask_status("쓰는 중 — %s · %ds" % (heads[-1][:40], time.time() - t0))
                            last_beat = time.time()
            elif et == "assistant":
                for b in ev.get("message", {}).get("content", []):
                    if b.get("type") == "tool_use":
                        st = _tool_status(b.get("name", ""), b.get("input", {}) or {})
                        if st:
                            set_ask_status(st)
                            last_beat = time.time()
            elif et == "result":
                text = (ev.get("result") or "").strip()
                cost = ev.get("total_cost_usd")
                u = ev.get("usage") or {}
                tokens = {"in": u.get("input_tokens"), "out": u.get("output_tokens"),
                          "cache_read": u.get("cache_read_input_tokens")}
                rc = 0
            if time.time() - last_beat > 4:   # 이벤트가 뜸해도 심박은 진짜(경과 시간)로
                set_ask_status("%s · %ds" % (base, time.time() - t0))
                last_beat = time.time()
        proc.wait(timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        proc.kill()
    try:
        with open(USAGE_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": now_iso(), "kind": kind, "model": model,
                                "cost_usd": cost, "sec": round(time.time() - t0, 1),
                                "tokens": tokens, "ok": rc == 0}, ensure_ascii=False) + "\n")
    except OSError:
        pass
    return text, rc


def usage_summary(days=1):
    """최근 N일 가리 발 LLM 호출 비용 요약."""
    if not USAGE_LOG.exists():
        return {"calls": 0, "cost": 0.0, "by_kind": {}}
    cutoff = datetime.now().astimezone() - timedelta(days=days)
    calls, cost, by = 0, 0.0, {}
    for line in USAGE_LOG.read_text(encoding="utf-8").splitlines():
        try:
            d = json.loads(line)
            if datetime.fromisoformat(d["ts"]) < cutoff:
                continue
        except (json.JSONDecodeError, KeyError, ValueError):
            continue
        calls += 1
        c = d.get("cost_usd") or 0.0
        cost += c
        k = d.get("kind", "?")
        by.setdefault(k, [0, 0.0])
        by[k][0] += 1
        by[k][1] += c
    return {"calls": calls, "cost": round(cost, 4),
            "by_kind": {k: {"calls": v[0], "cost": round(v[1], 4)} for k, v in by.items()}}


def cmd_cost(args):
    """gari cost [일수] — 가리가 쓴 LLM 비용 (구독 계정이라 명목치지만 상대 비교에 유효)."""
    days = int(args[0]) if args else 1
    s = usage_summary(days)
    print("가리 LLM 사용 — 최근 %d일: %d콜, $%.4f" % (days, s["calls"], s["cost"]))
    for k, v in sorted(s["by_kind"].items(), key=lambda kv: -kv[1]["cost"]):
        print("  %-12s %3d콜  $%.4f" % (k, v["calls"], v["cost"]))
    print("(주의: gjc 경유 호출은 미계측)")
    return 0


def cmd_ask(args):
    """자연어 창구: gari ask "어제 뭐 결정했지?" [--tool gjc] — 카드 근거로 가리가 답한다."""
    cfg = load_config()
    tool, rest, force_new = cfg.get("ask_tool_default", "claude"), [], False
    i = 0
    while i < len(args):
        if args[i] == "--tool":
            i += 1
            tool = args[i]
        elif args[i] == "--new":
            force_new = True
        else:
            rest.append(args[i])
        i += 1
    args = rest
    if not args:
        print('사용법: gari ask "질문" [--new] [--tool claude|gjc]')
        return 1
    question = " ".join(args)
    sid = chat_new_session(question) if force_new else chat_current_session(cfg, question)

    # 파견 승인 루프: 직전에 제안한 파견이 있고 형님이 승인하면 → 실제 파견 (백그라운드)
    meta, _turns = chat_read(sid)
    pend_d = meta.get("pending_dispatch")
    if pend_d and question.strip().lower() in ("ㄱㄱ", "ㄱ", "고", "go", "진행", "진행해", "해", "해줘", "응", "웅", "yes", "y", "그래", "오케이", "ok"):
        child = [str(GARI_HOME / "bin" / "gari"), "do", pend_d["task"], "--bg"]
        if pend_d.get("dir"):
            child += ["--in", pend_d["dir"]]
        if pend_d.get("write"):
            child.append("--write")
        subprocess.run(child, capture_output=True, text=True, timeout=30)
        _chat_set_meta(sid, "pending_dispatch", None)
        answer = "파견했습니다, 형님 — %s. 끝나면 알림으로 보고드리고 카드로 남깁니다." % pend_d["task"][:80]
        append_chat(sid, question, answer)
        set_ask_status("")
        print(answer)
        return 0

    deep_session = bool(meta.get("deep"))
    if deep_session and any(w in question for w in ("주제 바꿔", "새 주제", "가볍게", "그만하자")):
        _chat_set_meta(sid, "deep", None)
        deep_session = False
    attach_paths = [m.group(1).strip() for m in re.finditer(r"\[첨부:\s*([^\]]+)\]", question)]
    attach_paths = [a for a in attach_paths if Path(a).expanduser().exists()]

    cards = read_cards(cfg["briefing_days"])
    # 관련 카드 소환: 질문 키워드로 전체 원장 검색 → 최신 창에 합류 (최신 홍수에 기억이 밀려나지 않게)
    tokens = [t for t in re.findall(r"[가-힣a-zA-Z0-9]{2,}", question)][:8]
    pool = read_cards_all()
    relevant = [c for c in pool
                if any(t in c.get("text", "") or t in str(c.get("project", "")) for t in tokens)][-40:]
    seen_ids = set()
    merged = []
    for c in relevant + cards[-90:]:
        key = c.get("id") or c["text"][:30]
        if key in seen_ids:
            continue
        seen_ids.add(key)
        merged.append(c)
    merged.sort(key=lambda c: c["ts"])
    lines = ["(%s) %s [%s/%s] %s: %s" % (c.get("id", "-"), c["ts"][:16], c["tool"],
                                         _proj_short(c), c["type"], c["text"])
             for c in merged[-130:]]
    history = load_chat_history(cfg, sid)
    hist_txt = "\n".join("나: %s\n가리: %s" % (t["q"], t["a"]) for t in history)
    persona = (TEMPLATES / "ask-prompt.txt").read_text(encoding="utf-8")
    facts = ("\n\n[가리 자기 구조 사실표 — 자기 자신에 대한 질문은 이 표로만 답하고, 여기 없으면 모른다고 하라]\n"
             "- 수집(정리): %d분마다 자동 스윕 → 카드. 세션 시작 때 하는 건 '브리핑 주입'(최근 결정·미결 요약)이다.\n"
             "- 아침 보고: 매일 %d시 예약 실행 (한 칸·멘토 리뷰·참견·질문·큐 정리 포함). 세션 시작과 무관.\n"
             "- 주간 보고: 매주 월요일 9:30 (gari weekly). 뇌클론의 /brain-distill 의식과는 별개 시스템이다.\n"
             "- 모순 순찰: 하루 1회 아침 트리아지에서. 실시간이 아니다.\n"
             "- 뇌 배치: 접수·기억답변·증류=haiku / 판단·멘토·일반지식·아침산출=sonnet.\n"
             "- 저장: ~/gari/store (카드 원장·대화·보고). 원문 대화는 각 CLI 폴더에 그대로, 가리는 읽기만.\n"
             "- 수집 범위: 전량 (2026-07-06 형님 지시). 그 이전 회사 기록은 소급분만.\n"
             "- 위키 보유 프로젝트 (활동 이력 명단): %s. 이 밖의 이름을 지어내지 마라 — "
             "단, 형님이 명단 밖 이름을 말하면 옛/휴면 프로젝트일 수 있으니 부정하지 말고 카드·문서에서 근거를 찾아 답하라.\n"
             "- 화면 지도 — 현황판 탭: ①오늘 카드(한 칸·멘토 훈련·참견·질문 — 아침 산출) ②프로젝트 방향판(위키 기반, 프로젝트별 정체+다음 결정) "
             "③처리함(형님 액션 인박스: ▶지금 이거 1건 / 끝난 듯·중복=가리 정리 제안으로 접힘 / ◇결재 / 채점 맞음·오발 / 실무 대기=파견 가능이라 접힘 / 그 외 미결) "
             "④오늘 기록 1줄. 대화 탭: 세션 목록·말풍선 스레드. 행 클릭=맥락 질문, 완료/나중에 버튼.") % (
        cfg["sweep_interval_min"], cfg["report_hour"],
        ", ".join(sorted(wf.stem for wf in WIKI_DIR.glob("*.md"))) if WIKI_DIR.exists() else "(없음)")
    persona += facts
    if cfg.get("collect_all"):
        scope_line = ("모든 CLI 대화를 수집한다 (회사 포함 전량 — 2026-07-06 형님 지시). "
                      "단 전량 수집 시작 시점(2026-07-06 저녁) 이전의 회사 기록은 없다 — 그 이전 질문엔 이 사실을 밝혀라.")
    else:
        scope_line = "이 개인 프로젝트들만 수집한다: %s. 그 밖은 수집 범위 밖임을 먼저 밝혀라." % ", ".join(
            sorted({Path(pth).name for pth in cfg["allowlist_paths"]}))
    persona += ("\n\n[수집 범위 자각 — 위반 금지]\n너의 기억(카드)은 %s\n"
                "기록이 없다는 것은 진행이 없다는 뜻이 절대 아니다 — 혼동해 말하면 그것은 거짓 보고다.\n"
                "오래된 흔적은 \"마지막 흔적\"이라고만 부르고 현재 상태를 추정하지 마라.") % scope_line
    lenses = (TEMPLATES / "thinking-lenses.txt").read_text(encoding="utf-8")
    prefs = load_prefs()
    if prefs:
        lenses = lenses + "\n\n" + prefs
    # 순서 = 캐시 계층: 안 변하는 것(페르소나·렌즈) → 가끔 변하는 것(카드) → 매 턴 변하는 것(문답·질문)
    # 프롬프트 캐시는 앞부분 일치 구간만 재사용하므로, 자주 변하는 걸 뒤로 보낼수록 싸고 빨라진다
    full = "%s %s\n\n%s\n\n=== 카드 (최근) ===\n%s\n\n=== 이전 문답 (이어지는 대화) ===\n%s\n\n=== 형님의 질문 ===\n%s" % (
        DISTILL_MARKER, persona, lenses,
        "\n".join(lines) or "(없음)", hist_txt or "(첫 대화)", question)

    SELF_WORDS = ("처리함", "현황판", "방향판", "위키", "카드", "재우", "나중에", "스누즈",
                  "브리핑", "아침 보고", "보고서", "트리아지", "정리 제안", "펫", "말풍선",
                  "입력창", "대화창", "세션", "소급", "증류", "수집")
    self_q = any(w in question for w in SELF_WORDS)
    if self_q:
        # 자기 구조 질문 고속차선 — 심층 금지, 사실표 즉답 (몇 초)
        persona += ("\n\n[고속차선] 이 질문은 가리 자기 구조·규칙에 대한 것이다. "
                    "위 사실표와 화면 지도로 지금 즉답하라. [깊은사고]·[일반질문] 마커 출력 금지.")
    elif deep_session:
        # 논의 세션: 접수는 거치되, 판단 계열이면 주저 없이 심층으로 보내라는 편향만 부여
        persona += ("\n\n[지금 이 세션은 깊은 논의 중] 직전 주제의 전략·판단 후속이면 주저 없이 [깊은사고]를 출력하라. "
                    "단 가벼운 사실·설명 질문이면 네가 즉답하라 — 심층은 느리고 비싸다.")
    if attach_paths:
        # 첨부가 있으면 곧장 비전 경로 — Read 도구가 이미지를 직접 본다
        metric("ask_attach", question[:60])
        set_ask_status("첨부 확인 중 — %d개 파일" % len(attach_paths))
        clean_q = re.sub(r"\[첨부:[^\]]+\]", "", question).strip() or "이 첨부를 확인해줘"
        att_prompt = ("%s 너는 \"가리\" — 형님(아이루)의 솔직한 부하이자 PM이다. "
                      "아래 첨부 파일(이미지 포함)을 **Read 도구로 반드시 열어 직접 본 뒤** 답하라. "
                      "결론 먼저, 제품 언어로. 호칭 형님.\n\n첨부:\n%s\n\n"
                      "=== 이전 문답 ===\n%s\n\n=== 형님의 질문 ===\n%s") % (
            DISTILL_MARKER, "\n".join("- " + a for a in attach_paths),
            hist_txt or "(첫 대화)", clean_q)
        answer, rc = run_claude_stream(att_prompt, cfg["ask_fallback_model"], cfg, "ask-attach",
                                       "Read,Glob,Grep,WebSearch,WebFetch",
                                       timeout=cfg["do_timeout_sec"], cwd=str(Path.home()))
        if not answer:
            answer = "첨부 확인에 실패했습니다 — 파일 형식을 확인해주세요"
        metric("ask_answered", question[:60])
        append_chat(sid, question, answer)
        set_ask_status("")
        print(answer)
        return 0

    set_ask_status("기억 대조 중 — 최근 3일 카드 %d장" % len(lines))
    if tool == "gjc":
        r = subprocess.run([cfg["gjc_bin"], "-p", "--no-session", "--no-tools", full],
                           capture_output=True, text=True,
                           timeout=cfg["distill_timeout_sec"], cwd=str(GARI_HOME))
        answer, rc = r.stdout.strip(), r.returncode
    else:
        answer, rc = run_claude(full, cfg["ask_model"], cfg, "ask")
    if rc != 0 and not answer:
        set_ask_status("")
        print("[가리 응답 실패] 뇌(Claude CLI)가 응답하지 않습니다.", file=sys.stderr)
        print("  → 터미널에서 `claude` 를 한 번 실행해 로그인 상태를 확인하시고,", file=sys.stderr)
        print("  → 전체 진단은 `gari doctor` 로 확인할 수 있습니다.", file=sys.stderr)
        return 1

    if "[깊은사고]" in answer:
        set_ask_status("깊이 생각하는 중… (사고 원전 + 웹 검색 가능)")
        _chat_set_meta(sid, "deep", True)   # 이 세션은 이제 논의 — 후속 질문도 깊게 이어진다
        depth = (TEMPLATES / "thinking-depth.md").read_text(encoding="utf-8")
        # 관련 프로젝트 위키 동봉: 질문에 이름이 걸리는 것 + 최근 활동 상위 (카드보다 종합된 재료)
        wiki_txts, seen_wk = [], set()
        alias = {"review-board": "review-board", "sound-library": "sound-library", "젤리": "jellyfish", "뇌클론": "brain-clone",
                 "브레인클론": "brain-clone", "게임잼": "solo-game"}
        ql = question.lower()
        for wf in sorted(WIKI_DIR.glob("*.md")) if WIKI_DIR.exists() else []:
            stem = wf.stem.lower()
            hit = stem[:6] in ql or any(k in question and v in stem for k, v in alias.items())
            if hit and wf.stem not in seen_wk:
                wiki_txts.append(wf.read_text(encoding="utf-8")[:3000])
                seen_wk.add(wf.stem)
        if not wiki_txts:
            for b in _hud_compass(read_cards(3))[:2]:   # 못 찾으면 최근 활동 상위 2개
                wf = WIKI_DIR / (b["project"] + ".md")
                if wf.exists():
                    wiki_txts.append(wf.read_text(encoding="utf-8")[:2500])
        wiki_block = ("\n\n=== 프로젝트 위키 (현재 상태 종합 — 카드보다 이걸 우선 신뢰) ===\n"
                      + "\n---\n".join(wiki_txts)) if wiki_txts else ""
        deep_prompt = ("%s 너는 \"가리\" — 형님(아이루)의 기획 파트너다. 시니어 프로덕트 리더의 깊이로 논의를 리드하라. "
                       + facts.replace("%", "%%") + "\n"
                       "**형님의 마지막 질문에 첫 문단에서 직답부터 하라** — 직전 논의로 잇는 건 그 다음이다. "
                       "이건 단답이 아니라 **논의**다. 구조: ① 형님 말의 요지 재구성 (한 줄) ② 지금까지의 사실 (카드 인용) "
                       "③ 갈림길 2~3개와 각각의 트레이드오프 ④ 가리의 추천과 근거 (사고 원전 렌즈 1~3개 적용 — 렌즈명은 한글 풀이) "
                       "⑤ 논의를 진전시키는 반문 하나 — 답이 방향을 바꾸는 질문으로. "
                       "길이 제한 없음 — 필요한 만큼 깊게. 다만 형님이 이미 아는 것 반복은 금지. "
                       "최신 정보는 WebSearch로, 코드·문서 사실은 Read/Grep으로 실측할 수 있다. "
                       "출처 정직: '직접 열람했다'는 말은 실제로 Read/Grep 도구를 썼을 때만 하라 — "
                       "기억(카드)에서 아는 것은 '기록상'이라고 말하라. 출처 사칭은 거짓 보고다. "
                       "형님이 \"결정으로 굳혀/기록해/정리해\"라고 하면: 결정 요약을 쓰고 맨 끝에 "
                       "[기록: {\"type\": \"decision\", \"text\": \"<한 줄>\"}] 마커를 결정마다 붙여라 (시스템이 카드로 적재). 호칭 형님.\n\n"
                       "%s\n\n=== 형님의 최근 기록 (카드) ===\n%s\n\n=== 이전 문답 ===\n%s\n\n=== 형님의 질문 ===\n%s") % (
            DISTILL_MARKER, depth, "\n".join(lines[-60:]) or "(없음)",
            hist_txt or "(첫 대화)", question)
        deep_prompt += wiki_block
        if prefs:
            deep_prompt += "\n\n" + prefs
        metric("ask_deep", question[:60])
        answer, rc = run_claude_stream(deep_prompt, cfg["ask_fallback_model"], cfg, "ask-deep",
                                       "Read,Glob,Grep,WebSearch,WebFetch",
                                       timeout=cfg["do_timeout_sec"])
        if not answer:
            answer = "깊은 사고 뇌 호출 실패 — gari status 확인 요망"
    elif "[일반질문]" in answer:
        set_ask_status("일반 지식 답변 중… (웹 검색 가능)")
        gen = ("%s 너는 \"가리\" — 형님(아이루)의 쾌활하고 충성심 있는 솔직한 부하이자 PM이다. "
               "일반 질문이다. 아는 대로 정확히 답하되 모르면 모른다고 하라. 최신 정보가 필요하면 WebSearch로 확인하고 출처를 밝혀라. "
               "결론 먼저, 간결하게. 호칭은 형님.\n"
               "답 끝에, 형님이 놓친 게 보이면 «참견 —» 한 줄을 붙여라 (없으면 생략).\n\n%s\n\n"
               "=== 이전 문답 ===\n%s\n\n=== 형님의 질문 ===\n%s") % (
            DISTILL_MARKER, lenses, hist_txt or "(첫 대화)", question)
        metric("ask_general", question[:60])
        answer, rc = run_claude_stream(gen, cfg["ask_fallback_model"], cfg, "ask-general",
                                       "WebSearch,WebFetch", timeout=cfg["do_timeout_sec"])
        if not answer:
            answer = "일반 답변 뇌 호출에 실패했습니다 — gari status 확인 요망"
    elif ("없습니다" in answer or "없어요" in answer) and "기록" in answer:
        set_ask_status("문서 조사 중…")
        deep = ("%s %s\n\n카드에는 기록이 없었다. **~/gari/store/wiki/ 의 프로젝트 위키를 먼저 보고**, "
                "그다음 ~/gari, ~/roadmap, ~/brain-clone 의 문서를 "
                "Read/Glob/Grep으로 **지금 직접 조사해서** 결과로 답하라 — \"찾아볼까요?\" 같은 되묻기 절대 금지 (조사는 네 권한이다). "
                "화면·기능·사용법 질문이면 소스코드보다 ~/gari/docs/INVENTORY.md와 README.md를 우선 근거로 하라. "
                "답은 제품 언어로만 — 라인번호·git 상태·카드 ID 노출 금지 (형님은 기획자다). 그래도 없으면 어디를 찾아봤는지 밝혀라.\n"
                "=== 형님의 질문 ===\n%s") % (DISTILL_MARKER, persona, question)
        a2, rc2 = run_claude_stream(deep, cfg["ask_model"], cfg, "ask-docs",
                                    "Read,Glob,Grep", timeout=cfg["do_timeout_sec"],
                                    cwd=str(Path.home()))
        if a2:
            answer = "(기록엔 없어서 문서를 뒤졌습니다) " + a2

    # 낡은 기록 정정 마커: [해소: {...}] → 발견 즉시 미결을 근거와 함께 접는다
    for hm in re.finditer(r'\[해소:\s*(\{.*?\})\s*\]', answer, re.S):
        try:
            rec = json.loads(hm.group(1))
        except json.JSONDecodeError:
            continue
        tgt = next((c for c in open_pendings(read_cards_all())
                    if c.get("id") == rec.get("id")), None)
        if tgt and rec.get("evidence"):
            metric("self_correct", tgt["text"][:60])
            append_cards([{"id": hashlib.md5(("자가해소" + tgt["id"]).encode()).hexdigest()[:8],
                           "ts": now_iso(), "tool": "gari-chat", "project": tgt.get("project"),
                           "session": sid, "burst": "self-correct",
                           "type": "decision",
                           "text": "(해소·가리 정정) %s — 근거: %s" % (tgt["text"][:50], rec["evidence"][:80]),
                           "resolves": tgt["id"], "resolves_text": tgt["text"]}])
    answer = re.sub(r'\s*\[해소:[^\]]*\]', '', answer).strip()

    # 논의 결정 마커: [기록: {...}] → 결정/미결 카드로 적재 (논의가 기억이 되는 문)
    for km in re.finditer(r'\[기록:\s*(\{.*?\})\s*\]', answer, re.S):
        try:
            rec = json.loads(km.group(1))
            if rec.get("text") and rec.get("type") in ("decision", "pending"):
                append_cards([{"id": hashlib.md5((sid + rec["text"]).encode()).hexdigest()[:8],
                               "ts": now_iso(), "tool": "gari-chat", "project": "대화",
                               "session": sid, "burst": "discussion-" + sid[:8],
                               "type": rec["type"], "text": rec["text"]}])
        except json.JSONDecodeError:
            pass
    answer = re.sub(r'\s*\[기록:[^\]]*\]', '', answer).strip()

    # 지속 지시 마커: [지시: ...] → prefs.md 저장 → 이후 모든 산출에 반영
    for im in re.finditer(r'\[지시:\s*(.+?)\s*\]', answer):
        note = im.group(1).strip()
        if note:
            with open(PREFS_PATH, "a", encoding="utf-8") as f:
                f.write("- (%s) %s\n" % (datetime.now().strftime("%m/%d"), note))
    answer = re.sub(r'\s*\[지시:[^\]]*\]', '', answer).strip()

    # 파견 제안 마커: [파견: {"task":..,"dir":..,"write":..}] → 세션에 대기 등록, 표시는 사람 문장만
    m = re.search(r'\[파견:\s*(\{.*?\})\s*\]', answer, re.S)
    if m:
        try:
            prop = json.loads(m.group(1))
            if prop.get("task"):
                _chat_set_meta(sid, "pending_dispatch", prop)
                answer = answer.replace(m.group(0), "").strip()
                answer += "\n\n(진행하시려면 \"ㄱㄱ\" 한 마디면 제가 바로 파견합니다)"
        except json.JSONDecodeError:
            pass

    set_ask_status("")
    metric("ask_answered", question[:60])
    append_chat(sid, question, answer)   # 대화 이어짐의 원장
    print(answer)
    return 0


def cmd_do(args):
    """위임 창구 (매니저 최소형): gari do "작업" [--in 경로] [--tool claude|codex] [--write]
    가리가 저장소 맥락을 지시문에 포장해 실무 AI에게 맡기고 결과를 보고한다.
    결과 세션은 다음 스윕에서 자동 적재된다 (자기 기록 루프)."""
    cfg = load_config()
    workdir, tool, write, bg, task_words = None, cfg["do_tool_default"], False, False, []
    i = 0
    while i < len(args):
        if args[i] == "--in":
            i += 1
            workdir = args[i]
        elif args[i] == "--tool":
            i += 1
            tool = args[i]
        elif args[i] == "--write":
            write = True
        elif args[i] == "--bg":
            bg = True
        else:
            task_words.append(args[i])
        i += 1
    task = " ".join(task_words)
    if bg:
        # 백그라운드 파견 — 형님은 기다리지 않는다. 끝나면 알림 + 카드.
        child_args = [str(GARI_HOME / "bin" / "gari"), "do", task]
        if workdir: child_args += ["--in", workdir]
        if tool != cfg["do_tool_default"]: child_args += ["--tool", tool]
        if write: child_args.append("--write")
        log = open(STORE / "do-bg.log", "a")
        subprocess.Popen(child_args, stdout=log, stderr=log, start_new_session=True)
        print("파견했습니다, 형님 — 끝나면 알림으로 보고드립니다. (백그라운드)")
        return 0
    if not task:
        print('사용법: gari do "작업" [--in 프로젝트경로] [--tool claude|codex|gjc] [--write]')
        return 1
    workdir = workdir or os.getcwd()
    cards = read_cards(cfg["briefing_days"])
    ctx = "\n".join("- [%s] %s: %s" % (_proj_short(c), c["type"], c["text"])
                    for c in cards[-40:])
    north_head = ""
    north = Path(cfg["north_star_path"])
    if north.exists():
        north_head = "\n".join(north.read_text(encoding="utf-8").splitlines()[:60])
    prompt = (TEMPLATES / "do-prompt.txt").read_text(encoding="utf-8").format(
        north=north_head, cards=ctx or "(없음)", task=task)
    if tool == "codex":
        cmd = ["codex", "exec", "--skip-git-repo-check", prompt]
    elif tool == "gjc":
        # --no-session: 형님의 gjc 세션 목록·이어하기(-c)를 오염시키지 않는다
        cmd = [cfg["gjc_bin"], "-p", "--no-session"] + \
              ([] if write else ["--no-tools"]) + [prompt]
    else:
        cmd = [cfg["claude_bin"], "-p", prompt]
        cmd += (["--permission-mode", "acceptEdits"] if write
                else ["--allowedTools", "Read,Glob,Grep"])
    print("가리: %s에서 %s에게 맡깁니다%s…" % (workdir, tool,
                                              " (쓰기 허용)" if write else " (읽기 전용)"))
    r = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=cfg["do_timeout_sec"], cwd=workdir)
    out = (r.stdout or "").strip() or (r.stderr or "").strip()
    ok = r.returncode == 0
    # ── 작업 완결 루프: 결과 저장 → 카드 → 알림 (나중에 ask로 회수 가능) ──
    WORKS_DIR = GARI_HOME / "works"
    WORKS_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    work_file = WORKS_DIR / (stamp + ".md")
    work_file.write_text("# 가리 파견 작업 — %s\n\n- 작업: %s\n- 위치: %s · 도구: %s · %s\n- 결과: %s\n\n## 실무자 보고 전문\n\n%s\n"
                         % (stamp, task, workdir, tool,
                            "쓰기 허용" if write else "읽기 전용",
                            "완료" if ok else "실패(rc=%d)" % r.returncode, out),
                         encoding="utf-8")
    summary = out.replace("\n", " ")[:180]
    append_cards([{"id": hashlib.md5((stamp + task).encode()).hexdigest()[:8],
                   "ts": now_iso(), "tool": "gari-do", "project": workdir,
                   "session": "", "burst": "do-" + stamp,
                   "type": "decision",
                   "text": "(가리 작업 %s) %s → %s" % ("완료" if ok else "실패", task[:100], summary),
                   "quote": "", "shadow": False, "resolved": False,
                   "work_file": str(work_file)}])
    notify("가리 — 작업 %s" % ("완료" if ok else "실패"),
           "%s%s" % (task[:70], "" if ok else " (실패 — gari log 확인)"), cfg)
    print(out)
    return 0 if ok else 1


def _hud_chat(cfg):
    sid = CHAT_CURRENT.read_text(encoding="utf-8").strip() if CHAT_CURRENT.exists() else ""
    if not sid or not _chat_path(sid).exists():
        return {"session": "", "title": "새 대화", "thread": [], "sessions": []}
    meta, turns = chat_read(sid)
    return {"session": sid, "title": meta.get("title", "대화"),
            "thread": [{"q": t["q"], "a": t["a"], "ts": (t.get("ts") or "")[11:16]}
                       for t in turns[-10:]],
            "sessions": [{"id": s["id"], "title": s["title"]} for s in chat_sessions()[:8]]}


def _hud_compass(cards):
    """프로젝트 방향판 — 최근 활동 프로젝트의 위키에서 정체·다음 항목 추출 (LLM 없이)."""
    from collections import Counter
    recent = Counter()
    cutoff = (datetime.now().astimezone() - timedelta(days=3)).isoformat()
    for c in cards:
        if c["ts"] >= cutoff and c.get("type") != "snooze":
            name = canonical_project(_proj_short(c))
            if name not in ("?", "대화", "") and name not in NOISE_PROJECTS:
                recent[name] += 1
    board = []
    for name, cnt in recent.most_common(5):
        wf = WIKI_DIR / (name + ".md")
        if not wf.exists():
            continue
        ident, nxt = "", ""
        for line in wf.read_text(encoding="utf-8").splitlines():
            if line.startswith("**정체**:") and not ident:
                ident = line.split(":", 1)[1].strip()
        # '다음' 승격 규칙: 방향의 선행(미정의 빈칸) > 전술(열린 미결)
        txt = wf.read_text(encoding="utf-8")
        for field in ("존재 이유", "성공 기준"):
            if ("**%s" % field) in txt and "미정의" in txt.split("**%s" % field)[1][:120]:
                nxt = "'%s' 정의 필요 — 방향의 선행 조건 (가리가 아침 질문으로 묻습니다)" % field
                break
        if not nxt:
            in_pending = False
            for line in txt.splitlines():
                if line.startswith("**열린 미결**"):
                    in_pending = True
                    continue
                if in_pending and line.startswith("- "):
                    nxt = line[2:].strip()
                    break
                if in_pending and line.startswith("**"):
                    break
        board.append({"project": name, "identity": ident, "next": nxt, "activity": cnt})
    return board


def hud_data(cfg):
    """현황판 데이터 조립 — 텍스트/JSON 두 출력의 단일 원천."""
    h = load_json(HEALTH_PATH, {})
    cards = read_cards(cfg["briefing_days"])
    today = datetime.now().strftime("%Y-%m-%d")
    today_cards = [c for c in cards if c["ts"][:10] == today]
    last = h.get("last_sweep", "")
    age_min = None
    if last:
        try:
            t = datetime.fromisoformat(last)
            age_min = int((datetime.now(t.tzinfo) - t).total_seconds() // 60)
        except ValueError:
            pass
    ns_action, ns_reason = "", ""
    ns = STORE / "next-step.txt"
    if ns.exists():
        for line in ns.read_text(encoding="utf-8").splitlines():
            if line.startswith("한 칸:"):
                ns_action = line[4:].strip()
            elif line.startswith("이유:"):
                ns_reason = line[3:].strip()
    pend = open_pendings(cards)
    dec = [c for c in today_cards
           if c["type"] == "decision" and not c.get("resolves")
           and not c["text"].startswith("(해소)")]
    return {
        "time": datetime.now().strftime("%H:%M"),
        "pipeline": {
            "ok": age_min is not None and age_min < 30,
            "age_min": age_min,
            "cards_today": len(today_cards),
            "cost_today": usage_summary(1)["cost"],
        },
        "next_step": {"action": ns_action, "reason": ns_reason},
        "approvals": load_json(GARI_HOME / "pending-approvals.json", []),
        "pendings": [{"idx": i, "id": c.get("id", ""), "project": _proj_short(c), "text": c["text"],
                       "tool": c.get("tool", ""),
                       "restored": c.get("burst", "").startswith("backfill")}
                     for i, c in enumerate(pend[-cfg["briefing_max_items"]:])],
        "question": (STORE / "question.txt").read_text(encoding="utf-8").strip()
                    if (STORE / "question.txt").exists() else "",
        "chat": _hud_chat(cfg),
        "nag": (STORE / "nag.txt").read_text(encoding="utf-8").strip()
               if (STORE / "nag.txt").exists() else "",
        "mentor": next((l.split(":", 1)[1].strip()
                        for l in (MENTOR_PATH.read_text(encoding="utf-8").splitlines()
                                  if MENTOR_PATH.exists() else [])
                        if l.startswith("오늘의 훈련:")), ""),
        "triage": load_json(TRIAGE_PATH, {}),
        "compass": _hud_compass(cards),
        "freshness": {
            "sweep_interval_min": cfg["sweep_interval_min"],
            "report_hour": cfg["report_hour"],
            "morning_ts": datetime.fromtimestamp((STORE / "next-step.txt").stat().st_mtime).isoformat()
                          if (STORE / "next-step.txt").exists() else "",
            "triage_ts": load_json(TRIAGE_PATH, {}).get("ts", ""),
        },
        "shadow": [{"id": c.get("id", ""), "text": c["text"], "quote": c.get("quote", "")}
                   for c in cards if c.get("shadow") and c.get("id") not in graded_ids(cards)][-5:],
        "decisions": [{"project": _proj_short(c), "text": c["text"]} for c in dec],
        "corrections": [{"text": c["text"]} for c in today_cards if c["type"] == "correction"],
        "wins": [{"text": c["text"]} for c in today_cards if c["type"] == "win"],
    }


def cmd_hud(args):
    """펫 현황판용 통합 뷰. --json = 펫 패널용 구조화 출력, 무인자 = 터미널 열람용 텍스트."""
    cfg = load_config()
    if "--json" in args:
        print(json.dumps(hud_data(cfg), ensure_ascii=False))
        return 0
    h = load_json(HEALTH_PATH, {})
    cards = read_cards(cfg["briefing_days"])
    today = datetime.now().strftime("%Y-%m-%d")
    today_cards = [c for c in cards if c["ts"][:10] == today]

    lines = ["가리 현황판 — %s" % datetime.now().strftime("%m/%d %H:%M")]
    # 상태 한 줄
    last = h.get("last_sweep", "")
    age = ""
    if last:
        try:
            t = datetime.fromisoformat(last)
            age = "%d분 전" % ((datetime.now(t.tzinfo) - t).total_seconds() // 60)
        except ValueError:
            age = "?"
    pipe_ok = age and "분" in age and int(age.split("분")[0]) < 30
    lines.append("파이프라인 %s · 마지막 정리 %s · 오늘 카드 %d장" % (
        "정상" if pipe_ok else "⚠ 점검 필요", age or "(기록 없음)", len(today_cards)))

    def section(title, items, fmt, empty=None):
        lines.append("")
        lines.append("[%s]" % title)
        if not items:
            lines.append("  " + (empty or "(없음)"))
        for it in items:
            lines.append("  " + fmt(it))

    ns = STORE / "next-step.txt"
    lines.append("")
    lines.append("[오늘의 한 칸]")
    lines.append("  " + (ns.read_text(encoding="utf-8").strip().replace("\n", "\n  ")
                         if ns.exists() else "(아침 보고 때 산출됩니다)"))

    approvals = load_json(GARI_HOME / "pending-approvals.json", [])
    section("결재 대기 %d건" % len(approvals), approvals, lambda a: "□ " + a)

    pend = open_pendings(cards)[-8:]
    section("미결 (gari resolve <ID>)", pend,
            lambda c: "(%s) [%s] %s" % (c.get("id", "?"), _proj_short(c), c["text"]))

    dec = [c for c in today_cards
           if c["type"] == "decision" and not c.get("resolves")
           and not c["text"].startswith("(해소)")][-8:]
    section("오늘 결정된 것", dec, lambda c: "· [%s] %s" % (_proj_short(c), c["text"]),
            empty="(아직 없음 — 오늘도 시작입니다)")

    corr = [c for c in today_cards if c["type"] == "correction"][-5:]
    section("형님이 고쳐준 것", corr, lambda c: "· %s" % c["text"])

    wins = [c for c in today_cards if c["type"] == "win"][-3:]
    section("잘 굴러간 것", wins, lambda c: "· %s" % c["text"])

    lines.append("")
    lines.append("─" * 34)
    lines.append("더블클릭=보고 파일 · 우클릭=가리에게 묻기")
    print("\n".join(lines))
    return 0


LAUNCHD_DIR = Path.home() / "Library" / "LaunchAgents"


def write_launchd_plists(cfg):
    """config 기반으로 4개 plist 생성+재로드 — 시각·주기 변경이 실제 스케줄에 반영되는 단일 경로."""
    gari_bin = str(GARI_HOME / "bin" / "gari")
    def plist(label, args_xml, schedule_xml):
        return ("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array>%s</array>
%s  <key>StandardOutPath</key><string>%s/store/launchd-%s.log</string>
  <key>StandardErrorPath</key><string>%s/store/launchd-%s.err.log</string>
</dict>
</plist>
""" % (label, args_xml, schedule_xml, GARI_HOME, label.split(".")[-1], GARI_HOME, label.split(".")[-1]))
    def arg(s):
        return "<string>%s</string>" % s
    jobs = {
        "com.airu.gari-sweep": (arg(gari_bin) + arg("sweep"),
            "  <key>StartInterval</key><integer>%d</integer>\n" % (cfg["sweep_interval_min"] * 60)),
        "com.airu.gari-morning": (arg(gari_bin) + arg("report") + arg("--morning"),
            "  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>0</integer></dict>\n" % cfg["report_hour"]),
        "com.airu.gari-weekly": (arg(gari_bin) + arg("weekly"),
            "  <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>30</integer></dict>\n"),
        "com.airu.gari-pet": (arg(gari_bin) + arg("pet"),
            "  <key>RunAtLoad</key><true/>\n"),
    }
    LAUNCHD_DIR.mkdir(parents=True, exist_ok=True)
    for label, (args_xml, sched) in jobs.items():
        path = LAUNCHD_DIR / (label + ".plist")
        path.write_text(plist(label, args_xml, sched), encoding="utf-8")
        subprocess.run(["launchctl", "unload", str(path)], capture_output=True)
        subprocess.run(["launchctl", "load", str(path)], capture_output=True)
    return list(jobs)


TRIAGE_PATH = STORE / "triage.json"


def run_triage(cfg):
    """미결 큐 자동 검토 — 해소는 절대 직접 하지 않고 근거 딸린 제안만 만든다 (오발 사고 예방)."""
    cards = read_cards_all()
    pends = open_pendings(cards)
    if not pends:
        save_json(TRIAGE_PATH, {"ts": now_iso(), "now": None, "items": []})
        return None
    recent = ["%s [%s/%s] %s: %s" % (c["ts"][:16], c["tool"], _proj_short(c), c["type"], c["text"][:90])
              for c in read_cards(3)[-80:] if c["type"] != "pending"]
    decisions = ["(%s) %s [%s] %s" % (c.get("id", "-"), c["ts"][5:16], _proj_short(c), c["text"][:90])
                 for c in read_cards(7) if c["type"] in ("decision", "correction")][-60:]
    pends_in = pends[-40:]   # 입력 상한 — 트리아지 지연 방지 (나머지는 다음 날 순번)
    plist_txt = "\n".join("(%s) [%s] %s" % (c.get("id", "-"), _proj_short(c), c["text"][:100]) for c in pends_in)
    prompt = ("%s 너는 가리 — 사용자의 미결 큐를 정리하는 사서다. 미결 목록과 최근 활동 기록을 대조해 JSON만 출력하라 (설명 금지):\n"
              '{"now": {"id": "...", "why": "왜 이것부터인지 한 문장"},\n'
              ' "done_like": [{"id": "...", "evidence": "완료로 보이는 근거 — 반드시 기록에서 인용"}],\n'
              ' "dupes": [{"keep": "...", "drop": ["..."], "why": "..."}],\n'
              ' "snooze": [{"id": "...", "days": 7, "why": "지금 결정할 수 없는 이유"}],\n'
              ' "conflicts": [{"ids": ["...", "..."], "why": "서로 어긋나는 지점", "ask": "어느 쪽이 맞는지 묻는 한 문장"}],\n'
              ' "kinds": {"<모든 미결 id>": "direction 또는 work"}}\n'
              "kinds 기준: direction = 방향·우선순위·취향·권한·정책 — 사용자만 정할 수 있는 것. "
              "work = 구현·검증·조사·수정 — AI 에이전트가 파견받아 처리할 수 있는 것.\n"
              "규칙: **서문·설명·사고과정 절대 금지 — JSON 한 덩어리만 출력** (전체 800자 이내 목표). "
              "why/evidence/ask는 각각 한 문장 상한. kinds는 입력된 미결 id에 대해서만. "
              "근거 없는 done_like 금지(확신 없으면 비워라). now는 정확히 1건 — 임팩트와 차단 해제 기준. "
              "dupes는 같은 일을 가리키는 항목만. conflicts는 결정 카드끼리 **서로 모순**되는 쌍만 — "
              "정정(correction) 카드가 이미 덮은 모순, 단순한 계획 변경·진화는 제외. 모르면 빈 배열.\n\n"
              "=== 미결 (%d건 중 최근 40) ===\n%s\n\n=== 최근 결정·정정 (모순 검사용, 7일) ===\n%s\n\n=== 최근 3일 활동 ===\n%s") % (
        DISTILL_MARKER, len(pends), plist_txt, "\n".join(decisions) or "(없음)",
        "\n".join(recent) or "(없음)")
    text, rc = run_claude(prompt, cfg["ask_fallback_model"], cfg, "triage",
                          timeout=cfg["do_timeout_sec"])
    if rc != 0 or not text:
        raise RuntimeError("triage 뇌 호출 실패")
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise RuntimeError("triage 출력 파싱 실패: %s" % text[:120])
    data = json.loads(m.group(0))
    data["ts"] = now_iso()
    valid = {c.get("id") for c in pends} - {None}
    if data.get("now") and data["now"].get("id") not in valid:
        data["now"] = None
    data["done_like"] = [d for d in data.get("done_like", []) if d.get("id") in valid and d.get("evidence")]
    data["snooze"] = [s for s in data.get("snooze", []) if s.get("id") in valid]
    all_ids = {c.get("id") for c in read_cards(7)} - {None}
    data["conflicts"] = [c for c in data.get("conflicts", [])
                         if c.get("ask") and len(c.get("ids", [])) >= 2
                         and all(i in all_ids for i in c["ids"])]
    # 재우기는 가역(기한 후 자동 복귀) — 가리가 직접 실행하고 영수증만 남긴다 (양방향 문)
    pends_by_id = {c["id"]: c for c in pends if c.get("id")}
    slept = []
    for s in data.get("snooze", []):
        c = pends_by_id.get(s.get("id"))
        if not c:
            continue
        days = min(int(s.get("days", 7) or 7), 30)
        until = (datetime.now() + timedelta(days=days)).strftime("%Y-%m-%d")
        append_cards([{"id": hashlib.md5(("snooze" + c["id"] + until).encode()).hexdigest()[:8],
                       "ts": now_iso(), "tool": "gari", "project": c.get("project"),
                       "type": "snooze", "snoozes": c["id"], "until": until,
                       "text": "(가리가 재움 %s까지) %s — %s" % (until, c["text"][:50], s.get("why", "")[:60])}])
        slept.append("%s (%d일: %s)" % (c["text"][:40], days, s.get("why", "")[:40]))
    data["slept"] = slept
    kinds = data.get("kinds") or {}
    data["kinds"] = {k: v for k, v in kinds.items()
                     if k in valid and v in ("direction", "work")}
    save_json(TRIAGE_PATH, data)
    return data


def triage_summary_lines(data, pends_by_id):
    """트리아지 결과 → 사람용 줄들 (보고·브리핑 공용)."""
    if not data:
        return []
    lines = []
    if data.get("now"):
        c = pends_by_id.get(data["now"]["id"])
        if c:
            lines.append("지금 이거 하나: (%s) %s — %s" % (c["id"], c["text"][:70], data["now"].get("why", "")))
    for d in data.get("done_like", []):
        c = pends_by_id.get(d["id"])
        if c:
            lines.append("끝난 듯 (확인 후 `gari resolve %s`): %s — 근거: %s" % (c["id"], c["text"][:50], d["evidence"][:80]))
    for d in data.get("dupes", []):
        drops = ", ".join(d.get("drop", []))
        lines.append("중복: %s 가 대표, %s 는 `gari resolve` 로 접기 — %s" % (d.get("keep"), drops, d.get("why", "")[:60]))
    for s in data.get("slept", []):
        lines.append("재웠습니다 (기한 후 자동 복귀): %s" % s)
    for cf in data.get("conflicts", []):
        lines.append("기록 모순 의심 (%s): %s → %s (답하시면 정정 카드로 덮습니다)" % (
            "·".join(cf.get("ids", [])), cf.get("why", "")[:70], cf.get("ask", "")))
    return lines


def cmd_triage(args):
    """gari triage — 미결 큐 정리 제안 (아침 보고에도 자동 포함)."""
    cfg = load_config()
    try:
        data = run_triage(cfg)
    except (RuntimeError, json.JSONDecodeError) as e:
        print("큐 정리 실패: %s" % e)
        return 1
    if not data:
        print("미결 0건 — 정리할 것이 없습니다.")
        return 0
    pends = {c["id"]: c for c in open_pendings(read_cards_all()) if c.get("id")}
    lines = triage_summary_lines(data, pends)
    print("미결 %d건 검토:" % len(pends))
    for line in lines:
        print(" · " + line)
    if not lines:
        print(" · 정리 제안 없음 — 전부 살아있는 미결")
    return 0


MENTOR_PATH = STORE / "mentor.txt"


NOISE_PROJECTS = {"T", "observer-sessions", "tmp", "user", "spike-t8", "spike-updatedinput"}


def wiki_gaps():
    """위키의 '미정의' 필드들 — 시스템이 스스로 아는 무지. 활동 많은 프로젝트 순."""
    if not WIKI_DIR.exists():
        return []
    order = [b["project"] for b in _hud_compass(read_cards(3))]
    gaps = []
    for wf in WIKI_DIR.glob("*.md"):
        if wf.stem in NOISE_PROJECTS:
            continue
        for line in wf.read_text(encoding="utf-8").splitlines():
            if "미정의" in line and line.startswith("**"):
                field = line.split("**")[1].split("(")[0].strip()
                gaps.append((wf.stem, field))
    gaps.sort(key=lambda g: order.index(g[0]) if g[0] in order else 99)
    return gaps


def compose_mentor_review(cfg):
    """직업 이상향(방법론 원전) 기준으로 어제를 리뷰 — 가리의 멘토 목소리."""
    cards = read_cards(1)
    acted = [c for c in cards if c["type"] in ("decision", "correction", "win", "pending")]
    if len(acted) < 3:
        return ""
    from collections import Counter
    dist = Counter(_proj_short(c) for c in acted)
    dist_txt = ", ".join("%s %d장" % kv for kv in dist.most_common(8))
    lines = ["%s [%s] %s: %s" % (c["ts"][11:16], _proj_short(c), c["type"], c["text"])
             for c in acted[-80:]]
    persona = (TEMPLATES / "mentor-review.txt").read_text(encoding="utf-8")
    depth = (TEMPLATES / "thinking-depth.md").read_text(encoding="utf-8")
    prompt = ("%s %s\n\n=== 방법론 원전 (교과서) ===\n%s\n\n"
              "=== 어제 활동 분포 ===\n%s\n\n=== 어제 활동 (카드) ===\n%s") % (
        DISTILL_MARKER, persona, depth, dist_txt, "\n".join(lines))
    text, rc = run_claude(prompt, cfg["ask_fallback_model"], cfg, "mentor",
                          timeout=cfg["do_timeout_sec"])
    if rc == 0 and text:
        MENTOR_PATH.write_text(text + "\n", encoding="utf-8")
    return text


WIKI_DIR = STORE / "wiki"


def regenerate_wikis(cfg, force=False):
    """카드(사건 일지) → 프로젝트별 현재 상태 위키. 새 카드가 생긴 프로젝트만 다시 쓴다 (증분)."""
    WIKI_DIR.mkdir(exist_ok=True)
    cards = read_cards_all()
    by_proj = {}
    for c in cards:
        if c.get("type") == "snooze":
            continue
        name = canonical_project(_proj_short(c))
        if name in ("?", "대화", ""):
            continue
        by_proj.setdefault(name, []).append(c)
    state = load_json(STORE / "wiki-state.json", {})
    regen, kept = [], 0
    for name, cs in sorted(by_proj.items()):
        if len(cs) < 5:
            continue
        kept += 1
        last_ts = max(c["ts"] for c in cs)
        if not force and state.get(name) == last_ts:
            continue
        lines = ["%s %s: %s" % (c["ts"][5:16], c["type"], c["text"]) for c in cs[-200:]]
        prompt = ("%s 너는 가리 — 프로젝트 위키 사서다. 아래 사건 일지(카드)로 '%s' 프로젝트의 "
                  "**현재 상태 문서**를 작성하라. 규칙: 모순되면 최신·정정(correction)이 이긴다. "
                  "일지에 없는 것 지어내기 금지. 이 문서는 답변 뇌가 읽는다 — 장식 없이 사실만.\n"
                  "너의 출력 텍스트가 곧 문서다 — 파일 저장은 시스템이 한다. 권한·승인·저장 언급 절대 금지, "
                  "'# %s'로 시작하는 마크다운 본문만 출력하라.\n"
                  "형식 (마크다운):\n# %s\n**정체**: 한 줄\n"
                  "**존재 이유 (누가 언제 왜 쓰나)**: 한두 줄 — 일지에 근거가 없으면 정확히 \"미정의 — 카드에 사용자·문제 정의 없음\"이라고 써라\n"
                  "**성공 기준**: 한 줄 — 근거 없으면 \"미정의\"\n"
                  "**현재 상태**: 2~3줄\n"
                  "**유효한 결정** (최신 기준): 목록\n**열린 미결**: 목록\n**최근 흐름**: 3줄 이내\n\n"
                  "=== 사건 일지 (%d장) ===\n%s") % (
            DISTILL_MARKER, name, name, name, len(cs), "\n".join(lines))
        text, rc = run_claude(prompt, cfg["ask_fallback_model"], cfg, "wiki",
                              timeout=cfg["do_timeout_sec"])
        if rc == 0 and text and text.lstrip().startswith("#") and "권한" not in text[:200]:
            (WIKI_DIR / (name + ".md")).write_text(
                text + "\n\n---\n갱신: %s · 근거 카드 %d장\n" % (now_iso()[:16], len(cs)),
                encoding="utf-8")
            state[name] = last_ts
            regen.append(name)
    save_json(STORE / "wiki-state.json", state)
    return regen, kept


def cmd_wiki(args):
    """gari wiki [--all] [프로젝트명] — 프로젝트 위키 갱신/열람."""
    cfg = load_config()
    if args and not args[0].startswith("--"):
        f = WIKI_DIR / (args[0] + ".md")
        if f.exists():
            print(f.read_text(encoding="utf-8"))
            return 0
        print("위키 없음: %s (카드 5장 이상 쌓이면 생성됨)" % args[0])
        return 1
    regen, kept = regenerate_wikis(cfg, force="--all" in args)
    print("위키 갱신: %s (유지 중 %d개, %s)" % (", ".join(regen) or "변경 없음", kept, str(WIKI_DIR)))
    return 0


def cmd_backfill(args):
    """gari backfill [--dry] — 전량 수집 전환(2026-07-06) 이전의 과거 대화 소급 증류.
    개인 프로젝트(구 수집 범위)는 그간 정상 수집됐으므로 제외 — 나머지(회사 등)를 처음부터."""
    cfg = load_config()
    dry = "--dry" in args
    excl = set()
    for i, a in enumerate(args):
        if a == "--exclude" and i + 1 < len(args):
            excl = {x.strip() for x in args[i + 1].split(",") if x.strip()}
    cursors = load_json(CURSORS_PATH, {})
    old_allow = cfg.get("allowlist_paths", [])

    def in_old(cwd):
        cwd = str(cwd or "")
        return any(cwd == p or cwd.startswith(p.rstrip("/") + "/") for p in old_allow)

    targets = []
    for tool, path in find_session_files(cfg):
        meta = (cursors.get(str(path), {}) or {}).get("meta") or {}
        if not meta:
            try:
                meta = peek_meta(tool, path)
            except Exception:
                meta = {}
        cwd = meta.get("cwd", "")
        if in_old(cwd):
            continue
        try:
            size = path.stat().st_size
        except OSError:
            continue
        if size == 0:
            continue
        if Path(str(cwd or "?")).name in excl:
            continue
        targets.append((tool, path, cwd or "?", size))

    from collections import Counter
    by_proj = Counter()
    for tool, path, cwd, size in targets:
        by_proj[Path(str(cwd)).name or "?"] += size
    print("소급 대상: 파일 %d개, %.1fMB" % (len(targets), sum(t[3] for t in targets) / 1e6))
    for name, b in by_proj.most_common(12):
        print("  %-24s %.1fMB" % (name, b / 1e6))
    if dry:
        return 0

    cap = cfg["max_distill_chars"]
    done_files, made, t0 = 0, 0, time.time()
    for tool, path, cwd, size in targets:
        _fn = SOURCES[tool][1]
        try:
            turns, new_off, _m, _sk = _fn(path, 0)
        except Exception as e:
            print("  ! 추출 실패 %s: %s" % (path.name[:24], str(e)[:80]))
            continue
        key = str(path)
        if any(DISTILL_MARKER in (t[1] or "") or "[GARI-DO]" in (t[1] or "") for t in turns[:2]) \
           or not [t for t in turns if t[0] == "user"]:
            cursors[key] = {"offset": size, "meta": {"cwd": cwd}}
            save_json(CURSORS_PATH, cursors)
            continue
        # 상한 안쪽으로 조각내서 손실 없이 증류
        chunk, acc, ci = [], 0, 0
        def flush(chunk_turns, idx):
            burst_id = "backfill-%s-%d" % (path.stem[:8], idx)
            try:
                cards = distill(chunk_turns, tool, cwd, path.stem[:12], burst_id, cfg)
            except Exception as e:
                print("  ! 증류 실패 %s#%d: %s" % (path.name[:20], idx, str(e)[:80]))
                return 0
            append_cards(cards)
            return len(cards)
        for t in turns:
            chunk.append(t)
            acc += len(t[1] or "")
            if acc >= cap * 0.8:
                made += flush(chunk, ci)
                ci += 1
                chunk, acc = [], 0
        if chunk:
            made += flush(chunk, ci)
        cursors[key] = {"offset": size, "meta": {"cwd": cwd}}
        save_json(CURSORS_PATH, cursors)   # 파일 단위 저장 — 끊겨도 이어서
        done_files += 1
        print("  ✓ [%d/%d] %s (%s) — 누적 카드 %d" % (
            done_files, len(targets), path.name[:22], Path(str(cwd)).name, made), flush=True)
    mins = (time.time() - t0) / 60
    notify("가리 — 소급 완료", "세션 %d개에서 카드 %d장 (%.0f분)" % (done_files, made, mins), cfg)
    print("소급 완료: 파일 %d, 카드 %d장, %.0f분" % (done_files, made, mins))
    return 0


def cmd_doctor(args):
    """가리 전제조건·건강 진단 — 첫 세팅과 '뭔가 이상할 때'의 시작점."""
    cfg = load_config()
    ok_all = True
    def check(name, ok, hint="", warn=False):
        nonlocal ok_all
        mark = "✓" if ok else ("△" if warn else "✗")
        if not ok and not warn:
            ok_all = False
        print(" %s %s%s" % (mark, name, ("  → " + hint) if (hint and not ok) else ""))

    print("가리 진단 — %s" % datetime.now().strftime("%m/%d %H:%M"))
    print("[필수]")
    cb = cfg.get("claude_bin", "")
    check("Claude CLI 존재 (%s)" % cb, bool(cb) and Path(cb).exists(),
          "https://claude.com/claude-code 설치 후 다시")
    if "--fast" in args:
        print(" — 실호출 검사 생략 (--fast). 전체 검사: gari doctor")
    elif Path(cb).exists() if cb else False:
        set_ask_status("")
        txt, rc = run_claude("pong 이라고만 답해", cfg["ask_model"], cfg, "doctor", timeout=60)
        check("Claude 로그인·응답 (실호출)", rc == 0 and bool(txt),
              "터미널에서 `claude` 실행 → 로그인 진행")
    check("본체 저장소 쓰기 가능", os.access(STORE, os.W_OK), "~/gari/store 권한 확인")
    print("[예약 실행]")
    loaded = subprocess.run(["launchctl", "list"], capture_output=True, text=True).stdout
    for job in ("gari-sweep", "gari-morning", "gari-weekly", "gari-pet"):
        check("launchd %s" % job, job in loaded, "`gari init` 재실행으로 등록")
    print("[연결]")
    try:
        s = json.load(open(Path.home() / ".claude" / "settings.json"))
        hooks_txt = json.dumps(s.get("hooks", {}))
        check("Claude 훅 (수집·브리핑)", "gari" in hooks_txt, "`gari init` 재실행으로 등록")
    except (OSError, json.JSONDecodeError):
        check("Claude 훅 (수집·브리핑)", False, "~/.claude/settings.json 확인")
    check("Codex 연결 (선택)", shutil.which("codex") is not None, "", warn=True)
    check("gjc 연결 (선택)", Path(cfg.get("gjc_bin", "/nonexistent")).exists(), "", warn=True)
    check("Gari.app (Spotlight 깨우기)", Path("/Applications/Gari.app").exists(),
          "README '펫이 안 보이면' 참조", warn=True)
    print("[가동 상태]")
    h = load_json(HEALTH_PATH, {})
    last = h.get("last_sweep", "")
    fresh = False
    if last:
        try:
            fresh = (datetime.now(datetime.fromisoformat(last).tzinfo)
                     - datetime.fromisoformat(last)).total_seconds() < 30 * 60
        except ValueError:
            pass
    check("최근 30분 내 스윕", fresh, "`gari done` 으로 수동 1회 후 재확인", warn=True)
    print("결론: %s" % ("정상 — 가리 가동 가능" if ok_all else "필수 항목 실패 — 위 화살표 조치 후 gari doctor 재실행"))
    return 0 if ok_all else 1


def cmd_init(args):
    """온보딩: gari init [--honorific 님] [--name 이름] [--hour 9] [--add-path 경로 ...] [--yes]
    묻고 → config 갱신 → 훅·launchd·펫 등록 → 진단. 몇 번을 다시 돌려도 안전(멱등)."""
    cfg = load_config()
    opts = {"honorific": None, "name": None, "hour": None, "paths": [], "yes": False}
    i = 0
    while i < len(args):
        if args[i] == "--honorific":
            i += 1
            opts["honorific"] = args[i]
        elif args[i] == "--name":
            i += 1
            opts["name"] = args[i]
        elif args[i] == "--hour":
            i += 1
            opts["hour"] = int(args[i])
        elif args[i] == "--add-path":
            i += 1
            opts["paths"].append(str(Path(args[i]).expanduser().resolve()))
        elif args[i] == "--yes":
            opts["yes"] = True
        i += 1

    interactive = sys.stdin.isatty() and not opts["yes"]
    def ask_input(q, default):
        if not interactive:
            return default
        v = input("%s [%s]: " % (q, default)).strip()
        return v or default

    cfg["honorific"] = opts["honorific"] or ask_input("가리가 뭐라고 부를까요", cfg.get("honorific", "형님"))
    cfg["user_name"] = opts["name"] or ask_input("이름(페르소나용)", cfg.get("user_name", "아이루"))
    cfg["report_hour"] = opts["hour"] or int(ask_input("아침 보고 시각(시)", cfg.get("report_hour", 9)))
    for p in opts["paths"]:
        if p not in cfg["allowlist_paths"]:
            cfg["allowlist_paths"].append(p)
    if interactive and not opts["paths"]:
        extra = input("수집할 프로젝트 폴더 추가(쉼표 구분, 없으면 엔터): ").strip()
        for p in [x.strip() for x in extra.split(",") if x.strip()]:
            rp = str(Path(p).expanduser().resolve())
            if rp not in cfg["allowlist_paths"]:
                cfg["allowlist_paths"].append(rp)
    save_json(CONFIG_PATH, cfg)
    print("① 설정 저장 — 호칭 '%s', 보고 %d시, 수집 폴더 %d개" % (
        cfg["honorific"], cfg["report_hour"], len(cfg["allowlist_paths"])))

    # 훅 스크립트 재생성 ($HOME 기반 — 기기 이식성)
    hooks_dir = GARI_HOME / "hooks"
    hooks_dir.mkdir(exist_ok=True)
    for name, body in {
        "claude-stop.sh": 'exec "$HOME/gari/bin/gari" enqueue >/dev/null 2>>"$HOME/gari/store/hook.err.log"',
        "claude-sessionstart.sh": 'exec "$HOME/gari/bin/gari" brief 2>>"$HOME/gari/store/hook.err.log"',
        "codex-stop.sh": 'exec "$HOME/gari/bin/gari" enqueue >/dev/null 2>>"$HOME/gari/store/hook.err.log"',
    }.items():
        sp = hooks_dir / name
        sp.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        sp.chmod(0o755)

    # Claude 훅 등록 (멱등 — 이미 있으면 건너뜀, 백업 후 병합)
    sj = Path.home() / ".claude" / "settings.json"
    try:
        s = json.load(open(sj)) if sj.exists() else {}
        hooks_txt = json.dumps(s.get("hooks", {}))
        if "gari" not in hooks_txt:
            shutil.copy(sj, str(sj) + ".bak-gari-init")
            hooks = s.setdefault("hooks", {})
            hooks.setdefault("SessionStart", [{"hooks": []}])[0].setdefault("hooks", []).append(
                {"type": "command", "command": "$HOME/gari/hooks/claude-sessionstart.sh", "timeout": 10})
            hooks.setdefault("Stop", [{"hooks": []}])[0].setdefault("hooks", []).append(
                {"type": "command", "command": "$HOME/gari/hooks/claude-stop.sh", "timeout": 10, "async": True})
            json.dump(s, open(sj, "w"), ensure_ascii=False, indent=2)
            print("② Claude 훅 등록 (기존 설정은 .bak-gari-init 백업)")
        else:
            print("② Claude 훅 — 이미 등록됨 (건너뜀)")
    except (OSError, json.JSONDecodeError) as e:
        print("② Claude 훅 등록 실패: %s — 수동 확인 필요" % e)

    # Codex 훅 (있으면, 멱등)
    cj = Path.home() / ".codex" / "hooks.json"
    if cj.exists():
        try:
            c = json.load(open(cj))
            if "gari" not in json.dumps(c):
                stop = c.setdefault("hooks", {}).setdefault("Stop", [])
                stop.append({"hooks": [{"type": "command",
                                        "command": str(hooks_dir / "codex-stop.sh")}]})
                json.dump(c, open(cj, "w"), ensure_ascii=False, indent=2)
                print("③ Codex 훅 등록")
            else:
                print("③ Codex 훅 — 이미 등록됨")
        except (OSError, json.JSONDecodeError):
            print("③ Codex 훅 — hooks.json 파싱 실패, 건너뜀")
    else:
        print("③ Codex 미설치 — 건너뜀 (선택 사항)")

    jobs = write_launchd_plists(cfg)
    print("④ 예약 실행 %d개 등록 (스윕 %d분·보고 %d시·주간 월 9:30·펫 로그인)" % (
        len(jobs), cfg["sweep_interval_min"], cfg["report_hour"]))
    print("⑤ 진단:")
    return cmd_doctor([])


def cmd_pet(args):
    if args and args[0] == "color":
        pc_path = GARI_HOME / "pet" / "pet-config.json"
        pc = load_json(pc_path, {})
        if len(args) > 1 and args[1] == "reset":
            for k in ("body_color", "shade_color", "belly_color"):
                pc.pop(k, None)
            save_json(pc_path, pc)
            print("팔레트 초기화 — 가리발디 주황으로 복귀")
        elif len(args) > 1 and re.fullmatch(r"#?[0-9a-fA-F]{6}", args[1]):
            pc["body_color"] = "#" + args[1].lstrip("#")
            save_json(pc_path, pc)
            print("몸 색 변경: %s (음영·배는 자동 파생)" % pc["body_color"])
        else:
            print("사용법: gari pet color <#RRGGBB|reset>")
            return 1
        subprocess.run(["pkill", "-f", "gari-pet"], capture_output=True)
        subprocess.run(["pkill", "-f", "MacOS/gari"], capture_output=True)
        time.sleep(0.5)
        args = []   # 아래 기본 켜기 로직으로 재기동

    """펫(보이는 몸) 켜고 끄기: gari pet / gari pet off"""
    binpath = GARI_HOME / "pet" / "gari-pet"
    if args and args[0] == "off":
        r = subprocess.run(["pkill", "-f", "gari-pet"])
        print("펫 종료" if r.returncode == 0 else "펫이 떠 있지 않았습니다 (본체는 계속 돕니다)")
        return 0
    if subprocess.run(["pgrep", "-f", "gari-pet"], capture_output=True).returncode == 0:
        print("펫은 이미 떠 있습니다. 안 보이면 다른 모니터/스페이스 확인 — 끄려면: gari pet off")
        return 0
    if not binpath.exists():
        print("펫 실행 파일이 없습니다 — 빌드: cd ~/gari/pet && clang -fobjc-arc -framework Cocoa -O2 -o gari-pet GariPet.m")
        return 1
    log = open(GARI_HOME / "pet" / "pet.log", "a")
    subprocess.Popen([str(binpath)], stdout=log, stderr=log,
                     start_new_session=True)
    print("펫 등장 — 클릭=현황판, 더블클릭=보고 파일, 드래그=이동, 우클릭=메뉴")
    return 0


def main():
    cmds = {
        "sweep": cmd_sweep, "report": cmd_report, "brief": cmd_brief,
        "status": cmd_status, "enqueue": cmd_enqueue, "done": cmd_done,
        "resolve": cmd_resolve, "log": cmd_log,
        "ask": cmd_ask, "do": cmd_do, "pet": cmd_pet, "hud": cmd_hud, "weekly": cmd_weekly, "grade": cmd_grade, "chat": cmd_chat, "cost": cmd_cost, "doctor": cmd_doctor, "init": cmd_init, "wiki": cmd_wiki, "triage": cmd_triage, "snooze": cmd_snooze, "backfill": cmd_backfill,
    }
    args = sys.argv[1:]
    if not args or args[0] not in cmds:
        # 기본: 최신 보고 열람 (형님의 창구)
        latest = sorted(REPORTS_DIR.glob("*.md"))
        if latest:
            print(latest[-1].read_text(encoding="utf-8"))
            return 0
        print("가리입니다, 형님. 아직 보고서가 없습니다.")
        print('명령: ask "질문" / do "작업" / sweep / report / brief / status / done / resolve / log')
        return 0
    return cmds[args[0]](args[1:])


if __name__ == "__main__":
    sys.exit(main())
