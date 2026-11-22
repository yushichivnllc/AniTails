#!/usr/bin/env bash
# AniTails — waybar launcher for the i3-gaps session.
#
# Waybar is started by the i3 config (exec_always) with the AniTails config
# that seeds into ~/.config/waybar. Toggle via SUPER + Shift + B.
set -uo pipefail
export PATH="/usr/local/bin:${PATH}"

config="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/config.jsonc"
style="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/style.css"
args=()
[[ -f $config ]] && args+=(-c "${config}")
[[ -f $style ]] && args+=(-s "${style}")

command -v waybar >/dev/null 2>&1 || {
    printf 'bar.sh: waybar is not installed\n' >&2
    exit 1
}
exec waybar "${args[@]}"
