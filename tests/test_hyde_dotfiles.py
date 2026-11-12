#!/usr/bin/env python3
"""
Test Suite 8: AniDE/HyDE Hyprland desktop integration.

Covers the replacement of the old GDM + GNOME Shell session with:

  * a vendored, hash-pinned AniDE (HyDE) dotfiles tree (no opaque binaries),
  * an offline seeder that refuses to write an unverified tree,
  * a getty autologin + uwsm -> Hyprland session launcher,
  * AniTails policy overrides (Tor Browser, no lockscreen, Waybar fallback),
  * package set / config leftovers that would re-introduce GNOME.
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
VENDOR = AIROOTFS / "usr/share/anitails/hyde"
SEEDER = AIROOTFS / "usr/local/lib/anitails-hyde-seed"
SESSION = AIROOTFS / "usr/local/bin/anitails-hyprland-session"
OVERRIDES = REPO_ROOT / "archiso/hyde-overrides"


def package_set() -> set[str]:
    text = (REPO_ROOT / "archiso/packages.x86_64").read_text(encoding="utf-8")
    return {ln.strip() for ln in text.splitlines() if ln.strip() and not ln.startswith("#")}


class TestHydeDotfilesVendor(unittest.TestCase):
    def test_manifest_matches_vendored_tree(self) -> None:
        res = subprocess.run(
            ["python3", str(REPO_ROOT / "scripts/sync-hyde-dotfiles.py"), "--check"],
            capture_output=True, text=True,
        )
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_upstream_provenance_is_pinned_and_licensed(self) -> None:
        upstream = json.loads((VENDOR / "UPSTREAM.json").read_text(encoding="utf-8"))
        self.assertEqual(upstream["repository"], "https://github.com/hyprdes/AniDE")
        self.assertEqual(upstream["license"], "GPL-3.0-only")
        self.assertRegex(upstream["commit"], r"^[0-9a-f]{40}$")
        self.assertTrue((VENDOR / "LICENSE").is_file(), "GPL-3.0 text must ship with the dotfiles")
        self.assertIn("hydectl", " ".join(upstream["excluded_paths"]))
        # The pinned commit in snapshot.lock.json must be the vendored one.
        lock = json.loads((REPO_ROOT / "archiso/snapshot.lock.json").read_text(encoding="utf-8"))
        self.assertEqual(lock["desktop_dotfiles"]["commit"], upstream["commit"])

    def test_vendored_tree_is_not_git_ignored(self) -> None:
        """Regression: HyDE's shaders/.gitignore contains a bare `*`.

        That silently kept all 12 Hyprland shader files out of the commit, so
        the manifest check passed in the work tree but failed in CI's fresh
        checkout ("missing: Configs/.config/hypr/shaders/*"). Every vendored
        file must therefore be tracked by git.
        """
        files = [
            p.relative_to(REPO_ROOT).as_posix()
            for p in VENDOR.rglob("*")
            if p.is_file() and p.name != "MANIFEST.sha256"
        ]
        res = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "check-ignore", "--stdin"],
            input="\n".join(files), capture_output=True, text=True,
        )
        if res.returncode not in (0, 1):
            self.skipTest("not a git checkout")
        self.assertEqual(res.stdout.split(), [], "git-ignored vendored files disappear on clone")

        tracked = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "ls-files", "--", "archiso/airootfs/usr/share/anitails/hyde"],
            capture_output=True, text=True,
        )
        if tracked.returncode != 0:
            self.skipTest("not a git checkout")
        self.assertTrue(tracked.stdout.strip(), "vendored tree must be committed")
        shaders = [ln for ln in tracked.stdout.splitlines() if "/hypr/shaders/" in ln]
        self.assertGreaterEqual(len(shaders), 11, "Hyprland shaders must be tracked, not ignored")

    def test_no_elf_binaries_and_no_gnome_configs_vendored(self) -> None:
        for path in VENDOR.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(VENDOR).as_posix()
            with path.open("rb") as handle:
                magic = handle.read(4)
            self.assertNotEqual(magic, b"\x7fELF", f"vendored ELF blob is not allowed: {rel}")
            self.assertNotIn(".config/dconf", rel)
            self.assertNotIn("hydectl", rel)
            self.assertNotIn("hyde-ipc", rel)

    def test_only_gpl_compatible_anitails_overrides(self) -> None:
        expected = {
            ".config/hyde/config.toml",
            ".config/hypr/hyprland.lua",
            ".config/hypr/anitails.lua",
            ".config/hypr/hypridle.conf",
            ".config/uwsm/env.d/90-anitails.sh",
            ".config/waybar/config.jsonc",
            ".config/waybar/style.css",
        }
        actual = {p.relative_to(OVERRIDES).as_posix() for p in OVERRIDES.rglob("*") if p.is_file()}
        self.assertEqual(actual, expected)


class TestHydeSeeder(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="anitails-seed-"))
        self.home = self.tmp / "home"
        self.home.mkdir()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_seed(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "ANITAILS_HYDE_DIR": str(VENDOR)}
        return subprocess.run(
            ["python3", str(SEEDER), "--home", str(self.home), *args],
            capture_output=True, text=True, env=env,
        )

    def test_seed_creates_desktop_and_is_idempotent(self) -> None:
        res = self.run_seed()
        self.assertEqual(res.returncode, 0, res.stderr)

        for expected in (
            ".config/hypr/hyprland.lua",
            ".config/hypr/anitails.lua",
            ".config/hyde/config.toml",
            ".config/waybar/config.jsonc",
            ".local/share/hypr/hyde.lua",
            ".local/bin/hyde-shell",
            ".local/state/hyde/version",
            "Downloads",
            "Persistent",
        ):
            self.assertTrue((self.home / expected).exists(), f"seeder did not create {expected}")

        shell = self.home / ".local/bin/hyde-shell"
        self.assertTrue(os.access(shell, os.X_OK), "hyde-shell must be executable")

        # Overrides win over the upstream copy.
        config = (self.home / ".config/hyde/config.toml").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/anitails-tor-browser", config)
        self.assertIn('backend = "hyprpaper"', config)
        hyprland_lua = (self.home / ".config/hypr/hyprland.lua").read_text(encoding="utf-8")
        self.assertIn('pcall(require, "anitails")', hyprland_lua)

        state = json.loads((self.home / ".local/state/anitails/hyde-seed.json").read_text(encoding="utf-8"))
        self.assertGreater(state["created"], 400)

        # A second run must not overwrite the user's own HyDE entry file, while
        # AniTails policy files (overrides) are refreshed every boot.
        edited = self.home / ".config/hypr/hyprland.lua"
        edited.write_text("-- user edit\n", encoding="utf-8")
        policy = self.home / ".config/hypr/anitails.lua"
        policy.write_text("-- stale policy\n", encoding="utf-8")
        res2 = self.run_seed()
        self.assertEqual(res2.returncode, 0, res2.stderr)
        self.assertEqual(edited.read_text(encoding="utf-8"), "-- user edit\n")
        self.assertIn("anitails-tor-browser", policy.read_text(encoding="utf-8"))

    def test_check_mode_writes_nothing(self) -> None:
        res = self.run_seed("--check")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("not yet in", res.stdout)
        self.assertFalse((self.home / ".config").exists())

    def test_tampered_tree_is_refused(self) -> None:
        vendor = self.tmp / "vendor"
        shutil.copytree(VENDOR, vendor)
        victim = vendor / "Configs/.config/hyde/config.toml"
        victim.write_text(victim.read_text(encoding="utf-8") + "\n# tampered\n", encoding="utf-8")
        env = {**os.environ, "ANITAILS_HYDE_DIR": str(vendor)}
        res = subprocess.run(
            ["python3", str(SEEDER), "--home", str(self.home)],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(res.returncode, 1)
        self.assertIn("hash mismatch", res.stderr)
        self.assertFalse((self.home / ".config").exists(), "nothing may be written after a failed check")

    def test_force_resets_policy_files(self) -> None:
        self.assertEqual(self.run_seed().returncode, 0)
        config = self.home / ".config/hyde/config.toml"
        config.write_text("# broken\n", encoding="utf-8")
        self.assertEqual(self.run_seed("--force").returncode, 0)
        self.assertIn("anitails-tor-browser", config.read_text(encoding="utf-8"))


class TestHyprlandSession(unittest.TestCase):
    def test_session_launcher_is_fail_closed_and_uses_uwsm(self) -> None:
        text = SESSION.read_text(encoding="utf-8")
        self.assertIn("/usr/local/lib/anitails-hyde-seed", text)
        self.assertIn("uwsm start hyprland-uwsm.desktop", text)
        self.assertIn("systemctl poweroff", text)
        self.assertIn("bash -l", text)  # last-resort debug shell, no infinite loop
        self.assertTrue(os.access(SESSION, os.X_OK))

    def test_autologin_is_amnesia_only_and_has_no_display_manager(self) -> None:
        dropin = (
            AIROOTFS / "etc/systemd/system/getty@tty1.service.d/20-anitails-autologin.conf"
        ).read_text(encoding="utf-8")
        self.assertIn("--autologin amnesia", dropin)
        self.assertNotIn("--autologin root", dropin)
        self.assertNotIn("AutomaticLogin=root", dropin)
        finalize = (AIROOTFS / "usr/local/lib/anitails-alpm-finalize").read_text(encoding="utf-8")
        self.assertIn("display-manager.service", finalize)
        self.assertIn("getty@tty1.service", finalize)
        self.assertNotIn("gdm.service", finalize)

    def test_anitails_overrides_encode_the_security_policy(self) -> None:
        lua = (OVERRIDES / ".config/hypr/anitails.lua").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/anitails-tor-browser", lua)
        self.assertIn("lockscreen-disabled.sh", lua)
        hypridle = (OVERRIDES / ".config/hypr/hypridle.conf").read_text(encoding="utf-8")
        active_lines = [
            ln.strip() for ln in hypridle.splitlines() if ln.strip() and not ln.lstrip().startswith("#")
        ]
        directives = "\n".join(active_lines)
        self.assertNotIn("loginctl lock-session", directives)
        self.assertNotIn("systemctl suspend", directives)
        self.assertNotIn("lock_cmd", directives)
        env = (OVERRIDES / ".config/uwsm/env.d/90-anitails.sh").read_text(encoding="utf-8")
        self.assertIn("BROWSER=/usr/local/bin/anitails-tor-browser", env)

    def test_bar_falls_back_to_waybar(self) -> None:
        bar = (AIROOTFS / "usr/local/lib/anitails-hyde-desktop/bar.sh").read_text(encoding="utf-8")
        self.assertIn("quickshell", bar)
        self.assertIn("waybar", bar)
        # Waybar reads JSONC; strip line comments before parsing it here.
        raw = (OVERRIDES / ".config/waybar/config.jsonc").read_text(encoding="utf-8")
        stripped = "\n".join(re.sub(r"^\s*//.*$", "", ln) for ln in raw.splitlines())
        waybar = json.loads(stripped)
        self.assertIn("modules-center", waybar)
        self.assertTrue((OVERRIDES / ".config/waybar/style.css").is_file())


class TestDesktopInventory(unittest.TestCase):
    def test_hyprland_stack_present_and_gnome_absent(self) -> None:
        pkgs = package_set()
        for required in (
            "hyprland", "uwsm", "hypridle", "hyprlock", "hyprpaper", "hyprsunset",
            "hyprpolkitagent", "xdg-desktop-portal-hyprland", "waybar", "rofi-wayland",
            "dunst", "kitty", "dolphin", "cliphist", "grim", "slurp", "satty",
        ):
            self.assertIn(required, pkgs)
        for forbidden in (
            "gdm", "gnome-shell", "gnome-session", "gnome-control-center", "nautilus",
            "dconf", "xdg-desktop-portal-gnome", "firefox", "quickshell",
        ):
            self.assertNotIn(forbidden, pkgs)

    def test_snapshot_lock_tracks_desktop_stack(self) -> None:
        lock = json.loads((REPO_ROOT / "archiso/snapshot.lock.json").read_text(encoding="utf-8"))
        self.assertNotIn("gnome-shell", lock["arch_official_packages_pinned"])
        self.assertNotIn("gdm", lock["arch_official_packages_pinned"])
        stack = lock["desktop_stack_packages"]
        for pkg in ("hyprland", "uwsm", "waybar", "hyprpaper", "xdg-desktop-portal-hyprland"):
            self.assertIn(pkg, stack)
            self.assertIn("minimum_version", stack[pkg])
            self.assertIn("repo", stack[pkg])

    def test_wallpaper_and_doctor_ship_with_the_iso(self) -> None:
        wallpaper = AIROOTFS / "usr/share/anitails/wallpapers/anitails-default.png"
        self.assertTrue(wallpaper.is_file())
        self.assertEqual(wallpaper.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")
        self.assertGreater(wallpaper.stat().st_size, 10_000)
        doctor = AIROOTFS / "usr/local/bin/anitails-hyde-doctor"
        self.assertTrue(os.access(doctor, os.X_OK))
        text = doctor.read_text(encoding="utf-8")
        self.assertIn("quickshell", text)

    def test_every_profiledef_permission_path_exists_before_pacstrap(self) -> None:
        prof = (REPO_ROOT / "archiso/profiledef.sh").read_text(encoding="utf-8")
        for rel in re.findall(r'\["([^"]+)"\]="[^"]+"', prof):
            self.assertTrue(
                (AIROOTFS / rel.lstrip("/")).exists() or (AIROOTFS / rel.lstrip("/")).is_symlink(),
                f"file_permissions path missing from airootfs: {rel}",
            )


if __name__ == "__main__":
    unittest.main()
