#!/usr/bin/env python3
"""
Test Suite 8c: i3 configuration grammar lint.

The live ISO only proves that `i3` *starts*; i3 happily runs with directives it
could not parse (it raises an `i3-nagbar` instead) and with binding commands that
fail silently when the key is pressed. This suite pins the grammar contract by
running `scripts/lint-i3-config.py` over the vendored config and by feeding it
deliberately broken configs, so the linter cannot rot into a no-op.

Covered regressions:
  * `kill focused window` — `kill` only accepts `[window|client]`,
  * `smart_borders` combined with `hide_edge_borders` (deprecated + ignored),
  * `workspace_layout splitv`-style values that do not exist,
  * `layout toggle` token lists,
  * duplicate bindings, unknown modifiers, wrong colour arity, bad bar modes.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONFIG = REPO_ROOT / "archiso/airootfs/usr/share/anitails/i3/Configs/.config/i3/config"
LINTER = REPO_ROOT / "scripts/lint-i3-config.py"


def _load_linter():
    spec = importlib.util.spec_from_file_location("lint_i3_config", LINTER)
    assert spec and spec.loader, f"cannot import {LINTER}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestVendoredI3Config(unittest.TestCase):
    """The shipped AniTails i3 config must be grammar-clean."""

    def test_vendored_config_has_no_grammar_problems(self) -> None:
        problems = _load_linter().lint(CONFIG.read_text(encoding="utf-8"))
        self.assertEqual(problems, [], f"i3 config errors: {problems}")

    def test_linter_cli_exits_zero(self) -> None:
        result = subprocess.run([sys.executable, str(LINTER), "--config", str(CONFIG)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: i3 config is valid", result.stdout)

    def test_kill_binding_has_no_legacy_target(self) -> None:
        text = CONFIG.read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("kill focused window", code)
        self.assertRegex(code, r"(?m)^bindsym .*\bkill\s*$")

    def test_edge_borders_do_not_use_deprecated_smart_borders(self) -> None:
        text = CONFIG.read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        self.assertRegex(code, r"(?m)^hide_edge_borders smart(_no_gaps)?$")
        self.assertNotRegex(code, r"(?m)^smart_borders\b")

    def test_workspace_layout_is_a_real_value(self) -> None:
        text = CONFIG.read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        match = __import__("re").search(r"(?m)^workspace_layout (\S+)$", code)
        self.assertIsNotNone(match, "workspace_layout directive missing")
        self.assertIn(match.group(1), {"default", "stacking", "stacked", "tabbed"})


class TestLinterCatchesRegressions(unittest.TestCase):
    """Deliberately broken configs must be rejected — otherwise the lint is fake."""

    MOD_PRELUDE = "set $mod Mod4\n"

    def setUp(self) -> None:
        self._raw_lint = _load_linter().lint

    def lint(self, text: str) -> list[str]:
        """Lint a snippet with the canonical `set $mod Mod4` prelude in place."""
        return self._raw_lint(self.MOD_PRELUDE + text)

    def test_rejects_unknown_toplevel_directive(self) -> None:
        problems = self.lint("default_orientation auto\nworkspace_layouts default\n")
        self.assertTrue(any("unknown i3 directive 'workspace_layouts'" in p for p in problems))

    def test_rejects_legacy_kill_target(self) -> None:
        problems = self.lint("bindsym $mod+d kill focused window\n")
        self.assertTrue(any("kill focused window" in p for p in problems), problems)

    def test_accepts_the_two_valid_kill_forms(self) -> None:
        self.assertEqual(self.lint("bindsym $mod+d kill\nbindsym $mod+Shift+d kill window\n"), [])

    def test_rejects_deprecated_smart_borders_collision(self) -> None:
        problems = self.lint("hide_edge_borders vertical\nsmart_borders on\n")
        self.assertTrue(any("smart_borders" in p and "deprecated" in p for p in problems))
        self.assertEqual(self.lint("hide_edge_borders vertical\n"), [])

    def test_rejects_invalid_workspace_layout(self) -> None:
        problems = self.lint("workspace_layout splitv\n")
        self.assertTrue(any("workspace_layout" in p for p in problems))

    def test_rejects_unknown_layout_toggle_token(self) -> None:
        problems = self.lint("bindsym $mod+t layout toggle splitv spiraltabbed\n")
        self.assertTrue(any("spiraltabbed" in p for p in problems))

    def test_accepts_two_and_three_mode_layout_toggle(self) -> None:
        self.assertEqual(self.lint("bindsym $mod+t layout toggle splitv tabbed\n"), [])
        self.assertEqual(self.lint("bindsym $mod+t layout toggle splitv stacking tabbed\n"), [])

    def test_rejects_duplicate_binding(self) -> None:
        problems = self.lint("set $mod Mod4\nbindsym $mod+d kill\nbindsym Mod4+d kill window\n")
        self.assertTrue(any("duplicate binding" in p for p in problems), problems)
        self.assertEqual(self.lint("bindsym $mod+d kill\n"), [])

    def test_rejects_unset_variable_in_binding(self) -> None:
        problems = self._raw_lint("bindsym $mod+d kill\n")
        self.assertTrue(any("never `set`" in p for p in problems), problems)
        self.assertEqual(self.lint("set $mod Mod4\nbindsym $mod+d kill\n"), [])

    def test_rejects_unknown_modifier(self) -> None:
        problems = self.lint("bindsym Hyper+d kill\n")
        self.assertTrue(any("unknown modifier 'Hyper'" in p for p in problems), problems)

    def test_rejects_wrong_client_colour_arity(self) -> None:
        problems = self.lint("client.focused #38bdf8 #0e1220 #eef1f8 #38bdf8\n")
        self.assertTrue(any("client.focused" in p and "5 colours" in p for p in problems))
        self.assertEqual(
            self.lint("client.focused #38bdf8 #0e1220 #eef1f8 #38bdf8 #0a0d16\n"), [])

    def test_rejects_invalid_bar_mode_and_unknown_bar_key(self) -> None:
        problems = self.lint("bar {\n    mode floating\n    status_command i3status\n}\n")
        self.assertTrue(any("bar mode 'floating'" in p for p in problems), problems)
        problems = self.lint("bar {\n    nonsense yes\n}\n")
        self.assertTrue(any("unknown i3bar directive 'nonsense'" in p for p in problems))

    def test_accepts_hidden_bar_block(self) -> None:
        self.assertEqual(self.lint("bar {\n    mode hide\n}\n"), [])

    def test_rejects_unclosed_block(self) -> None:
        problems = self.lint("bar {\n    mode hide\n")
        self.assertTrue(any("unclosed block" in p for p in problems), problems)

    def test_rejects_bad_gaps_and_border_values(self) -> None:
        self.assertTrue(any("gaps" in p for p in self.lint("gaps inner\n")))
        self.assertTrue(any("default_border" in p for p in self.lint("default_border pixel\n")))
        self.assertEqual(self.lint("default_border pixel 2\ngaps inner 6\ngaps outer 6\n"), [])

    def test_rejects_invalid_resize_binding(self) -> None:
        problems = self.lint('bindsym $mod+Right resize grow width\n')
        self.assertTrue(any("resize" in p for p in problems), problems)
        self.assertEqual(self.lint("bindsym $mod+Right resize grow width 10 px\n"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
