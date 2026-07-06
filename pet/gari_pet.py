#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""GariPet — 가리의 몸. 화면에 상주하는 픽셀 펫 (CodexPet 문법, tkinter판).

원칙: 표시하는 모든 상태는 실제 상태다 — 자는 모습 = 가리가 진짜 유휴라는 뜻.
본체와 분리: 이 앱이 죽어도 가리(수집·증류·보고)는 무사하다.
알려진 한계: tkinter 창은 데스크톱 스페이스 1곳에 고정 (전 스페이스 상주는 Swift판 승격 때).
"""
import json
import subprocess
import time
from datetime import datetime
from pathlib import Path
import tkinter as tk

GARI = Path.home() / "gari"
STORE = GARI / "store"
PET = GARI / "pet"
CELL = 6           # 픽셀 한 칸 px
POLL_MS = 5000     # 상태 읽기 주기
TICK_MS = 800      # 애니메이션 프레임

# 문자 → 색: .=투명 B=몸 D=그늘 W=흰자 K=눈동자 M=입 Z=포인트 R=경고
PALETTE = {
    "B": "#383838", "D": "#262626", "W": "#f7f7f7", "K": "#0d0d0d",
    "M": "#f28c8c", "Z": "#59d9b8", "R": "#e65a4d",
}

SPRITES = {
    "sleep": [
        ".....BBBBB.....",
        "...BBBBBBBBB...",
        "..BBBBBBBBBBB..",
        ".BBBBBBBBBBBBB.",
        ".BBB..BBB..BBB.",
        ".BBBBBBBBBBBBB.",
        ".BBBBB.M.BBBBB.",
        "..BBBBBBBBBBB..",
        "...BBBBBBBBB...",
        "....DD...DD....",
    ],
    "awake": [
        ".....BBBBB.....",
        "...BBBBBBBBB...",
        "..BBBBBBBBBBB..",
        ".BBBWWBBBWWBBB.",
        ".BBBWKBBBWKBBB.",
        ".BBBBBBBBBBBBB.",
        ".BBBBB.M.BBBBB.",
        "..BBBBBBBBBBB..",
        "...BBBBBBBBB...",
        "....DD...DD....",
    ],
    "work": [
        ".Z...BBBBB...Z.",
        ".ZB.BBBBBBB.BZ.",
        "..BBBBBBBBBBB..",
        ".BBBWWBBBWWBBB.",
        ".BBBWKBBBWKBBB.",
        ".BBBBBBBBBBBBB.",
        ".BBBB.MMM.BBBB.",
        "..BBBBBBBBBBB..",
        "...BBBBBBBBB...",
        "....DD...DD....",
    ],
    "alert": [
        ".....RRRRR.....",
        "...RRRRRRRRR...",
        "..RRRRRRRRRRR..",
        ".RRRWWRRRWWRRR.",
        ".RRRWKRRRWKRRR.",
        ".RRRRRRRRRRRRR.",
        ".RRRR.MMM.RRRR.",
        "..RRRRRRRRRRR..",
        "...RRRRRRRRR...",
        "....DD...DD....",
    ],
}


def read_state():
    """가리의 실제 상태 → (mood, badge). 전부 로컬 파일 읽기 — 네트워크·프로세스 없음."""
    mood, badge = "sleep", 0
    # 스윕 심박: 30분 넘게 침묵이면 이상 (스윕 주기 10분의 3배)
    stale = True
    try:
        h = json.loads((STORE / "health.json").read_text())
        last = h.get("last_sweep", "")
        if last:
            t = datetime.fromisoformat(last)
            if (datetime.now(t.tzinfo) - t).total_seconds() < 30 * 60:
                stale = False
    except (OSError, ValueError):
        pass
    try:
        badge += len(json.loads((GARI / "pending-approvals.json").read_text()))
    except (OSError, ValueError):
        pass
    today = datetime.now().strftime("%Y-%m-%d")
    if (GARI / "reports" / (today + ".md")).exists() and not (PET / ("seen-" + today)).exists():
        badge += 1
    if stale:
        mood = "alert"
    elif (STORE / "sweep.lock").exists():
        mood = "work"
    elif badge > 0:
        mood = "awake"
    return mood, badge


class GariPet:
    def __init__(self):
        self.root = tk.Tk()
        self.root.overrideredirect(True)          # 테두리 없음
        self.root.wm_attributes("-topmost", True) # 항상 위 (코덱스펫 문법)
        w, h = 15 * CELL + 30, 10 * CELL + 44
        # 위치 복원 (기본: 우하단)
        x = self.root.winfo_screenwidth() - w - 40
        y = self.root.winfo_screenheight() - h - 90
        try:
            p = json.loads((PET / "position.json").read_text())
            x, y = int(p["x"]), int(p["y"])
        except (OSError, ValueError, KeyError):
            pass
        self.root.geometry("%dx%d+%d+%d" % (w, h, x, y))
        # 투명 배경 (macOS)
        try:
            self.root.wm_attributes("-transparent", True)
            bg = "systemTransparent"
            self.root.config(bg=bg)
        except tk.TclError:
            bg = "#1e1e1e"  # 투명 미지원 시 어두운 카드로 (fail-loud하게 티가 남)
        self.canvas = tk.Canvas(self.root, width=w, height=h, bg=bg,
                                highlightthickness=0)
        self.canvas.pack()
        self.mood, self.badge = "sleep", 0
        self.tick = 0
        self.drag = None
        self.moved = False
        self.canvas.bind("<ButtonPress-1>", self.on_press)
        self.canvas.bind("<B1-Motion>", self.on_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_release)
        for ev in ("<Button-2>", "<Button-3>", "<Control-Button-1>"):
            self.canvas.bind(ev, self.on_menu)
        self.poll()
        self.animate()

    # ---------------- 상태·애니메이션
    def poll(self):
        self.mood, self.badge = read_state()
        self.draw()
        self.root.after(POLL_MS, self.poll)

    def animate(self):
        self.tick += 1
        self.draw()
        self.root.after(TICK_MS, self.animate)

    def draw(self):
        c = self.canvas
        c.delete("all")
        rows = SPRITES[self.mood]
        cols = len(rows[0])
        ox = (int(c["width"]) - cols * CELL) // 2
        oy = 26
        squash = 1 if (self.mood == "sleep" and self.tick % 2 == 0) else 0
        for r, row in enumerate(rows):
            for col, ch in enumerate(row):
                color = PALETTE.get(ch)
                if not color:
                    continue
                y0 = oy + r * CELL + (squash if r < 3 else 0)
                c.create_rectangle(ox + col * CELL, y0,
                                   ox + (col + 1) * CELL, y0 + CELL,
                                   fill=color, width=0)
        if self.mood == "sleep" and self.tick % 4 < 2:
            c.create_text(ox + cols * CELL - 4, oy - 10,
                          text="z" * (1 + self.tick % 2), fill="#8a8a8a",
                          font=("Menlo", 12, "bold"))
        if self.badge:
            bx, by = ox + cols * CELL - 2, oy + 2
            c.create_oval(bx - 8, by - 8, bx + 8, by + 8, fill="#e65a4d", width=0)
            c.create_text(bx, by, text=str(min(self.badge, 9)), fill="white",
                          font=("Helvetica", 10, "bold"))

    # ---------------- 입력
    def on_press(self, e):
        self.drag = (e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y())
        self.moved = False

    def on_drag(self, e):
        if not self.drag:
            return
        nx, ny = e.x_root - self.drag[0], e.y_root - self.drag[1]
        if abs(nx - self.root.winfo_x()) + abs(ny - self.root.winfo_y()) > 2:
            self.moved = True
        self.root.geometry("+%d+%d" % (nx, ny))

    def on_release(self, e):
        if self.moved:
            PET.mkdir(exist_ok=True)
            (PET / "position.json").write_text(json.dumps(
                {"x": self.root.winfo_x(), "y": self.root.winfo_y()}))
        else:
            self.open_report()
        self.drag = None

    def on_menu(self, e):
        m = tk.Menu(self.root, tearoff=0)
        m.add_command(label="보고 열기", command=self.open_report)
        m.add_command(label="상태 확인 (gari status)", command=self.open_status)
        m.add_separator()
        m.add_command(label="가리 펫 종료 (본체는 계속 돎)", command=self.root.destroy)
        m.tk_popup(e.x_root, e.y_root)

    def open_report(self):
        today = datetime.now().strftime("%Y-%m-%d")
        PET.mkdir(exist_ok=True)
        (PET / ("seen-" + today)).touch()   # 배지 해제는 실제로 연 순간에만
        report = GARI / "reports" / (today + ".md")
        if not report.exists():
            mds = sorted((GARI / "reports").glob("*.md"))
            if mds:
                report = mds[-1]
        subprocess.Popen(["open", str(report)])
        self.mood, self.badge = read_state()
        self.draw()

    def open_status(self):
        out = PET / "status-snapshot.txt"
        subprocess.Popen(["/bin/sh", "-c",
                          "%s status > %s 2>&1; open -e %s" %
                          (GARI / "bin" / "gari", out, out)])


if __name__ == "__main__":
    GariPet().root.mainloop()
