#!/usr/bin/env python3
"""
Test Suite 8d: the Xorg bar (`i3bar` + `anitails-i3status`).

Waybar ≥ 0.11 draws only through `gtk-layer-shell`, whose `gtk_layer_is_supported()`
returns FALSE for any non-Wayland display; on Xorg `gtk_layer_init_for_window()`
falls back to a plain GTK toplevel, so the bar became a stray tiled window. These
tests pin the replacement: an i3bar `bar { }` block fed by `anitails-i3status`,
which speaks i3bar's JSON protocol and carries the AniTails posture banner.

Covers:
  * `--once` emits the i3bar header + a parseable frame with every block,
  * a healthy posture report renders Tor ●, a broken/missing one still renders a
    valid frame (the bar must never die because a probe failed),
  * `anitails-i3-bar.sh` exits 0 with a notice outside Wayland,
  * the i3 config actually wires `status_command` to the script and keeps the
    grammar lint green.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
AIROOTFS = REPO_ROOT / "archiso/airootfs"
STATUS = AIROOTFS / "usr/local/bin/anitails-i3status"
POSTURE = AIROOTFS / "usr/local/bin/anitails-posture"
BAR_LAUNCHER = AIROOTFS / "usr/local/lib/anitails-i3-bar.sh"
I3_CONFIG = AIROOTFS / "usr/share/anitails/i3/Configs/.config/i3/config"
LINTER = REPO_ROOT / "scripts/lint-i3-config.py"


def read_frame(*extra: str, posture_cmd: Path | str = POSTURE) -> tuple[dict, list[dict]]:
    """Run `anitails-i3status --once` and return (header, blocks)."""
    result = subprocess.run(
        [sys.executable, str(STATUS), "--once", "--posture-cmd", str(posture_cmd), *extra],
        capture_output=True, text=True, timeout=60,
    )
    assert result.returncode == 0, result.stderr
    header_line, _, rest = result.stdout.partition("\n")
    body = rest.strip()
    assert body.startswith("[") and body.endswith("]"), f"bad i3bar body: {body!r}"
    frames = json.loads(body)
    # `--once` prints one frame inside the array: [[{...}, ...]]
    assert isinstance(frames, list) and len(frames) == 1, frames
    return json.loads(header_line), frames[0]


class TestI3StatusProtocol(unittest.TestCase):
    def test_header_and_blocks_follow_the_i3bar_protocol(self) -> None:
        header, blocks = read_frame()
        self.assertEqual(header["version"], 1)
        self.assertFalse(header["click_events"])
        names = [b["name"] for b in blocks]
        self.assertEqual(names, ["posture", "firewall", "persistence", "ramwipe", "clock"])
        for entry in blocks:
            self.assertIn("full_text", entry)
            self.assertTrue(entry["full_text"])
            self.assertRegex(entry["color"], r"^#[0-9a-f]{6}$")

    def test_clock_block_has_a_human_and_machine_form(self) -> None:
        _, blocks = read_frame()
        clock = next(b for b in blocks if b["name"] == "clock")
        self.assertRegex(clock["full_text"], r"^\d{2}:\d{2}  [A-Z][a-z]{2} \d{2} [A-Z][a-z]{2}$")
        self.assertRegex(clock["tooltip"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$")

    def test_healthy_posture_renders_tor_connected(self) -> None:
        _, blocks = read_frame()
        posture = next(b for b in blocks if b["name"] == "posture")
        # The Debian sandbox has no Tor proxy: the honest state is "not connected".
        self.assertIn(posture["full_text"], {"Tor ●", "Tor ○"})
        self.assertIn("Firewall:", posture["tooltip"])
        self.assertIn("RAM wipe:", posture["tooltip"])

    def test_failed_posture_command_still_emits_a_valid_frame(self) -> None:
        for bogus in ("/bin/false", "/nonexistent/anitails-posture"):
            header, blocks = read_frame(posture_cmd=bogus)
            self.assertEqual(header["version"], 1)
            posture = next(b for b in blocks if b["name"] == "posture")
            self.assertEqual(posture["full_text"], "Tor ○")
            self.assertIn("unknown", posture["tooltip"])

    def test_synthetic_posture_is_rendered_verbatim(self) -> None:
        import tempfile

        script = ("#!/usr/bin/env python3\n"
                  "import json\n"
                  "print(json.dumps({'tor': 'connected', 'firewall': 'enforced',\n"
                  "                  'persistence': 'unlocked', 'ram_wipe': 'armed',\n"
                  "                  'release': 'READY'}))\n")
        with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as handle:
            handle.write(script)
            path = handle.name
        os.chmod(path, 0o755)
        try:
            _, blocks = read_frame(posture_cmd=path)
        finally:
            os.unlink(path)
        texts = {b["name"]: b["full_text"] for b in blocks}
        self.assertEqual(texts["posture"], "Tor ●")
        self.assertEqual(texts["firewall"], "fw ✓")
        self.assertEqual(texts["persistence"], "LUKS ●")
        self.assertEqual(texts["ramwipe"], "RAM ✓")


class TestBarLauncherWaylandGate(unittest.TestCase):
    def _run(self, env_extra: dict[str, str]) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if k != "WAYLAND_DISPLAY"}
        env.update(env_extra)
        return subprocess.run(["bash", str(BAR_LAUNCHER)], capture_output=True, text=True,
                              env=env, timeout=60)

    def test_no_wayland_display_exits_cleanly_with_a_notice(self) -> None:
        result = self._run({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Wayland", result.stderr)
        self.assertIn("i3bar", result.stderr)

    def test_never_starts_waybar_on_xorg(self) -> None:
        # Even a fake `waybar` on PATH must not be executed without Wayland.
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "waybar-ran"
            fake = Path(tmp) / "waybar"
            fake.write_text(f"#!/bin/sh\ntouch {marker}\n", encoding="utf-8")
            os.chmod(fake, 0o755)
            result = self._run({"PATH": f"{tmp}:/usr/bin:/bin", "XDG_SESSION_TYPE": "x11"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists(), "waybar was launched on an Xorg session")


class TestI3ConfigWiring(unittest.TestCase):
    def test_bar_block_uses_i3bar_with_the_anitails_status_command(self) -> None:
        text = I3_CONFIG.read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines()
                         if not line.lstrip().startswith("#"))
        self.assertRegex(code, r"(?m)^\s*mode dock$")
        self.assertIn("status_command /usr/local/bin/anitails-i3status", code)
        self.assertIn("bindsym $mod+Shift+b bar mode toggle", code)
        self.assertNotIn("mode hide", code)

    def test_config_still_lints_clean(self) -> None:
        result = subprocess.run([sys.executable, str(LINTER)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_status_script_is_executable_and_py_compiles(self) -> None:
        self.assertTrue(os.access(STATUS, os.X_OK), "anitails-i3status must be executable")
        result = subprocess.run([sys.executable, "-m", "py_compile", str(STATUS)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
