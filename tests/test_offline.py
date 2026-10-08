#!/usr/bin/env python3
"""Offline tests — no model calls, no network, no real user data.

They guard the contracts that break silently:
- personalization tokens are filled everywhere
- model-output markers and their parsers stay in sync (English + legacy Korean)
- the north-star metric counts only real handoffs
- hooks find GARI_HOME from their own location

Run: python3 tests/test_offline.py
"""
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TMP = Path(tempfile.mkdtemp(prefix="gari-test-"))
HOME = TMP / "gari"
shutil.copytree(REPO / "templates", HOME / "templates")
(HOME / "store").mkdir(parents=True)
cfg = json.loads((REPO / "config.example.json").read_text(encoding="utf-8"))
cfg.update({"notify": False, "claude_bin": "/nonexistent/claude", "user_name": "Ada"})
(HOME / "config.json").write_text(json.dumps(cfg), encoding="utf-8")
os.environ["GARI_HOME"] = str(HOME)
os.environ.pop("ANTHROPIC_API_KEY", None)
sys.path.insert(0, str(REPO))
import gari as g  # noqa: E402

HANGUL = re.compile("[\uac00-\ud7a3]")


def fake_brain(answer):
    def _brain(prompt, model, cfg, kind, **kw):
        return answer, 0, "claude"
    return _brain


def ask(question, answer):
    """Run cmd_ask with a canned model answer; return what Gari printed."""
    g.run_brain = fake_brain(answer)
    g.judge_nag = lambda q, a, c: a
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = g.cmd_ask(["--new", question])
    assert rc == 0, rc
    return out.getvalue().strip()


class Personalization(unittest.TestCase):
    def test_tokens(self):
        c = g.load_config()
        self.assertEqual(g.personalize("{{USER}}|{{LANG}}", c), "Ada|English")
        self.assertEqual(g.personalize("{{ADDRESS_RULE}}", c), "")
        c2 = dict(c, honorific="boss")
        self.assertIn('"boss"', g.personalize("{{ADDRESS_RULE}}", c2))

    def test_no_leftover_tokens_or_korean_in_templates(self):
        c = g.load_config()
        for f in (HOME / "templates").iterdir():
            text = g.personalize(f.read_text(encoding="utf-8"), c)
            self.assertNotIn("{{", text, f.name)
            self.assertIsNone(HANGUL.search(text), f.name)

    def test_format_templates_survive_braces_in_names(self):
        c = dict(g.load_config(), user_name="A{x}")
        t = g.personalize_for_format((HOME / "templates" / "do-prompt.txt").read_text(), c)
        out = t.format(north="N", cards="C", task="T")
        self.assertIn("A{x}", out)


class Markers(unittest.TestCase):
    def test_directive_saved_and_hidden(self):
        shown = ask("from now on reply shorter", "Got it.\n[DIRECTIVE: reply in under 3 sentences]")
        self.assertNotIn("DIRECTIVE", shown)
        self.assertIn("reply in under 3 sentences", g.PREFS_PATH.read_text(encoding="utf-8"))

    def test_record_becomes_card(self):
        shown = ask("lock it in", 'Done.\n[RECORD: {"type": "decision", "text": "Ship on Friday"}]')
        self.assertNotIn("RECORD", shown)
        self.assertTrue(any(c["text"] == "Ship on Friday" for c in g.read_cards_all()))

    def test_delegate_parked_for_approval(self):
        shown = ask("add a readme", 'Shall I delegate this? — add a readme\n'
                    '[DELEGATE: {"task": "add a readme", "dir": "/tmp", "write": true}]')
        self.assertNotIn("[DELEGATE", shown)
        self.assertIn('say "go"', shown)

    def test_legacy_korean_markers_still_parsed(self):
        shown = ask("old style", "OK\n[지시: legacy rule works]")
        self.assertNotIn("지시", shown)
        self.assertIn("legacy rule works", g.PREFS_PATH.read_text(encoding="utf-8"))

    def test_no_record_answer_logs_a_miss(self):
        before = len(g.read_misses(7)) if hasattr(g, "read_misses") else 0
        g.run_claude_stream = lambda *a, **k: ("", 1)   # doc search finds nothing
        ask("what did I decide about X?", "There's no record of that.")
        self.assertGreater(len(g.read_misses(7)), before)

    def test_next_step_parser(self):
        g.run_claude = lambda *a, **k: ("Next step: write tests\nWhy: safety\n"
                                        "Question: which first?\nNudge: no metric yet", 0)
        g.compose_next_step([], g.load_config())
        self.assertEqual((g.STORE / "question.txt").read_text().strip(), "which first?")
        self.assertEqual((g.STORE / "nag.txt").read_text().strip(), "no metric yet")


class NorthStar(unittest.TestCase):
    def test_brief_served_counts_serving_not_rebuilding(self):
        c = g.load_config()
        g.rebuild_briefing(c)
        n0 = g.metrics_summary(1).get("brief_served", 0)
        g.rebuild_briefing(c)
        self.assertEqual(g.metrics_summary(1).get("brief_served", 0), n0)
        with contextlib.redirect_stdout(io.StringIO()):
            g.cmd_brief([])
        self.assertEqual(g.metrics_summary(1).get("brief_served", 0), n0 + 1)

    def test_northstar_command_reports_both_metrics(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(g.cmd_northstar([]), 0)
        self.assertIn("Re-explanations", out.getvalue())
        self.assertIn("Context handoffs", out.getvalue())


class Hooks(unittest.TestCase):
    def test_hook_resolves_home_from_its_location(self):
        root = TMP / "hookcheck"
        (root / "hooks").mkdir(parents=True)
        (root / "bin").mkdir()
        (root / "store").mkdir()
        shutil.copy(REPO / "hooks" / "claude-sessionstart.sh", root / "hooks")
        (root / "bin" / "gari").write_text('#!/bin/sh\necho "ran $1"\n')
        (root / "bin" / "gari").chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k not in ("GARI_HOME", "GARI_INTERNAL")}
        r = subprocess.run(["sh", str(root / "hooks" / "claude-sessionstart.sh")],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.stdout.strip(), "ran brief")
        r = subprocess.run(["sh", str(root / "hooks" / "claude-sessionstart.sh")],
                           capture_output=True, text=True, env=dict(env, GARI_INTERNAL="1"))
        self.assertEqual(r.stdout.strip(), "")


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
