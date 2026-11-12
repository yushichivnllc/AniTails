#!/usr/bin/env bash
# @name: quickshell
# @ver: 1.0.0
# @short: Manage the AniDE Quickshell status bar
# @usage: hyde-shell quickshell [--watch|--reload|--update|--hide|--kill]
# @global.flag: -w,--watch | Start Quickshell if not already running
# @global.flag: -r,--reload | Restart Quickshell and refresh theme colors
# @global.flag: -u,--update | Refresh Quickshell theme colors
# @global.flag: -H,--hide | Toggle Quickshell bar visibility
# @global.flag: -k,--kill | Stop Quickshell and any legacy Waybar process
# @global.flag: -h,--help | Show this help message

set -euo pipefail

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
QS_CONFIG_DIR="${XDG_CONFIG_HOME}/quickshell"
QS_SHARE_DIR="${XDG_DATA_HOME}/quickshell"

find_qs_bin() {
    if command -v quickshell >/dev/null 2>&1; then
        printf 'quickshell\n'
    elif command -v qs >/dev/null 2>&1; then
        printf 'qs\n'
    else
        return 1
    fi
}

is_qs_running() {
    pgrep -u "${USER:-$(id -un)}" -x quickshell >/dev/null 2>&1 ||
        pgrep -u "${USER:-$(id -un)}" -x qs >/dev/null 2>&1
}

stop_waybar() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop "hyde-${XDG_SESSION_DESKTOP:-Hyprland}-bar.service" "hyde-Hyprland-bar.service" "waybar.service" >/dev/null 2>&1 || true
        systemctl --user reset-failed "hyde-${XDG_SESSION_DESKTOP:-Hyprland}-bar.service" "hyde-Hyprland-bar.service" "waybar.service" >/dev/null 2>&1 || true
    fi
    pkill -u "${USER:-$(id -un)}" -x waybar >/dev/null 2>&1 || true
}

ensure_config() {
    mkdir -p "${QS_CONFIG_DIR}"
    if [[ ! -f "${QS_CONFIG_DIR}/shell.qml" && -d "${QS_SHARE_DIR}" ]]; then
        cp -rn "${QS_SHARE_DIR}/." "${QS_CONFIG_DIR}/" 2>/dev/null || true
    fi
    if [[ ! -f "${QS_CONFIG_DIR}/theme.json" ]]; then
        cat >"${QS_CONFIG_DIR}/theme.json" <<'EOF'
{
  "barBg": "#141313",
  "mainBg": "#141313",
  "surfaceBg": "#1c1b1c",
  "layer2Bg": "#2b2a2a",
  "mainFg": "#e6e1e1",
  "subFg": "#948f94",
  "actBg": "#cbc4cb",
  "accentSecondary": "#4d4b4d",
  "onSecondaryContainer": "#ece6e9",
  "actFg": "#322f34",
  "hvrBg": "#2b2a2a",
  "hvrFg": "#e6e1e1",
  "borderColor": "#49464a",
  "cornerRadius": 23
}
EOF
    fi
}

sync_theme_from_waybar_css() {
    local css_file="${XDG_CONFIG_HOME}/waybar/theme.css"
    local json_file="${QS_CONFIG_DIR}/theme.json"
    [[ -f "${css_file}" ]] || return 0

    local main_bg main_fg act_bg act_fg
    main_bg=$(sed -nE 's/^[[:space:]]*@define-color[[:space:]]+main-bg[[:space:]]+(#[0-9a-fA-F]{6})[[:space:]]*;.*/\1/p' "${css_file}" | head -n1)
    main_fg=$(sed -nE 's/^[[:space:]]*@define-color[[:space:]]+main-fg[[:space:]]+(#[0-9a-fA-F]{6})[[:space:]]*;.*/\1/p' "${css_file}" | head -n1)
    act_bg=$(sed -nE 's/^[[:space:]]*@define-color[[:space:]]+wb-act-bg[[:space:]]+(#[0-9a-fA-F]{6})[[:space:]]*;.*/\1/p' "${css_file}" | head -n1)
    act_fg=$(sed -nE 's/^[[:space:]]*@define-color[[:space:]]+wb-act-fg[[:space:]]+(#[0-9a-fA-F]{6})[[:space:]]*;.*/\1/p' "${css_file}" | head -n1)

    [[ -n "${main_bg}" ]] || return 0
    mkdir -p "${QS_CONFIG_DIR}"
    cat >"${json_file}" <<EOF
{
  "barBg": "${main_bg}",
  "mainBg": "${main_bg}",
  "surfaceBg": "${main_bg}",
  "mainFg": "${main_fg:-#93cee9}",
  "subFg": "${main_fg:-#7aa8c4}",
  "actBg": "${act_bg:-#93cee9}",
  "actFg": "${act_fg:-#101419}",
  "hvrBg": "${act_fg:-#27323f}",
  "hvrFg": "${main_fg:-#93cee9}",
  "borderColor": "${act_bg:-#2c3847}",
  "cornerRadius": 16
}
EOF
}

start_qs() {
    stop_waybar
    ensure_config
    local qs_bin
    if ! qs_bin=$(find_qs_bin); then
        printf 'Quickshell binary (quickshell / qs) not found on PATH.\n' >&2
        return 0
    fi
    if is_qs_running; then
        return 0
    fi
    nohup "${qs_bin}" -p "${QS_CONFIG_DIR}" >/dev/null 2>&1 &
    disown || true
}

kill_qs() {
    stop_waybar
    pkill -u "${USER:-$(id -un)}" -x quickshell >/dev/null 2>&1 || true
    pkill -u "${USER:-$(id -un)}" -x qs >/dev/null 2>&1 || true
}

reload_qs() {
    kill_qs
    sleep 0.15
    start_qs
}

update_qs() {
    stop_waybar
    ensure_config
    if [[ -f "${QS_CONFIG_DIR}/theme.json" ]]; then
        touch "${QS_CONFIG_DIR}/theme.json"
    else
        sync_theme_from_waybar_css
    fi
    if ! is_qs_running && [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        start_qs
    fi
}

toggle_qs() {
    stop_waybar
    if is_qs_running; then
        kill_qs
    else
        start_qs
    fi
}

show_help() {
    cat <<'EOF'
Usage: hyde-shell quickshell [OPTION]

Options:
  -w, --watch, --start   Start Quickshell (and stop any legacy Waybar instance)
  -r, --reload           Restart Quickshell
  -u, --update           Refresh Quickshell theme colors
  -H, --hide, --toggle   Toggle Quickshell visibility
  -k, --kill, --stop     Stop Quickshell
  -h, --help             Show this help message
EOF
}

case "${1:---watch}" in
    -w | --watch | --start | start)
        start_qs
        ;;
    -r | --reload | reload | restart)
        reload_qs
        ;;
    -u | --update | update)
        update_qs
        ;;
    -H | --hide | --toggle | toggle | hide)
        toggle_qs
        ;;
    -k | --kill | --stop | stop | kill)
        kill_qs
        ;;
    -h | --help | help)
        show_help
        ;;
    *)
        start_qs
        ;;
esac
