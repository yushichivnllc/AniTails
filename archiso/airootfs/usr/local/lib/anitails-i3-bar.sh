#!/usr/bin/env bash
# AniTails — Waybar launcher (Wayland sessions only).
#
# The AniTails desktop is Xorg + i3-gaps, where **Waybar cannot draw**: since
# 0.11 it renders only through gtk-layer-shell, and `gtk_layer_is_supported()`
# is FALSE unless the default GDK display is Wayland. On X11
# `gtk_layer_init_for_window()` silently falls back to a plain GTK toplevel, so
# Waybar appears as a stray window that i3 tiles instead of a bar.
#
# On Xorg the bar is therefore i3bar (built into i3) fed by
# `anitails-i3status` — see the `bar { }` block in Configs/.config/i3/config.
# This launcher stays for a future Wayland session: with WAYLAND_DISPLAY set it
# execs Waybar using the AniTails config seeded into ~/.config/waybar, otherwise
# it exits 0 with an explanatory notice so `exec_always` never spams errors.
set -uo pipefail
export PATH="/usr/local/bin:${PATH}"

if [[ -z ${WAYLAND_DISPLAY:-} ]]; then
    printf 'anitails-i3-bar: no Wayland display (WINDOW_SESSION=%s); ' \
        "${XDG_SESSION_TYPE:-x11}" >&2
    printf 'Waybar needs gtk-layer-shell, which is Wayland-only — ' >&2
    printf 'i3bar + anitails-i3status own the bar on Xorg.\n' >&2
    exit 0
fi

config="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/config.jsonc"
style="${XDG_CONFIG_HOME:-$HOME/.config}/waybar/style.css"
args=()
[[ -f $config ]] && args+=(-c "${config}")
[[ -f $style ]] && args+=(-s "${style}")

command -v waybar >/dev/null 2>&1 || {
    printf 'anitails-i3-bar: waybar is not installed\n' >&2
    exit 1
}
exec waybar "${args[@]}"
