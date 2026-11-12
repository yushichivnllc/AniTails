# AniTails — start the Hyprland session on the autologin TTY.
#
# getty@tty1 autologins `amnesia` (see
# /etc/systemd/system/getty@tty1.service.d/20-anitails-autologin.conf), which
# gives a login shell; this fragment replaces that shell with the graphical
# session. It is sourced by /etc/profile, i.e. login shells only.
#
# Guards:
#   * no DISPLAY/WAYLAND_DISPLAY — never nest a session inside a session
#   * XDG_VTNR=1                 — only the autologin VT
#   * ANITAILS_SESSION_LAUNCHED  — no exec loop after a compositor crash
#   * interactive                — `su -` style non-interactive shells are left alone

if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
if [ -n "${ANITAILS_SESSION_LAUNCHED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
case "${XDG_VTNR:-}" in
    1) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac
case $- in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

ANITAILS_SESSION_LAUNCHED=1
export ANITAILS_SESSION_LAUNCHED
exec /usr/local/bin/anitails-hyprland-session
