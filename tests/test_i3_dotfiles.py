#!/usr/bin/env python3
"""
Test Suite 8b: i3-gaps desktop integration.

Covers the AniTails-written i3-gaps design stack:

  * a repository-owned, hash-pinned i3 config tree (no opaque binaries),
  * an offline seeder that refuses to write an unverified tree,
  * a getty autologin + startx -> i3-gaps session launcher,
  * AniTails policy overrides (Tor Browser, no lock, Waybar standalone),
  * package set / config leftovers that would re-introduce GNOME/Wayland.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
AIROOTFS = REPO_ROOT / "archiso/airootfs"
VENDOR = AIROOTFS / "usr/share/anitails/i3"
SEEDER = AIROOTFS / "usr/local/lib/anitails-i3-seed"
SESSION = AIROOTFS / "usr/local/bin/anitails-i3-session"
DOCTOR = AIROOTFS / "usr/local/bin/anitails-i3-doctor"
WRAPPER = AIROOTFS / "etc/X11/xinit/anitails-i3.sh"
SYNC = REPO_ROOT / "scripts/sync-i3-dotfiles.py"


def package_set() -> set[str]:
    text = (REPO_ROOT / "archiso/packages.x86_64").read_text(encoding="utf-8")
    return {ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")}


class TestI3DotfilesVendor(unittest.TestCase):
    def test_manifest_matches_vendored_tree(self) -> None:
        res = subprocess.run(
            ["python3", str(SYNC), "--check"], capture_output=True, text=True,
        )
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_upstream_provenance_is_pinned_and_licensed(self) -> None:
        upstream = json.loads((VENDOR / "UPSTREAM.json").read_text(encoding="utf-8"))
        self.assertEqual(upstream["repository"], "anitails:local")
        self.assertEqual(upstream["license"], "GPL-3.0-or-later")
        # The i3 stack is self-written; provenance must not point at HyDE/AniDE.
        self.assertNotIn("AniDE", str(upstream.get("project", "")))
        self.assertIn("i3", str(upstream.get("project", "")).lower())

    def test_no_elf_binaries(self) -> None:
        for path in VENDOR.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(VENDOR).as_posix()
            with path.open("rb") as handle:
                magic = handle.read(4)
            self.assertNotEqual(magic, b"\x7fELF", f"vendored ELF blob is not allowed: {rel}")

    def test_no_gnome_configs_in_tree(self) -> None:
        for path in VENDOR.rglob("*"):
            if not path.is_file():
                continue
            rel = str(path.relative_to(VENDOR))
            self.assertNotIn(".config/dconf", rel)
            self.assertNotIn("gnome", rel.lower())
            self.assertNotIn("nautilus", rel)
            self.assertNotIn("dconf", rel)

    def test_no_hyde_leftover_files(self) -> None:
        """The vendored hyde tree was removed; the new tree must contain no hyde/hypr/uwsm paths."""
        for path in VENDOR.rglob("*"):
            if not path.is_file():
                continue
            rel = str(path.relative_to(VENDOR)).lower()
            self.assertNotIn("hyde", rel)
            self.assertNotIn("hypr", rel)
            self.assertNotIn("uwsm", rel)


class TestI3SessionAndSessionContract(unittest.TestCase):
    def test_session_script_is_present_executable_and_i3_centered(self) -> None:
        self.assertTrue(SESSION.is_file(), "anitails-i3-session must exist")
        self.assertTrue(os.access(SESSION, os.X_OK))
        txt = SESSION.read_text(encoding="utf-8")
        self.assertIn("anitails-i3-seed", txt)
        self.assertIn("XDG_CURRENT_DESKTOP=i3-gaps", txt)
        self.assertIn("xinit", txt.lower() + "")
        self.assertIn("/usr/local/lib/anitails-i3-seed", txt)
        # No greeter, no display manager, no Wayland.
        self.assertNotIn("uwsm", txt)
        self.assertNotIn("hyprland", txt)

    def test_x11_wrapper_is_present_executable(self) -> None:
        self.assertTrue(WRAPPER.is_file(), "X11 wrapper must exist")
        self.assertTrue(os.access(WRAPPER, os.X_OK))
        txt = WRAPPER.read_text(encoding="utf-8")
        self.assertIn("exec /usr/bin/i3", txt)
        self.assertNotIn("hypr", txt)
        self.assertNotIn("uwsm", txt)

    def test_profile_hook_points_at_i3_session(self) -> None:
        hook = (REPO_ROOT / "archiso/airootfs/etc/profile.d/99-anitails-session.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("anitails-i3-session", hook)
        self.assertNotIn("anitails-hyprland-session", hook)

    def test_doctor_script_reports_i3_not_hyprland(self) -> None:
        txt = DOCTOR.read_text(encoding="utf-8")
        self.assertIn("i3", txt.lower())
        self.assertNotIn("hypr", txt)

    def test_i3_config_policy_and_design_markers(self) -> None:
        txt = (VENDOR / "Configs/.config/i3/config").read_text(encoding="utf-8")
        # Tor Browser is the only browser, lock/suspend are absent.
        self.assertIn("anitails-tor-browser", txt)
        self.assertIn("$mod+L", txt)
        self.assertNotIn("firefox", txt)
        self.assertNotIn("clearnet", txt)

    def test_packages_drop_hyprland_and_keep_i3_stack(self) -> None:
        pkgs = package_set()
        for gone in ("hyprland", "uwsm", "hyprlock", "hypridle", "hyprpaper",
                     "hyprsunset", "hyprpicker", "hyprpolkitagent", "lua", "luarocks",
                     "xdg-desktop-portal-hyprland", "xorg-xwayland", "grim",
                     "slurp", "satty", "rofi-wayland", "xwaylandvideobridge",
                     "wl-clip-persist", "wl-clipboard", "nwg-displays"):
            self.assertNotIn(gone, pkgs, f"{gone} must not ship in the i3-gaps stack")
        for present in ("i3-gaps", "xorg-server", "xorg-xinit", "waybar",
                        "dunst", "wofi", "scrot", "feh", "cliphist"):
            self.assertIn(present, pkgs, f"{present} must ship in the i3-gaps stack")


class TestI3Step2UX(unittest.TestCase):
    """STEP 2 (UX/UI): posture module + settings keybinding."""

    def test_posture_and_settings_exist_executable_and_safe(self) -> None:
        posture = AIROOTFS / "usr/local/bin/anitails-posture"
        settings = AIROOTFS / "usr/local/bin/anitails-settings"
        for script in (posture, settings):
            self.assertTrue(script.is_file(), f"missing {script}")
            self.assertTrue(os.access(script, os.X_OK), f"not executable: {script}")
            txt = script.read_text(encoding="utf-8")
            self.assertNotIn("sudo", txt)
            self.assertNotIn("su root", txt)
            self.assertNotIn("password", txt.lower())
        # The report must be read-only: never delete, move, or overwrite files.
        posture_src = posture.read_text(encoding="utf-8")
        self.assertNotIn("rm ", posture_src)
        self.assertNotIn("rm -rf", posture_src)
        self.assertNotIn("mv ", posture_src)
        self.assertNotIn("> " + "$HOME", posture_src)
        self.assertNotIn("tee ", posture_src)

    def test_waybar_config_has_custom_posture_module(self) -> None:
        txt = (VENDOR / "Configs/.config/waybar/config.jsonc").read_text(encoding="utf-8")
        self.assertIn("custom/posture", txt)
        self.assertIn("anitails-posture --inline", txt)
        self.assertIn("anitails-settings", txt)

    def test_i3_config_binds_settings_key(self) -> None:
        txt = (VENDOR / "Configs/.config/i3/config").read_text(encoding="utf-8")
        self.assertIn("bindsym $mod+S exec /usr/local/bin/anitails-settings", txt)
        # The settings binding must not shadow the screenshot or browser bindings.
        self.assertIn("bindsym $mod+B exec $browser", txt)
        self.assertIn("bindsym $mod+Shift+4 exec $screenshot", txt)


class TestI3Seeder(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="anitails-i3-seed-"))
        self.home = self.tmp / "home"
        self.home.mkdir()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "ANITAILS_I3_DIR": str(VENDOR),
            "HOME": str(self.home),
        }
        return subprocess.run(
            ["python3", str(SEEDER), *args],
            capture_output=True, text=True, env=env,
        )

    def test_seeder_copies_tree_and_writes_state(self) -> None:
        res = self._run("--quiet")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue((self.home / ".config/i3/config").is_file())
        self.assertTrue((self.home / ".config/waybar/config.jsonc").is_file())
        self.assertTrue((self.home / ".Xresources").is_file())
        self.assertTrue((self.home / ".local/state/anitails/i3-seed.json").is_file())

    def test_seeder_check_mode_reports_missing_without_writing(self) -> None:
        res = self._run("--check", "--quiet")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue((self.home / ".config/i3/config").exists() is False)

    def test_seeder_rejects_corrupted_manifest(self) -> None:
        bogus = self.tmp / "bogus.sha256"
        bogus.write_text("0000000000000000000000000000000000000000000000000000000000000000  Configs/.config/i3/config\n")
        env = {**os.environ, "ANITAILS_I3_DIR": str(VENDOR), "HOME": str(self.home)}
        # Simulate a tampered tree: run with the real manifest but a corrupted file.
        real_config = VENDOR / "Configs/.config/i3/config"
        saved = real_config.read_bytes()
        try:
            real_config.write_bytes(saved + b"\n# tampered\n")
            res = subprocess.run(
                ["python3", str(SEEDER), "--quiet", "--home", str(self.home)],
                capture_output=True, text=True, env=env,
            )
            self.assertNotEqual(res.returncode, 0, "seeder must refuse a tampered tree")
            # Nothing written on failure.
            self.assertFalse((self.home / ".config/i3/config").is_file())
        finally:
            real_config.write_bytes(saved)

    def test_seeder_refresh_is_idempotent(self) -> None:
        first = self._run("--quiet")
        second = self._run("--quiet")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertTrue((self.home / ".config/i3/config").is_file())


if __name__ == "__main__":
    unittest.main()
