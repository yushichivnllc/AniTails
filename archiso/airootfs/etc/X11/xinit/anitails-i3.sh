#!/bin/bash
# AniTails — X11 session wrapper (invoked by startx / xinit).
#
# This script is the client startx runs. It:
#   1. paints the solid AniTails desktop background (#0a0d16),
#   2. applies the pinned wallpaper behind it (best-effort),
#   3. execs i3-gaps.
#
# The seeder (anitails-i3-seed) and the cursor theme (.Xresources) are handled
# by the i3 config, which runs before the window manager takes over.
set -uo pipefail

export PATH="/usr/local/bin:${PATH}"

# Solid dark desktop background; the wallpaper replaces it when it is available.
xsetroot -solid '#0a0d16' 2>/dev/null || true

# Best-effort pinned wallpaper (never blocks the session).
wallpaper="/usr/share/anitails/wallpapers/anitails-default.png"
if [[ -f "$wallpaper" ]] && command -v feh >/dev/null 2>&1; then
    feh --bg-fill "$wallpaper" 2>/dev/null || true
fi

exec /usr/bin/i3
