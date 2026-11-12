#!/usr/bin/env bash
# AniTails — status bar launcher for the HyDE (AniDE) Hyprland session.
#
# HyDE's bar is Quickshell (`hyde-shell quickshell.sh --watch`), an AUR-only
# package that AniTails refuses to ship (no unaudited third-party builds).
# When Quickshell is absent we fall back to Waybar with an AniTails config that
# ships inside the dotfiles tree.
#
# Usage:
#   bar.sh            start the bar (Waybar unless quickshell is installed)
#   bar.sh --toggle   hide the bar if it is running, start it otherwise
set -uo pipefail
export PATH="/usr/local/bin:${PATH}"

toggle=0
[[ ${1:-} == "--toggle" ]] && toggle=1

running_bar() {
    pgrep -u "$(id -u)" -x waybar >/dev/null 2>&1 && { echo waybar; return 0; }
    pgrep -u "$(id -u)" -x quickshell >/dev/null 2>&1 && { echo quickshell; return 0; }
    return 1
}

if (( toggle )); then
    if current="$(running_bar)"; then
        pkill -u "$(id -u)" -x "$current" >/dev/null 2>&1
        exit 0
    fi
fi

if command -v quickshell >/dev/null 2>&1; then
    # Quickshell was installed by the user (or a future audited PKGBUILD).
    exec hyde-shell quickshell.sh --watch
fi

if ! command -v waybar >/dev/null 2>&1; then
    notify-send -a "AniTails" "Status bar" "Neither quickshell nor waybar is available." 2>/dev/null || true
    printf 'bar.sh: neither quickshell nor waybar is installed\n' >&2
    exit 1
fi

config="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/config.jsonc"
style="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/style.css"
args=()
[[ -f $config ]] && args+=(-c "${config}")
[[ -f $style ]] && args+=(-s "${style}")

exec waybar "${args[@]}"
