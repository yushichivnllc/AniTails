#!/usr/bin/env bash
# AniDE Settings launcher. Inspired by SekaiPop and end-4/dots-hyprland.
# GPL-3.0-or-later; see CREDITS.md.
set -e
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! python3 -c 'from PyQt6 import QtWidgets' >/dev/null 2>&1; then
    message='AniDE Settings requires PyQt6 for the system Python. On Arch Linux: sudo pacman -S python-pyqt6'
    printf '%s\n' "$message" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send 'AniDE Settings' "$message" || true
    fi
    exit 1
fi
exec python3 "$script_dir/pygui/anide_settings.py" "$@"
