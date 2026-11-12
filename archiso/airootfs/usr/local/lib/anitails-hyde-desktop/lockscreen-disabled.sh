#!/usr/bin/env bash
# AniTails — screen locking is disabled on the live system.
#
# `amnesia` has a locked password entry (`!*` in /etc/shadow) and AniTails
# forbids passwordless sudo, so a compositor lock screen could be shown but
# never unlocked. Tails disables screen locking for the same reason.
#
# Idle blanking still works (hypridle dims the panel and turns DPMS off, both
# reversible with any input), and RAM is wiped on shutdown/USB removal.
set -uo pipefail

message="Screen locking is disabled on AniTails: the live user has no password.
The panel still blanks when idle; any input wakes it. RAM is wiped on shutdown
or when the boot USB is removed."

printf '%s\n' "$message" >&2
if command -v notify-send >/dev/null 2>&1; then
    notify-send -u low -a "AniTails" "Screen locking disabled" "$message" 2>/dev/null || true
fi
exit 0
