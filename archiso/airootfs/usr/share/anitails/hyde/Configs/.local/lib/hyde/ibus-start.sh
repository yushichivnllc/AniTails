#!/usr/bin/env bash
# @name: ibus-start
# @ver: 1.1.0
# @short: Start IBus with the Vietnamese engine already registered
# @usage: hyde-shell ibus-start [--seed] [--force] [--status]
# @global.flag: -h,--help | Show this help message
# @global.flag: --seed | Register the Vietnamese engine in IBus and exit, without starting the daemon
# @global.flag: --force | Register again even when an earlier session already did it
# @global.flag: --status | Show the input method environment, the installed engines and the seed state

# AniDE Vietnamese input bootstrap.
#
# Installing `ibus` and `ibus-unikey` alone never gave a working Vietnamese
# keyboard: IBus preloads only the plain layout engine (`xkb:us::eng`), so a
# fresh session had no Vietnamese engine to switch to until the user opened
# `ibus-setup` and added Vietnamese -> Unikey by hand. This script closes that
# gap. At session start it registers the Vietnamese engine that is installed
# (Unikey by default, any other `vi` engine as a fallback) in IBus' own
# settings, then starts the daemon without replacing another one.
#
# Registering is deliberately conservative:
#   * engines are appended, never rewritten or removed -- a list the user built
#     in `ibus-setup` is kept as it is;
#   * it happens once, recorded in $XDG_STATE_HOME/hyde/ibus/vi-engine-seeded,
#     so an engine the user removes on purpose is not added back at every login;
#   * an empty engine-switch key is filled in, an existing one is left alone;
#   * nothing runs when another input method framework is in use, or when
#     ANIDE_INPUT_METHOD turns the AniDE defaults off.
#
# Knobs, all optional and read before login (e.g. in ~/.config/uwsm/env):
#   ANIDE_INPUT_METHOD=auto|ibus|none  anything but auto/ibus disables this script
#   ANIDE_IBUS_ENGINE=<name>|none      engine to register (default: Unikey)
#   ANIDE_IBUS_COMPONENT_DIRS=<dirs>   colon separated IBus component directories
#                                      (default: $XDG_DATA_DIRS; testing hook)

set -u

IBUS_SCHEMA="org.freedesktop.ibus.general"
IBUS_DCONF_PATH="/desktop/ibus/general"
IBUS_HOTKEY_SCHEMA="org.freedesktop.ibus.general.hotkey"
IBUS_HOTKEY_DCONF_PATH="/desktop/ibus/general/hotkey"
IBUS_LAYOUT_FALLBACK="xkb:us::eng"
IBUS_ENGINE_TIMEOUT=5
IBUS_TRIGGER_FALLBACK="<Control>space"

stateHome="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}"
# A relative XDG_STATE_HOME would drop the marker into whatever cwd the session
# started in, so fall back to the plain default instead.
[[ ${stateHome} == /* ]] || stateHome="${HOME:-/tmp}/.local/state"
seedMarker="${stateHome}/hyde/ibus/vi-engine-seeded"
requestedEngine="${ANIDE_IBUS_ENGINE:-Unikey}"

flg_SeedOnly=0
flg_Force=0
flg_Status=0

usage() {
    cat <<'EOF'
Usage: hyde-shell ibus-start [options]

Starts IBus for the session and makes sure a Vietnamese engine is registered in
it, so Vietnamese works right after the installation without opening ibus-setup
first. The engine switch key stays IBus' own default: <Control>space.

Options:
  --seed       Register the Vietnamese engine, then exit (no daemon start)
  --force      Register again even if an earlier session already did
  --status     Print the input method environment, engines and seed state
  -h, --help   Show this help

Environment:
  ANIDE_INPUT_METHOD  "auto" or "ibus" (default) keep the AniDE defaults; any
                      other value, e.g. "none", disables them
  ANIDE_IBUS_ENGINE   Engine to register, default "Unikey"; "none" skips it
EOF
}

log() { printf '[ibus-start] %s\n' "$*" >&2; }

# Best effort: a session that has no notification daemon just logs instead.
notify() {
    have notify-send || return 0
    notify-send -a "AniDE" -i input-keyboard "$1" "$2" >/dev/null 2>&1 || return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

one_line() { tr '\n' ' ' | sed 's/ $//'; }

# A readable one-liner of a list valued key; an unreachable backend reads as
# empty rather than failing the whole report.
list_line() {
    local reader="$1" key="${2:-}" raw=""
    if [[ -n ${key} ]]; then
        raw="$("${reader}" "${key}" 2>/dev/null)" || raw=""
    else
        raw="$("${reader}" 2>/dev/null)" || raw=""
    fi
    parse_string_array "${raw}" | one_line
}

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| Policy: whose input method is this?  |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

policy_allows_ibus() {
    case ${ANIDE_INPUT_METHOD:-auto} in
    auto | ibus) return 0 ;;
    *) return 1 ;;
    esac
}

# A toolkit variable pointing somewhere else means another framework was chosen.
toolkit_env_conflicts() {
    [[ -n ${GTK_IM_MODULE:-} && ${GTK_IM_MODULE} != ibus ]] && return 0
    [[ -n ${QT_IM_MODULE:-} && ${QT_IM_MODULE} != ibus ]] && return 0
    [[ -n ${XMODIFIERS:-} && ${XMODIFIERS} != '@im=ibus' ]] && return 0
    return 1
}

# Another framework may have been started without exporting its toolkit vars.
fcitx_running() {
    have pgrep || return 1
    pgrep -u "$(id -u)" -x 'fcitx5|fcitx' >/dev/null 2>&1
}

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| GVariant string arrays               |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

# gsettings prints "['xkb:us::eng', 'Unikey']", and "@as []" for an empty list;
# dconf prints the same, or nothing at all when the key was never written.
parse_string_array() {
    local raw="${1:-}" item
    local -a items=()
    raw="${raw#@as }"
    raw="${raw#\[}"
    raw="${raw%\]}"
    [[ -z ${raw//[[:space:]]/} ]] && return 0
    IFS=',' read -r -a items <<<"${raw}"
    for item in ${items[@]+"${items[@]}"}; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        item="${item#\'}"
        item="${item%\'}"
        item="${item#\"}"
        item="${item%\"}"
        [[ -n ${item} ]] && printf '%s\n' "${item}"
    done
    return 0
}

format_string_array() {
    local out="" item
    for item in "$@"; do
        item="${item//\'/}"
        [[ -z ${item} ]] && continue
        [[ -n ${out} ]] && out+=", "
        out+="'${item}'"
    done
    printf '[%s]' "${out}"
}

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| IBus settings                        |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

declare -A gsUsable=()
gsettings_usable() {
    local schema="$1"
    if [[ -z ${gsUsable["${schema}"]:-} ]]; then
        if have gsettings && gsettings list-keys "${schema}" >/dev/null 2>&1; then
            gsUsable["${schema}"]=1
        else
            gsUsable["${schema}"]=0
        fi
    fi
    [[ ${gsUsable["${schema}"]} -eq 1 ]]
}

# Prints the raw GVariant of a key. Failing means no settings backend is
# reachable, which is not the same as an empty value: without a backend nothing
# can be written either, so the caller gives up instead of "registering" a list
# that would only ever exist inside this process.
setting_read() {
    local schema="$1" key="$2" path="$3"
    if gsettings_usable "${schema}"; then
        gsettings get "${schema}" "${key}" 2>/dev/null && return 0
        return 1
    fi
    if have dconf; then
        dconf read "${path}" 2>/dev/null && return 0
        return 1
    fi
    return 1
}

setting_write() {
    local schema="$1" key="$2" path="$3" value="$4"
    if gsettings_usable "${schema}"; then
        if gsettings set "${schema}" "${key}" "${value}" >/dev/null 2>&1; then
            return 0
        fi
        log "gsettings refused to write ${key}"
        return 1
    fi
    if have dconf; then
        if dconf write "${path}" "${value}" >/dev/null 2>&1; then
            return 0
        fi
        log "dconf refused to write ${key}"
        return 1
    fi
    log "neither gsettings nor dconf is reachable; cannot register the engine"
    return 1
}

ibus_read() { setting_read "${IBUS_SCHEMA}" "$1" "${IBUS_DCONF_PATH}/$1"; }
ibus_write() { setting_write "${IBUS_SCHEMA}" "$1" "${IBUS_DCONF_PATH}/$1" "$2"; }
hotkey_read() { setting_read "${IBUS_HOTKEY_SCHEMA}" triggers "${IBUS_HOTKEY_DCONF_PATH}/triggers"; }
hotkey_write() { setting_write "${IBUS_HOTKEY_SCHEMA}" triggers "${IBUS_HOTKEY_DCONF_PATH}/triggers" "$1"; }

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| Engine discovery                     |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

# IBus takes its engines from the component XML files an engine package
# installs. That is also what `ibus list-engine` reports, but reading the files
# works before the daemon is up and without a session bus.
ibus_component_dirs() {
    local list="${ANIDE_IBUS_COMPONENT_DIRS:-${XDG_DATA_DIRS:-/usr/local/share/:/usr/share}}"
    local relative=1 dir
    local -a parts=()
    [[ -n ${ANIDE_IBUS_COMPONENT_DIRS:-} ]] && relative=0
    IFS=':' read -r -a parts <<<"${list}"
    for dir in ${parts[@]+"${parts[@]}"}; do
        [[ -n ${dir} ]] || continue
        if [[ ${relative} -eq 1 ]]; then
            printf '%s/ibus/component\n' "${dir%/}"
        else
            printf '%s\n' "${dir}"
        fi
    done
}

# Vietnamese engine names out of an <engine> list, on stdin.
awk_vi_engines() {
    awk '
        /<engine>/ { in_engine = 1; name = ""; lang = ""; next }
        /<\/engine>/ {
            if (in_engine && lang == "vi" && name != "") print name
            in_engine = 0
            next
        }
        in_engine && match($0, /<name>[^<]*<\/name>/) {
            name = substr($0, RSTART + 6, RLENGTH - 13)
        }
        in_engine && match($0, /<language>[^<]*<\/language>/) {
            lang = substr($0, RSTART + 10, RLENGTH - 21)
        }
    ' 2>/dev/null
}

# The command a component delegates its engine list to, if any.
ibus_component_exec() {
    awk '
        match($0, /<engines[^>]*exec="[^"]*"/) {
            tag = substr($0, RSTART, RLENGTH)
            sub(/^.*exec="/, "", tag)
            sub(/".*$/, "", tag)
            print tag
            exit
        }
    ' "$1" 2>/dev/null
}

# A component either lists its engines inline or, like the unikey.xml that
# ibus-unikey installs, hands the list to the engine itself:
# <engines exec="/usr/lib/ibus/ibus-engine-unikey --xml"/>. IBus runs that
# command to build its registry, so both forms are read here. It is bounded,
# because this runs at session start and a broken engine must not stall login.
ibus_engines_of_component() {
    local file="$1" cmdLine execPath
    local -a cmd=()
    awk_vi_engines <"${file}"
    cmdLine="$(ibus_component_exec "${file}")"
    [[ -n ${cmdLine} ]] || return 0
    read -r -a cmd <<<"${cmdLine}"
    execPath="${cmd[0]:-}"
    # Only an absolute path that is there: a relative one would resolve against
    # whatever cwd the session happened to start in.
    [[ ${execPath} == /* && -x ${execPath} ]] || return 0
    if have timeout; then
        timeout "${IBUS_ENGINE_TIMEOUT}" "${cmd[@]}" 2>/dev/null | awk_vi_engines
    else
        "${cmd[@]}" 2>/dev/null | awk_vi_engines
    fi
}

ibus_vi_engines() {
    local dir file
    while IFS= read -r dir; do
        [[ -d ${dir} ]] || continue
        for file in "${dir}"/*.xml; do
            [[ -f ${file} ]] || continue
            ibus_engines_of_component "${file}"
        done
    done < <(ibus_component_dirs)
}

# The requested engine when it is installed, else the best known Vietnamese
# engine that is, else nothing: registering an engine IBus has no component for
# would leave the list pointing at a keyboard that cannot be loaded. Takes the
# installed list, so discovery runs once per invocation.
pick_vi_engine() {
    local installed="${1:-}" candidate
    [[ -n ${installed} ]] || return 1
    if grep -qxF -- "${requestedEngine}" <<<"${installed}"; then
        printf '%s\n' "${requestedEngine}"
        return 0
    fi
    for candidate in Unikey Bamboo; do
        if grep -qxF -- "${candidate}" <<<"${installed}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    head -n 1 <<<"${installed}"
}

write_seed_marker() {
    local engine="$1" dir
    dir="$(dirname "${seedMarker}")"
    mkdir -p "${dir}" 2>/dev/null || return 1
    printf 'engine=%s\ndate=%s\n' "${engine}" "$(date -Is 2>/dev/null || date)" >"${seedMarker}" 2>/dev/null
}

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| Registering the engine               |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

seed_vi_engine() {
    local force="${1:-0}"

    if [[ ${requestedEngine} == none ]]; then
        log "ANIDE_IBUS_ENGINE=none; not registering a Vietnamese engine"
        return 0
    fi
    if [[ -f ${seedMarker} && ${force} -ne 1 ]]; then
        return 0
    fi

    local engine installed item
    installed="$(ibus_vi_engines | sort -u)"
    if ! engine="$(pick_vi_engine "${installed}")"; then
        # No marker is written, so an engine installed later is still picked up
        # at the next login.
        log "no Vietnamese IBus engine found; install ibus-unikey or set ANIDE_IBUS_ENGINE"
        return 1
    fi

    local raw
    if ! raw="$(ibus_read preload-engines)"; then
        return 1
    fi
    local -a preload=()
    mapfile -t preload < <(parse_string_array "${raw}")

    # Already usable: the user configured it, or an earlier run did. Recording
    # that here keeps a deliberate removal by the user out of the next login.
    if [[ ${#preload[@]} -gt 0 ]]; then
        for item in "${preload[@]}"; do
            if [[ ${item} == "${engine}" ]] || grep -qxF -- "${item}" <<<"${installed}"; then
                write_seed_marker "${item}"
                printf '[ibus-start] Vietnamese input already registered in IBus: %s.\n' "${item}"
                return 0
            fi
        done
    fi

    local -a updated=()
    if [[ ${#preload[@]} -eq 0 ]]; then
        # IBus' own default for preload-engines is an empty list: it keeps the
        # plain layout engine aside and would make the Vietnamese engine the one
        # every application starts in, where Telex turns "as" into a vowel with
        # a tone on it. What `ibus-setup` writes when the first engine is added
        # is written here instead: the layout engine first, Vietnamese second.
        updated=("${IBUS_LAYOUT_FALLBACK}" "${engine}")
    else
        updated=("${preload[@]}" "${engine}")
    fi
    ibus_write preload-engines "$(format_string_array "${updated[@]}")" || return 1

    # Keep the switching order in step, but only when the user has one: an empty
    # engines-order already means IBus follows preload-engines.
    local orderRaw
    if orderRaw="$(ibus_read engines-order)"; then
        local -a order=()
        mapfile -t order < <(parse_string_array "${orderRaw}")
        if [[ ${#order[@]} -gt 0 ]]; then
            local ordered=0
            for item in "${order[@]}"; do
                [[ ${item} == "${engine}" ]] && ordered=1
            done
            if [[ ${ordered} -eq 0 ]]; then
                ibus_write engines-order "$(format_string_array "${order[@]}" "${engine}")" ||
                    log "engine switch order left unchanged"
            fi
        fi
    fi

    ensure_switch_hotkey
    write_seed_marker "${engine}"
    printf '[ibus-start] Vietnamese input ready: %s is registered in IBus, switch to it with <Control>space.\n' "${engine}"
    notify "Vietnamese input ready" "${engine} was added to IBus. Press Ctrl+Space to switch keyboards."
    return 0
}

# Without a switch key the engine that was just registered cannot be reached.
# IBus used to default to <Control>space and now defaults to <Super>space, a
# chord a compositor is the likeliest to grab -- HyDE's own hyprland.lua
# template suggests binding SUPER+SPACE -- so a key nobody has chosen yet is
# set to <Control>space, what the Vietnamese guides and this repo's docs say.
# "Not chosen yet" is dconf's empty answer for a key sitting at its schema
# default; gsettings would print the default itself and cannot tell the two
# apart, so it is only trusted when dconf is missing.
ensure_switch_hotkey() {
    local chosen=""
    if have dconf; then
        # Anything written counts as chosen, an empty list included -- the user
        # may switch engines from the panel instead. Only a key nobody ever
        # touched is filled in.
        chosen="$(dconf read "${IBUS_HOTKEY_DCONF_PATH}/triggers" 2>/dev/null)" || chosen=""
        [[ -n ${chosen//[[:space:]]/} ]] && return 0
    else
        # Without dconf a schema default and a choice are indistinguishable, so
        # only an empty list is treated as "nobody can switch engines yet".
        chosen="$(hotkey_read)" || chosen=""
        [[ -n $(parse_string_array "${chosen}") ]] && return 0
    fi
    if hotkey_write "$(format_string_array "${IBUS_TRIGGER_FALLBACK}")"; then
        log "engine switch key was not chosen yet; set to ${IBUS_TRIGGER_FALLBACK}"
    fi
    return 0
}

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| Status                               |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

status() {
    local viEngines daemonPath triggers
    viEngines="$(ibus_vi_engines | sort -u | one_line)"
    daemonPath="$(command -v ibus-daemon 2>/dev/null)"

    printf 'AniDE Vietnamese input\n'
    printf '  ANIDE_INPUT_METHOD   : %s\n' "${ANIDE_INPUT_METHOD:-auto}"
    printf '  ANIDE_IBUS_ENGINE    : %s\n' "${requestedEngine}"
    printf '  GTK_IM_MODULE        : %s\n' "${GTK_IM_MODULE:-<unset>}"
    printf '  QT_IM_MODULE         : %s\n' "${QT_IM_MODULE:-<unset>}"
    printf '  XMODIFIERS           : %s\n' "${XMODIFIERS:-<unset>}"
    printf '  ibus-daemon          : %s\n' "${daemonPath:-<not installed>}"
    if have pgrep && pgrep -u "$(id -u)" -x ibus-daemon >/dev/null 2>&1; then
        printf '  daemon running       : yes\n'
    else
        printf '  daemon running       : no\n'
    fi
    if fcitx_running; then
        printf '  fcitx running        : yes (AniDE keeps out of the way)\n'
    else
        printf '  fcitx running        : no\n'
    fi
    printf '  vi engines installed : %s\n' "${viEngines:-<none>}"
    printf '  preload-engines      : %s\n' "$(list_line ibus_read preload-engines)"
    printf '  engines-order        : %s\n' "$(list_line ibus_read engines-order)"
    triggers="$(list_line hotkey_read)"
    printf '  switch key           : %s\n' "${triggers:-<unset>}"
    if [[ ${triggers} == *'<Super>space'* ]]; then
        printf '                         IBus default; a compositor bind on SUPER+SPACE wins over it\n'
    fi
    if [[ -f ${seedMarker} ]]; then
        printf '  registered by AniDE  : %s\n' "$(one_line <"${seedMarker}")"
    else
        printf '  registered by AniDE  : not yet\n'
    fi

    if ! policy_allows_ibus; then
        printf '\nANIDE_INPUT_METHOD=%s disables the AniDE defaults.\n' "${ANIDE_INPUT_METHOD}"
    elif toolkit_env_conflicts; then
        printf '\nAnother input method framework owns the toolkit variables.\n'
    elif [[ -z ${viEngines} ]]; then
        printf '\nNo Vietnamese engine is installed. Install ibus-unikey, then log out and\nback in, or run: hyde-shell ibus-start --seed --force\n'
    else
        printf '\nSwitch engines with %s, or run ibus-setup to change them.\n' "${triggers:-${IBUS_TRIGGER_FALLBACK}}"
    fi
}

#|---/ /+--------------------------------------+---/ /|#
#|--/ /-| Main                                 |-/ /--|#
#|/ /---+--------------------------------------+/ /---|#

while [[ $# -gt 0 ]]; do
    case $1 in
    --seed) flg_SeedOnly=1 ;;
    --force) flg_Force=1 ;;
    --status) flg_Status=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
done

if [[ ${flg_Status} -eq 1 ]]; then
    status
    exit 0
fi

if ! policy_allows_ibus; then
    exit 0
fi
if toolkit_env_conflicts || fcitx_running; then
    exit 0
fi

# A failed registration is no reason to leave the session without IBus: the
# engine can still be added by hand in ibus-setup.
if ! seed_vi_engine "${flg_Force}"; then
    log "Vietnamese engine not registered; see 'hyde-shell ibus-start --status'"
    # Only an explicit request is worth interrupting for: at login this would
    # fire on every session of a machine that simply has no engine installed.
    if [[ ${flg_SeedOnly} -eq 1 || ${flg_Force} -eq 1 ]]; then
        notify "Vietnamese input not registered" "Run 'hyde-shell ibus-start --status' to see why."
    fi
fi

if [[ ${flg_SeedOnly} -eq 1 ]]; then
    exit 0
fi

have ibus-daemon || exit 0
# IBus itself refuses to replace an existing instance without --replace, and
# replacing one would take over a daemon the user started on purpose.
exec ibus-daemon --daemonize --xim
