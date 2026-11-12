#!/usr/bin/env bash
# @name: rofi.movie
# @ver: 1.1.0
# @short: Watch KKPhim movies from Rofi
# @usage: hyde-shell rofi.movie [search|browse|recent|history|play|link|open|settings|diagnose] [args]
# @global.flag: -h,--help | Show this help message
# @cmd: search
# @cmd.alias: s
# @cmd.desc: Search KKPhim and play the selection
# @cmd.opt: <keyword> | Search keyword; Rofi asks when omitted
# @cmd: browse
# @cmd.alias: b
# @cmd.desc: Browse KKPhim categories, genres and countries, page by page
# @cmd: recent
# @cmd.alias: r
# @cmd.desc: Show the latest updates on KKPhim
# @cmd: history
# @cmd.desc: Continue watching from the local history
# @cmd: play
# @cmd.desc: Play a movie slug, asking for server and episode
# @cmd.opt: <slug> | KKPhim movie slug
# @cmd: link
# @cmd.desc: Print the HLS (m3u8) link of one episode instead of playing it
# @cmd.opt: <slug> | KKPhim movie slug
# @cmd.opt: <episode> | Episode name such as "Tập 1"; Rofi asks when omitted
# @cmd: open
# @cmd.desc: Open the movie page in the default browser
# @cmd.opt: <slug> | KKPhim movie slug
# @cmd: settings
# @cmd.desc: Change player, Rofi style, server preference or clear the cache
# @cmd: diagnose
# @cmd.desc: Check dependencies, API reachability and configuration

# KKPhim (https://kkphim.com) movie browser for Rofi.
#
# The data comes from the public KKPhim API (https://phimapi.com), the same
# source anisub's kkphim module uses: a search endpoint, category/genre/country
# listings and a movie detail endpoint holding the HLS (m3u8) link of every
# episode. Those links expire after a few minutes, so detail responses are
# cached for a short TTL and refreshed every time playback starts.
#
# Every screen is `rofi -dmenu`: rows are `|`-separated fields shown with
# -display-columns, and the selected row is parsed back field by field. Rows
# carry an icon (`\0icon\x1f`) with the poster once it is cached. The main menu
# is `-no-custom`: it only ever returns a listed entry, so a stray typed string
# can never be mistaken for a movie slug. Searching has its own entry, and the
# result lists accept free text to filter the current page.
#
# Text is only readable if the layout actually draws it: rofi paints the `-mesg`
# line through the `message` widget, and no HyDE layout lists `message` in its
# mainbox children — so the movie summaries and page counters used to vanish.
# The default style is therefore `movie` (hyde/rofi/themes/movie.rasi), and any
# other vertical layout gets `message` injected into its own children list.

if [[ ${1:-} != "--rofi-script" && ${1:-} != "script" ]]; then
    if [[ ${HYDE_SHELL_INIT:-0} -ne 1 ]] && command -v hyde-shell >/dev/null 2>&1; then
        eval "$(hyde-shell init)"
    elif declare -F export_hyde_config >/dev/null 2>&1; then
        export_hyde_config
    fi
fi

# Work with or without `hyde-shell init`: fall back to this script's own
# location and plain XDG defaults so it can also run (and be tested) standalone.
_hyde_movie_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$(dirname -- "$_hyde_movie_dir")}"
SHARE_DIR="${SHARE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
export HYDE_CONFIG_HOME="${HYDE_CONFIG_HOME:-$XDG_CONFIG_HOME/hyde}"
export HYDE_CACHE_HOME="${HYDE_CACHE_HOME:-$XDG_CACHE_HOME/hyde}"
export HYDE_STATE_HOME="${HYDE_STATE_HOME:-$XDG_STATE_HOME/hyde}"

# ── Settings ──────────────────────────────────────────────────────────────────
# Values come from ~/.config/hyde/config.toml ([rofi.movie] keys are exported
# by hyde-shell as ROFI_MOVIE_*), from the environment, or from these defaults.
MOVIE_SITE_URL="${ROFI_MOVIE_SITE_URL:-https://kkphim.com}"
MOVIE_API_URL="${ROFI_MOVIE_API_URL:-https://phimapi.com}"
MOVIE_CDN_URL="${ROFI_MOVIE_CDN_URL:-https://phimimg.com}"
MOVIE_SERVER_PREF="${ROFI_MOVIE_SERVER_PREF:-auto}"
MOVIE_LIMIT="${ROFI_MOVIE_LIMIT:-24}"
MOVIE_DETAIL_TTL="${ROFI_MOVIE_DETAIL_TTL:-600}"
MOVIE_POSTER="${ROFI_MOVIE_POSTER:-true}"
MOVIE_WIDTH="${ROFI_MOVIE_WIDTH:-46em}"
MOVIE_UA="Mozilla/5.0 (X11; Linux x86_64) AniDE/rofi.movie"
MOVIE_SITE_URL="${MOVIE_SITE_URL%/}"
MOVIE_API_URL="${MOVIE_API_URL%/}"
MOVIE_CDN_URL="${MOVIE_CDN_URL%/}"
MOVIE_REFERER="${MOVIE_SITE_URL}/"
MOVIE_HOST="${MOVIE_SITE_URL#*://}"

if ! [[ $MOVIE_LIMIT =~ ^[0-9]+$ ]] || ((MOVIE_LIMIT < 1 || MOVIE_LIMIT > 64)); then
    MOVIE_LIMIT=24
fi
[[ $MOVIE_DETAIL_TTL =~ ^[0-9]+$ ]] || MOVIE_DETAIL_TTL=600
[[ $MOVIE_SERVER_PREF =~ ^[A-Za-z0-9._-]*$ ]] || MOVIE_SERVER_PREF=auto

MOVIE_CACHE_DIR="${HYDE_CACHE_HOME}/rofi/movie"
MOVIE_POSTER_DIR="${MOVIE_CACHE_DIR}/posters"
MOVIE_DETAIL_DIR="${MOVIE_CACHE_DIR}/detail"
MOVIE_STATE_DIR="${HYDE_STATE_HOME}/movie"
MOVIE_HISTORY_FILE="${MOVIE_STATE_DIR}/history"
MOVIE_QUERY_FILE="${MOVIE_STATE_DIR}/last-query"
MOVIE_HISTORY_MAX=40
MOVIE_POSTER_ROWS=24

# ── Small helpers ─────────────────────────────────────────────────────────────
movie_tmp() {
    mktemp "${TMPDIR:-/tmp}/rofi-movie.XXXXXX" 2>/dev/null ||
        printf '%s/rofi-movie.%s.tmp' "${TMPDIR:-/tmp}" "$$"
}

movie_log() {
    printf '%s\n' "$*" >&2
}

movie_notify() {
    command -v notify-send >/dev/null 2>&1 &&
        notify-send -a "KKPhim" "$1" "${2:-}" >/dev/null 2>&1
    return 0
}

movie_have_rofi() {
    [[ ${ROFI_MOVIE_PROMPT:-0} -eq 1 ]] && return 1
    command -v rofi >/dev/null 2>&1
}

# Fail early with one clear message instead of a broken menu later.
movie_need() {
    local dep missing=()
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        movie_notify "Thiếu công cụ" "${missing[*]}"
        movie_log "❌ Thiếu: ${missing[*]} — cài bằng: sudo pacman -S ${missing[*]}"
        return 1
    fi
    return 0
}

movie_player() {
    local candidate
    for candidate in "${ROFI_MOVIE_PLAYER:-}" mpv vlc celluloid haruna xdg-open; do
        [[ -z $candidate ]] && continue
        command -v "$candidate" >/dev/null 2>&1 && {
            printf '%s' "$candidate"
            return 0
        }
    done
    return 1
}

# Pango escaping for the -mesg summary; '&' first, or entities double up.
movie_markup() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Single-line, pipe-free text safe to embed in a row field.
movie_clean() {
    tr -d '\r\n\t' | sed -e 's/|/ /g' -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}

# ── Rofi plumbing ─────────────────────────────────────────────────────────────

# movie_theme_file <name> → path of that theme, or nothing when unknown.
# Rofi only looks in its own theme directories; the wallpaper cache symlinks
# the HyDE themes there, but that has not necessarily happened yet, so resolve
# the name against the HyDE theme directory first and pass rofi a real path.
movie_theme_file() {
    local name="${1:-}" candidate dir
    [[ -z $name ]] && return 1
    [[ -f $name ]] && {
        printf '%s' "$name"
        return 0
    }
    for dir in "$SHARE_DIR/hyde/rofi/themes" \
        "$XDG_DATA_HOME/hyde/rofi/themes" \
        "$XDG_DATA_HOME/rofi/themes" \
        "$XDG_CONFIG_HOME/rofi/themes"; do
        candidate="${dir%/}/${name}.rasi"
        [[ -f $candidate ]] && {
            printf '%s' "$candidate"
            return 0
        }
    done
    return 1
}

# movie_mesg_override <theme file> → mainbox override that draws the -mesg line.
# Every shipped HyDE layout lists mainbox children without `message`, so rofi
# never paints the message widget: the movie summaries, page counters and hints
# passed with -mesg simply vanished. Re-emit the theme's own children with
# `message` first. Horizontal mainboxes are left alone — a message column there
# would squeeze the list, so those layouts keep today's behaviour.
movie_mesg_override() {
    local file="${1:-}" kids flat
    [[ -f $file ]] || return 1
    # A layout that already places `message` somewhere must not get a second
    # one: rofi aborts with "Message widget can only be added once".
    grep -Eq '^[[:space:]]*children[[:space:]]*:.*message' "$file" && return 1
    kids=$(awk '
        /mainbox[ \t]*\{/ { inblock = 1 }
        inblock && /orientation[ \t]*:[ \t]*horizontal/ { exit 1 }
        inblock && /children[ \t]*:/ {
            line = $0
            sub(/.*children[ \t]*:[ \t]*/, "", line)
            sub(/[ \t]*;.*$/, "", line)
            # Only the widget names survive; the brackets are re-added below.
            gsub(/[\[\]]/, "", line)
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            print line
            exit
        }
        inblock && /^[ \t]*\}[ \t]*$/ { exit 1 }
    ' "$file") || return 1
    [[ -n $kids ]] || return 1
    flat=",$(printf '%s' "$kids" | tr -d ' \t"'),"
    [[ $flat == *,message,* ]] && return 1 # this layout already draws it
    printf 'mainbox{children:[ "message" , %s ];}' "$kids"
}

movie_setup_rofi() {
    local font_scale="${ROFI_MOVIE_SCALE:-${ROFI_SCALE:-10}}"
    [[ $font_scale =~ ^[0-9]+$ ]] || font_scale=10
    ((font_scale < 8 || font_scale > 40)) && font_scale=10
    local font_name="${ROFI_MOVIE_FONT:-${ROFI_FONT:-}}"
    if [[ -z $font_name ]] && declare -F get_hyprConf >/dev/null 2>&1; then
        font_name=$(get_hyprConf "MENU_FONT")
        [[ -z $font_name ]] && font_name=$(get_hyprConf "FONT")
    fi
    font_name="${font_name:-JetBrainsMono Nerd Font}"
    # A font without Vietnamese glyphs turns every title into boxes, so drop
    # quotes and a trailing size ("… Nerd Font 12"): the scale is added below.
    font_name="${font_name//[\"\']/}"
    while [[ $font_name =~ [[:space:]][0-9]+$ ]]; do
        font_name="${font_name% *}"
    done
    font_name="${font_name%"${font_name##*[![:space:]]}"}"
    MOVIE_FONT_NAME="${font_name:-JetBrainsMono Nerd Font}"
    MOVIE_FONT_OVERRIDE="* {font: \"${MOVIE_FONT_NAME} ${font_scale}\";}"

    # Readability, whatever layout is configured: the -mesg line and the row
    # text get explicit colours, the row text is centred against its poster and
    # the input row keeps a visible prompt (even on layouts like clipboard.rasi
    # whose inputbar children only list "entry").
    MOVIE_TEXT_OVERRIDE="message{padding:0.5em 0.9em;border:0px 0px 1px 0px;border-color:@main-br;background-color:@main-bg;text-color:@main-fg;}"
    MOVIE_TEXT_OVERRIDE+="textbox{vertical-align:0.0;horizontal-align:0.0;padding:0.1em 0em;text-color:inherit;background-color:transparent;}"
    MOVIE_TEXT_OVERRIDE+="element{padding:0.45em 0.65em;spacing:0.7em;}"
    MOVIE_TEXT_OVERRIDE+="element-text{vertical-align:0.5;horizontal-align:0.0;text-color:inherit;background-color:transparent;}"
    MOVIE_TEXT_OVERRIDE+="element-icon{size:2.8em;}"
    MOVIE_TEXT_OVERRIDE+="inputbar{children:[ \"prompt\" , \"entry\" ];}"
    MOVIE_TEXT_OVERRIDE+="prompt{enabled:true;padding:0.7em 0.2em 0.7em 0.9em;text-color:@main-br;background-color:transparent;}"
    MOVIE_TEXT_OVERRIDE+="entry{padding:0.7em 0.9em 0.7em 0.2em;text-color:@main-fg;background-color:transparent;}"

    local border="${hypr_border:-}" width="${hypr_width:-}"
    if [[ ! $border =~ ^[0-9]+$ || ! $width =~ ^[0-9]+$ ]] && command -v hyprctl >/dev/null 2>&1; then
        [[ $border =~ ^[0-9]+$ ]] ||
            border=$(hyprctl -j getoption decoration:rounding 2>/dev/null | jq '.int' 2>/dev/null)
        [[ $width =~ ^[0-9]+$ ]] ||
            width=$(hyprctl -j getoption general:border_size 2>/dev/null | jq '.int' 2>/dev/null)
    fi
    [[ $border =~ ^[0-9]+$ ]] || border=10
    [[ $width =~ ^[0-9]+$ ]] || width=2
    local wind_border=$((border * 3 / 2))
    local elem_border=$((border == 0 ? 5 : border))
    MOVIE_RADIUS_OVERRIDE="window{border:${width}px;border-radius:${wind_border}px;}wallbox{border-radius:${elem_border}px;} element{border-radius:${elem_border}px;}"

    # Posters are attached to the rows, so the layout has to ask for icons;
    # without this every downloaded poster stays invisible.
    local icon_theme=""
    declare -F get_hyprConf >/dev/null 2>&1 && icon_theme=$(get_hyprConf "ICON_THEME")
    MOVIE_ICON_OVERRIDE="configuration {show-icons: true;"
    [[ -n $icon_theme ]] && MOVIE_ICON_OVERRIDE+=" icon-theme: \"$icon_theme\";"
    MOVIE_ICON_OVERRIDE+="}"

    MOVIE_ROFI_STYLE="${ROFI_MOVIE_STYLE:-movie}"
    MOVIE_ROFI_THEME=$(movie_theme_file "$MOVIE_ROFI_STYLE") || MOVIE_ROFI_THEME="$MOVIE_ROFI_STYLE"
    MOVIE_MESG_OVERRIDE=$(movie_mesg_override "$MOVIE_ROFI_THEME") || MOVIE_MESG_OVERRIDE=""
    MOVIE_ROFI_ARGS=()
    # config.toml arrays arrive as ("a" "b"); splitting on purpose here.
    # shellcheck disable=SC2206
    [[ -n ${ROFI_MOVIE_ARGS:-} ]] && MOVIE_ROFI_ARGS=(${ROFI_MOVIE_ARGS})
}

# Run rofi with the shared overrides: movie_rofi <args...> (reads stdin).
movie_rofi() {
    movie_setup_rofi
    local -a args=("$@")
    args+=(-theme-str "$MOVIE_RADIUS_OVERRIDE")
    args+=(-theme-str "$MOVIE_FONT_OVERRIDE")
    args+=(-theme-str "$MOVIE_TEXT_OVERRIDE")
    [[ -n $MOVIE_MESG_OVERRIDE ]] && args+=(-theme-str "$MOVIE_MESG_OVERRIDE")
    args+=(-theme-str "$MOVIE_ICON_OVERRIDE")
    args+=(-theme-str "window{width:${MOVIE_WIDTH};}")
    args+=(-config "$MOVIE_ROFI_THEME")
    [[ ${#MOVIE_ROFI_ARGS[@]} -gt 0 ]] && args+=("${MOVIE_ROFI_ARGS[@]}")
    rofi "${args[@]}"
}

# movie_pick <prompt> <mesg> <lines> [extra rofi args...] → chosen row or "".
movie_pick() {
    local prompt="$1" mesg="${2:-}" lines="${3:-10}"
    shift 3 2>/dev/null || true
    local rows sel rc
    rows=$(movie_tmp)
    cat >"$rows"
    if [[ ! -s $rows ]]; then
        rm -f "$rows"
        return 0
    fi
    if ! movie_have_rofi; then
        movie_pick_prompt "$prompt" "$rows"
        return 0
    fi
    local -a args=(-dmenu -i -no-sort -p "$prompt" -l "$lines")
    local cols="1,2" arg
    for arg in "$@"; do
        [[ $arg == "-display-columns" ]] && cols=""
    done
    # Rofi passes -display-column-separator to g_regex_split_simple (GLib PCRE):
    # a bare '|' is an empty alternation regex that splits between every UTF-8
    # character and truncates rows to 2 characters; '[|]' matches a literal pipe.
    args+=(-display-column-separator '[|]')
    # shellcheck disable=SC2054 # "1,2" is rofi's column list, not an array
    [[ -n $cols ]] && args+=(-display-columns "$cols")
    [[ -n $mesg ]] && args+=(-mesg "$mesg")
    args+=(-theme-str "listview{lines:${lines};}")
    (( $# > 0 )) && args+=("$@")
    sel=$(movie_rofi "${args[@]}" <"$rows")
    rc=$?
    rm -f "$rows"
    [[ $rc -eq 1 || -z $sel ]] && return 0
    printf '%s' "$sel"
    return 0
}

# Terminal fallback: numbered list, used when Rofi is absent or disabled.
movie_pick_prompt() {
    local prompt="$1" rows="$2" total i sel choice=""
    total=$(grep -c . "$rows" 2>/dev/null)
    total=${total:-0}
    if [[ $total -eq 0 ]]; then
        rm -f "$rows"
        return 0
    fi
    {
        printf '\n%s\n' "$prompt"
        printf '%s\n' "─────────────────────────────────────────────────"
        i=0
        while IFS= read -r line; do
            [[ -z $line ]] && continue
            i=$((i + 1))
            printf '  %2d) %s\n' "$i" "$(printf '%s' "$line" | awk -F'|' '{print $1 "  " $2}')"
        done <"$rows"
        printf '\n  [q] Thoát\n> '
    } >&2
    read -r sel || sel=q
    if [[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= total)); then
        choice=$(awk -v n="$sel" 'length($0) { c++ } c == n { print; exit }' "$rows")
    fi
    rm -f "$rows"
    printf '%s' "$choice"
}

# movie_ask <prompt> [initial] → typed text (used for keywords and settings).
movie_ask() {
    local prompt="$1" initial="${2:-}" value
    if ! movie_have_rofi; then
        printf '%s: ' "$prompt" >&2
        read -r value || value=""
        printf '%s' "$value"
        return 0
    fi
    local -a args=(-dmenu -i -p "$prompt" -l 0 -display-columns 1)
    args+=(-mesg "Enter để xác nhận · Esc để hủy")
    [[ -n $initial ]] && args+=(-filter "$initial")
    printf '' | movie_rofi "${args[@]}" 2>/dev/null
}

# movie_info <markup message> [prompt]: dismissable message box.
movie_info() {
    local mesg="$1" prompt="${2:-Thông báo}"
    printf '%s\n' "   OK | Đóng" | movie_pick "$prompt" "$mesg" 1 -no-custom >/dev/null
}

movie_progress() {
    movie_log "⏳ $1"
}

# ── KKPhim API ────────────────────────────────────────────────────────────────
# movie_api <path> [key=value...] → JSON on stdout. curl encodes the query, so
# Vietnamese titles with spaces or '&' keep working.
movie_api() {
    local path="${1:-}"
    shift 2>/dev/null || true
    [[ -z $path ]] && return 1
    [[ $path != /* ]] && path="/$path"
    local -a opts=()
    local kv
    for kv in "$@"; do
        [[ -n $kv ]] && opts+=(--data-urlencode "$kv")
    done
    local body status
    body=$(movie_tmp)
    status=$(curl -sS -G -L --compressed --max-time 20 --retry 1 --retry-delay 1 \
        -A "$MOVIE_UA" \
        -H 'accept: application/json' \
        -H 'accept-language: vi,en;q=0.8' \
        -e "$MOVIE_REFERER" \
        -o "$body" -w '%{http_code}' \
        "${opts[@]}" \
        "${MOVIE_API_URL}${path}" 2>/dev/null)
    MOVIE_HTTP_STATUS="${status:-000}"
    case "$MOVIE_HTTP_STATUS" in
        2??)
            if [[ -s $body ]]; then
                cat "$body"
                rm -f "$body"
                return 0
            fi
            ;;
    esac
    rm -f "$body"
    return 1
}

movie_json_ok() {
    jq -e '(.status == true) or (.status == "success")' >/dev/null 2>&1
}

# One jq program for every listing endpoint. It accepts both the current v1
# shape ({"data":{"items":[...]}}) and the legacy one ({"items":[...]}), turns
# relative CDN paths into absolute URLs and emits one `|` row per movie:
#   name (year)|meta|slug|poster|type
# shellcheck disable=SC2016 # $root/$cdn are jq variables, not shell ones
MOVIE_JQ_ROWS='
def s: if . == null then "" else tostring end;
def clean: (s | gsub("[|\\t\\r\\n]"; " ") | gsub("  +"; " ") | sub("^ +"; "") | sub(" +$"; ""));
def img($u; $cdn): ($u | s) as $x
    | if ($x == "" or $x == "null") then ""
      elif ($x | test("^https?://")) then $x
      else ($cdn + "/" + ($x | ltrimstr("/"))) end;
(.data // .) as $root
| (($root.APP_DOMAIN_CDN_IMAGE // "") | s | sub("/+$"; "")) as $cdn0
| (if ($cdn0 == "" or $cdn0 == "null") then $cdn else $cdn0 end) as $cdn
| ($root.items // [])[]
| [ ((.name // .origin_name // "Phim") | clean)
      + (if ((.year | s) | length) > 0 and (.year | s) != "null"
         then " (" + (.year | s) + ")" else "" end),
    ([ .episode_current, .quality, .lang, .time ]
        | map(select(. != null and (. | tostring) != "")) | join(" · ") | clean),
    (.slug // "" | clean),
    img(.poster_url // .thumb_url; $cdn),
    (.type // "" | clean)
  ]
| join("|")
'
MOVIE_JQ_TOTAL='(.data // .) | (.params.pagination.totalPages // .pagination.totalPages // 1)'
MOVIE_JQ_PAGE='(.data // .) | (.params.pagination.currentPage // .pagination.currentPage // 1)'
MOVIE_JQ_MOVIE='(.data // .) | (.movie // .)'

movie_rows() {
    jq -r --arg cdn "$MOVIE_CDN_URL" "$MOVIE_JQ_ROWS" 2>/dev/null | sed '/^$/d'
}

movie_search_json() {
    local keyword="$1"
    [[ ${#keyword} -lt 2 ]] && return 1
    movie_api "/v1/api/tim-kiem" "keyword=$keyword" "page=${2:-1}" "limit=$MOVIE_LIMIT"
}

movie_list_json() {
    local cat="${1:-}" page="${2:-1}" genre="${3:-}" country="${4:-}"
    cat="${cat//[^A-Za-z0-9._-]/}"
    [[ -z $cat ]] && return 1
    if [[ $cat == "phim-moi-cap-nhat" ]]; then
        movie_api "/danh-sach/phim-moi-cap-nhat" "page=$page"
        return
    fi
    local -a params=("page=$page" "limit=$MOVIE_LIMIT")
    [[ -n $genre ]] && params+=("category=$genre")
    [[ -n $country ]] && params+=("country=$country")
    movie_api "/v1/api/danh-sach/${cat}" "${params[@]}"
}

# Full detail of one movie, cached for MOVIE_DETAIL_TTL seconds.
movie_detail_json() {
    local slug="${1:-}" force="${2:-0}" file json age mtime
    [[ -z $slug ]] && return 1
    file="${MOVIE_DETAIL_DIR}/$(printf '%s' "$slug" | tr -c 'A-Za-z0-9_-' '_').json"
    if [[ $force -ne 1 && -s $file ]]; then
        mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null)
        if [[ $mtime =~ ^[0-9]+$ ]]; then
            age=$(($(date +%s) - mtime))
            if ((age < MOVIE_DETAIL_TTL)); then
                cat "$file"
                return 0
            fi
        fi
    fi
    json=$(movie_api "/phim/${slug}")
    if ! printf '%s' "$json" | movie_json_ok; then
        # Network hiccup: a stale copy still lets the user pick an episode.
        if [[ -s $file ]]; then
            cat "$file"
            return 0
        fi
        return 1
    fi
    mkdir -p "$MOVIE_DETAIL_DIR" 2>/dev/null
    printf '%s' "$json" >"$file" 2>/dev/null
    printf '%s' "$json"
}

movie_detail_field() {
    local json="${1:-}" field="${2:-}"
    printf '%s' "$json" | jq -r --arg f "$field" '
        (.data // .) | (.movie // .) | (.[$f] // "")
        | if type == "array" then map(.name // tostring) | join(", ") else tostring end
    ' 2>/dev/null
}

# Servers: "index|name|episode count"
movie_servers() {
    jq -r '((.data // .).episodes // []) | to_entries[]
        | "\(.key)|\(.value.server_name // ("Server " + ((.key + 1) | tostring)))|\(((.value.server_data // []) | length))"' 2>/dev/null
}

# Episodes of one server: "name|m3u8|embed"
movie_episodes() {
    local json="${1:-}" idx="${2:-0}"
    [[ $idx =~ ^[0-9]+$ ]] || idx=0
    printf '%s' "$json" | jq -r --argjson i "$idx" '
        ((.data // .).episodes // []) as $eps
        | (if ($i >= 0 and $i < ($eps | length)) then $eps[$i] else {} end) as $srv
        | (($srv.server_data) // [])[]
        | [ (.name // .slug // "Tập"), (.link_m3u8 // ""), (.link_embed // "") ]
        | join("|")
    ' 2>/dev/null | sed '/^$/d'
}

# Direct stream URL of an episode row; falls back to the ?url= of its embed page.
movie_stream_url() {
    local line="${1:-}" m3u8 embed direct
    m3u8=$(printf '%s' "$line" | awk -F'|' '{print $2}')
    case "$m3u8" in
        http*) printf '%s' "$m3u8"; return 0 ;;
    esac
    embed=$(printf '%s' "$line" | awk -F'|' '{print $3}')
    [[ -z $embed ]] && return 1
    direct=$(printf '%s' "$embed" | sed -n 's/.*[?&]url=\([^&]*\).*/\1/p')
    [[ -z $direct ]] && return 1
    direct=$(printf '%b' "$(printf '%s' "$direct" | sed 's/+/ /g; s/%/\\x/g')")
    case "$direct" in
        http*) printf '%s' "$direct"; return 0 ;;
    esac
    return 1
}

# Human-readable label for the configured server preference (settings menu).
movie_server_pref_label() {
    case "${1,,}" in
        "" | auto | default | none) printf 'Tự động' ;;
        vietsub | sub | vs) printf 'Vietsub' ;;
        long-tieng | longtieng | dub | lt) printf 'Lồng tiếng' ;;
        thuyet-minh | thuyetminh | tm) printf 'Thuyết minh' ;;
        *) printf '%s' "$1" ;;
    esac
}

# The server to preselect: the configured language preference, else the first.
movie_pref_server() {
    local json="${1:-}" pref="${MOVIE_SERVER_PREF,,}" patterns=()
    local i name count first="" chosen="" lname pat
    case "$pref" in
        "" | auto | default | none) patterns=() ;;
        vietsub | sub | vs) patterns=("vietsub" "sub") ;;
        long-tieng | longtieng | dub | lt) patterns=("lồng tiếng" "long tieng" "longtieng") ;;
        thuyet-minh | thuyetminh | tm) patterns=("thuyết minh" "thuyet minh" "thuyetminh") ;;
        *) patterns=("$pref") ;;
    esac
    while IFS='|' read -r i name count; do
        [[ $i =~ ^[0-9]+$ ]] || continue
        [[ -z $first ]] && first="$i"
        [[ -n $chosen ]] && continue
        [[ ${#patterns[@]} -eq 0 ]] && continue
        lname="${name,,}"
        for pat in "${patterns[@]}"; do
            case "$lname" in
                *"$pat"*)
                    chosen="$i"
                    break
                    ;;
            esac
        done
    done < <(movie_servers <<<"$json")
    printf '%s' "${chosen:-${first:-0}}"
}

movie_movie_url() {
    printf '%s/phim/%s' "$MOVIE_SITE_URL" "${1:-}"
}

movie_poster_url() {
    local u="${1:-}"
    [[ -z $u || $u == "null" || $u == "none" ]] && return 1
    case "$u" in
        http://* | https://*) printf '%s' "$u" ;;
        *) printf '%s/%s' "$MOVIE_CDN_URL" "${u#/}" ;;
    esac
}

# ── Poster cache ──────────────────────────────────────────────────────────────
movie_poster_path() {
    local url="${1:-}" name
    [[ -z $url ]] && return 1
    name=$(printf '%s' "$url" | cksum | tr ' ' '-')
    printf '%s/%s-full.png' "$MOVIE_POSTER_DIR" "$name"
}

movie_poster_resize() {
    local src="${1:-}" dst="${2:-}"
    [[ -s $src && -n $dst ]] || return 1
    if command -v magick >/dev/null 2>&1; then
        magick "$src" -resize 664x660^ -gravity north -extent 664x660 "$dst" 2>/dev/null || true
    elif command -v convert >/dev/null 2>&1; then
        convert "$src" -resize 664x660^ -gravity north -extent 664x660 "$dst" 2>/dev/null || true
    fi
    if [[ ! -s $dst ]] && command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -nostdin -loglevel error -y -i "$src" \
            -vf "scale=664:660:force_original_aspect_ratio=increase,crop=664:660" \
            -frames:v 1 "$dst" 2>/dev/null || true
    fi
    if [[ ! -s $dst ]]; then
        cp -f "$src" "$dst" 2>/dev/null || true
    fi
    [[ -s $dst ]]
}

# Download + resize one poster to 664x660 (33.2:33 aspect ratio) so Rofi's
# icon-current-entry preview panel fills the entire background panel edge-to-edge.
movie_poster_fetch() {
    local url="${1:-}" out tmp
    url=$(movie_poster_url "$url") || return 1
    [[ $MOVIE_POSTER == "false" || $MOVIE_POSTER == "0" ]] && return 1
    out=$(movie_poster_path "$url") || return 1
    [[ -s $out ]] && return 0
    mkdir -p "$MOVIE_POSTER_DIR" 2>/dev/null || return 1
    tmp=$(movie_tmp)
    if ! curl -fsSL --max-time 8 -A "$MOVIE_UA" -e "$MOVIE_REFERER" -o "$tmp" "$url" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -s $tmp ]]; then
        movie_poster_resize "$tmp" "$out" || true
    fi
    rm -f "$tmp"
    [[ -s $out ]]
}

# Resolve a cached poster file for a movie slug from its cached detail JSON
# without blocking on network I/O.
movie_cached_slug_poster() {
    local slug="${1:-}" detail_file poster path legacy_name legacy_file
    [[ -z $slug || $MOVIE_POSTER == "false" || $MOVIE_POSTER == "0" ]] && return 1
    detail_file="${MOVIE_DETAIL_DIR}/$(printf '%s' "$slug" | tr -c 'A-Za-z0-9_-' '_').json"
    [[ -s $detail_file ]] || return 1
    poster=$(jq -r "$MOVIE_JQ_MOVIE | (.poster_url // .thumb_url // \"\")" "$detail_file" 2>/dev/null)
    poster=$(movie_poster_url "$poster") || return 1
    path=$(movie_poster_path "$poster") || return 1
    if [[ -s $path ]]; then
        printf '%s' "$path"
        return 0
    fi
    legacy_name=$(printf '%s' "$poster" | cksum | tr ' ' '-')
    for legacy_file in "${MOVIE_POSTER_DIR}/${legacy_name}-lg.png" "${MOVIE_POSTER_DIR}/${legacy_name}.png"; do
        if [[ -s $legacy_file ]]; then
            if movie_poster_resize "$legacy_file" "$path" 2>/dev/null; then
                printf '%s' "$path"
                return 0
            fi
            (movie_poster_fetch "$poster" >/dev/null 2>&1 &)
            printf '%s' "$legacy_file"
            return 0
        fi
    done
    (movie_poster_fetch "$poster" >/dev/null 2>&1 &)
    return 1
}

# Wait for the first MOVIE_POSTER_ROWS posters (these become visible icons right
# away) and fetch the rest in the background for the next visit of this list.
movie_prefetch_posters() {
    local rows="${1:-}" url
    [[ $MOVIE_POSTER == "false" || $MOVIE_POSTER == "0" ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    mkdir -p "$MOVIE_POSTER_DIR" 2>/dev/null || return 0

    local -a urls=()
    while IFS= read -r url; do
        [[ $url == http* ]] && urls+=("$url")
    done < <(awk -F'|' '{print $4}' <<<"$rows")
    [[ ${#urls[@]} -eq 0 ]] && return 0

    for url in "${urls[@]:0:MOVIE_POSTER_ROWS}"; do
        movie_poster_fetch "$url" >/dev/null 2>&1 &
    done
    wait

    # Remainder: detached, so it does not delay the menu; visible next time.
    if ((${#urls[@]} > MOVIE_POSTER_ROWS)); then
        (
            for url in "${urls[@]:MOVIE_POSTER_ROWS}"; do
                movie_poster_fetch "$url" >/dev/null 2>&1
            done
        ) >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
    return 0
}

# Attach the cached poster to each row as a Rofi icon.
movie_rows_with_icons() {
    local line poster path
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        poster=$(printf '%s' "$line" | awk -F'|' '{print $4}')
        path=$(movie_poster_path "$poster" 2>/dev/null)
        if [[ -n $path && -s $path ]]; then
            printf '%s\0icon\x1f%s\n' "$line" "$path"
        else
            printf '%s\n' "$line"
        fi
    done
}

movie_prune_cache() {
    [[ -d $MOVIE_POSTER_DIR ]] &&
        find "$MOVIE_POSTER_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
    [[ -d $MOVIE_DETAIL_DIR ]] &&
        find "$MOVIE_DETAIL_DIR" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null
    return 0
}

# ── History ───────────────────────────────────────────────────────────────────
# One TSV line per movie: timestamp, slug, name, server index, episode name.
movie_history_add() {
    local slug="${1:-}" name="${2:-}" server="${3:-0}" episode="${4:-}" tmp
    [[ -z $slug ]] && return 0
    mkdir -p "$MOVIE_STATE_DIR" 2>/dev/null || return 0
    tmp=$(movie_tmp)
    {
        printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$name" "$server" "$episode"
        if [[ -s $MOVIE_HISTORY_FILE ]]; then
            awk -F'\t' -v s="$slug" '$2 != s' "$MOVIE_HISTORY_FILE" | head -n $((MOVIE_HISTORY_MAX - 1))
        fi
    } >"$tmp" 2>/dev/null
    if [[ -s $tmp ]]; then
        mv -f "$tmp" "$MOVIE_HISTORY_FILE" 2>/dev/null
    fi
    rm -f "$tmp"
    return 0
}

movie_history_lines() {
    [[ -s $MOVIE_HISTORY_FILE ]] || return 0
    awk -F'\t' 'NF >= 5 { print }' "$MOVIE_HISTORY_FILE"
}

# The episode this movie was last watched at (empty when unknown).
movie_history_episode() {
    movie_history_lines | awk -F'\t' -v s="${1:-}" '$2 == s { print $5; exit }'
}

movie_save_query() {
    [[ -z ${1:-} ]] && return 0
    mkdir -p "$MOVIE_STATE_DIR" 2>/dev/null || return 0
    printf '%s\n' "$1" >"$MOVIE_QUERY_FILE" 2>/dev/null
    return 0
}

movie_last_query() {
    [[ -s $MOVIE_QUERY_FILE ]] && head -n 1 "$MOVIE_QUERY_FILE"
    return 0
}

# ── Playback ──────────────────────────────────────────────────────────────────
# KKPhim's CDN checks Referer/User-Agent, so players that support it get both.
movie_play_url() {
    local url="${1:-}" title="${2:-}" player base
    if [[ -z $url ]]; then
        movie_notify "Không phát được" "Tập này không có link stream."
        return 1
    fi
    if ! player=$(movie_player); then
        movie_notify "Thiếu trình phát" "Cài mpv hoặc chọn trình phát trong Cài đặt."
        movie_log "❌ Không thấy mpv/vlc — cài bằng: sudo pacman -S mpv"
        return 1
    fi
    base=$(basename -- "$player")
    case "$base" in
        mpv)
            setsid mpv "$url" --force-media-title="$title" \
                --referrer="$MOVIE_REFERER" --user-agent="$MOVIE_UA" \
                --http-header-fields="Referer: $MOVIE_REFERER" \
                --cache=yes --demuxer-max-bytes=256MiB >/dev/null 2>&1 &
            ;;
        vlc)
            setsid vlc --http-referrer="$MOVIE_REFERER" --http-user-agent="$MOVIE_UA" \
                --meta-title="$title" "$url" >/dev/null 2>&1 &
            ;;
        *)
            setsid "$player" "$url" >/dev/null 2>&1 &
            ;;
    esac
    return 0
}

movie_open_url() {
    local url="${1:-}"
    [[ -z $url ]] && return 0
    if command -v xdg-open >/dev/null 2>&1; then
        setsid xdg-open "$url" >/dev/null 2>&1 &
    else
        movie_log "Mở: $url"
    fi
}

# ── Detail screen ─────────────────────────────────────────────────────────────
# Pango summary shown under the filter box of the episode list.
movie_summary() {
    local json="${1:-}" name origin year rating cats countries quality lang runtime ep content line2=""
    name=$(movie_detail_field "$json" name)
    origin=$(movie_detail_field "$json" origin_name)
    year=$(movie_detail_field "$json" year)
    quality=$(movie_detail_field "$json" quality)
    lang=$(movie_detail_field "$json" lang)
    runtime=$(movie_detail_field "$json" time)
    ep=$(movie_detail_field "$json" episode_current)
    content=$(movie_detail_field "$json" content)
    rating=$(printf '%s' "$json" |
        jq -r "$MOVIE_JQ_MOVIE | (.tmdb.vote_average // .imdb.vote_average // 0) | tostring" 2>/dev/null)
    cats=$(printf '%s' "$json" |
        jq -r "$MOVIE_JQ_MOVIE | (.category // []) | map(.name) | join(\", \")" 2>/dev/null)
    countries=$(printf '%s' "$json" |
        jq -r "$MOVIE_JQ_MOVIE | (.country // []) | map(.name) | join(\", \")" 2>/dev/null)

    {
        printf '<b>%s</b>' "$(printf '%s' "$name" | movie_markup)"
        [[ $year =~ ^[0-9]{4}$ ]] && printf ' (%s)' "$year"
        if [[ $rating =~ ^[0-9.]+$ ]] && [[ $rating != "0" && $rating != "0.0" ]]; then
            printf ' · ⭐ %s' "$rating"
        fi
        printf '\n'
        if [[ -n $origin && $origin != "$name" && $origin != "null" ]]; then
            printf '<i>%s</i>\n' "$(printf '%s' "$origin" | movie_markup)"
        fi
        [[ -n $cats && $cats != "null" ]] && printf '🎭 %s\n' "$(printf '%s' "$cats" | movie_markup)"
        if [[ -n $countries && $countries != "null" ]]; then
            line2+="🌍 $countries"
        fi
        [[ -n $runtime && $runtime != "null" ]] && line2+="${line2:+ · }⏱ $runtime"
        [[ -n $quality && $quality != "null" ]] && line2+="${line2:+ · }📺 $quality"
        [[ -n $lang && $lang != "null" ]] && line2+="${line2:+ · }🔉 $lang"
        [[ -n $line2 ]] && printf '%s\n' "$line2"
        [[ -n $ep && $ep != "null" ]] && printf '🎞 %s\n' "$ep"
        if [[ -n $content && $content != "null" ]]; then
            printf '\n<small>%s…</small>' "$(printf '%s' "${content:0:480}" | movie_markup)"
        fi
    }
}

# movie_choose_server <json> → server index ("" when cancelled)
movie_choose_server() {
    local json="${1:-}" servers count auto_idx rows sel
    servers=$(movie_servers <<<"$json")
    if [[ -z $servers ]]; then
        printf '0'
        return 0
    fi
    count=$(printf '%s\n' "$servers" | grep -c '^[0-9]')
    auto_idx=$(movie_pref_server "$json")
    if [[ $count -le 1 ]]; then
        printf '%s' "$auto_idx"
        return 0
    fi
    rows=$(printf '%s\n' "$servers" | awk -F'|' -v cur="$auto_idx" \
        '{printf "%s%s. %s|%s tập|%s\n", ($1 == cur ? "✔ " : ""), ($1 + 1), $2, $3, $1}')
    sel=$(printf '%s\n' "$rows" |
        movie_pick "🔉 Chọn nguồn phát" "Phụ đề / thuyết minh / lồng tiếng · ✔ là nguồn ưu tiên" 6 -no-custom)
    [[ -z $sel ]] && return 0
    printf '%s' "$sel" | awk -F'|' '{print $3}'
}

# movie_pick_episode <json> <server idx> <preselect> → chosen episode row
movie_pick_episode() {
    local json="${1:-}" idx="${2:-0}" preselect="${3:-}" rows total sel server_name
    rows=$(movie_episodes "$json" "$idx")
    [[ -z $rows ]] && return 0
    total=$(printf '%s\n' "$rows" | grep -c .)
    if [[ $total -eq 1 && -z $preselect ]]; then
        printf '%s' "$rows"
        return 0
    fi
    server_name=$(movie_servers <<<"$json" | awk -F'|' -v i="$idx" '$1 == i { print $2; exit }')
    local -a extra=(-no-custom -display-columns 1)
    [[ -n $preselect ]] && extra+=(-select "$preselect")
    sel=$(printf '%s\n' "$rows" |
        movie_pick "🎬 ${server_name:-Chọn tập}" "$total tập · $MOVIE_HOST · gõ để lọc tập" 12 "${extra[@]}")
    [[ -z $sel ]] && return 0
    printf '%s' "$sel"
}

# Ask the API for a fresh m3u8 of the same episode and play it again.
movie_replay_fresh() {
    local slug="${1:-}" name="${2:-}" server="${3:-0}" ep_name="${4:-}" json row fresh
    json=$(movie_detail_json "$slug" 1)
    [[ -z $json ]] && return 1
    row=$(movie_episodes "$json" "$server" | awk -F'|' -v n="$ep_name" '$1 == n { print; exit }')
    [[ -z $row ]] && row=$(movie_pick_episode "$json" "$server" "$ep_name")
    [[ -z $row ]] && return 1
    ep_name=$(printf '%s' "$row" | awk -F'|' '{print $1}')
    if ! fresh=$(movie_stream_url "$row"); then
        movie_notify "Không có link mới" "$name · $ep_name"
        return 1
    fi
    movie_play_url "$fresh" "$name - $ep_name"
    movie_history_add "$slug" "$name" "$server" "$ep_name"
}

# movie_watch <name> <slug> — detail → server → episode → play.
movie_watch() {
    local name="${1:-Phim}" slug="${2:-}" json summary server_idx episodes ep_row ep_name stream embed title
    [[ -z $slug ]] && return 0
    movie_need curl jq >/dev/null 2>&1 || return 1

    movie_progress "Đang tải $name…"
    json=$(movie_detail_json "$slug")
    if [[ -z $json ]]; then
        movie_log "❌ Không tải được phim '$slug' (HTTP $MOVIE_HTTP_STATUS)"
        movie_info "⚠️ Không lấy được thông tin phim <b>$(printf '%s' "$name" | movie_markup)</b> (HTTP $MOVIE_HTTP_STATUS).\nKiểm tra mạng, hoặc đổi API trong ⚙️ Cài đặt." "Lỗi"
        return 1
    fi
    # `play <slug>` has no display name: take it from the detail response.
    if [[ $name == "$slug" ]]; then
        name=$(movie_detail_field "$json" name)
        name="${name:-$slug}"
    fi
    summary=$(movie_summary "$json")

    server_idx=$(movie_choose_server "$json")
    [[ -z $server_idx ]] && return 0
    episodes=$(movie_episodes "$json" "$server_idx")
    if [[ -z $episodes ]]; then
        # Empty server list: use the first server that actually has episodes.
        server_idx=$(movie_servers <<<"$json" | awk -F'|' '$3 + 0 > 0 { print $1; exit }')
        [[ -z $server_idx ]] && server_idx=0
        episodes=$(movie_episodes "$json" "$server_idx")
    fi
    if [[ -z $episodes ]]; then
        movie_info "$summary\n\n⚠️ Phim này chưa có nguồn phát trên KKPhim." "Không có nguồn"
        return 1
    fi

    ep_row=$(movie_pick_episode "$json" "$server_idx" "$(movie_history_episode "$slug")")
    [[ -z $ep_row ]] && return 0
    ep_name=$(printf '%s' "$ep_row" | awk -F'|' '{print $1}')

    if ! stream=$(movie_stream_url "$ep_row"); then
        embed=$(printf '%s' "$ep_row" | awk -F'|' '{print $3}')
        movie_notify "Không có link trực tiếp" "$name · $ep_name"
        if [[ -n $embed ]]; then
            movie_info "⚠️ KKPhim chỉ có link nhúng cho tập này, không phát trực tiếp được.\nĐang mở trang player trong trình duyệt." "Mở trình duyệt"
            movie_open_url "$embed"
        fi
        return 1
    fi

    title="$name - $ep_name"
    movie_play_url "$stream" "$title" || return 1
    movie_history_add "$slug" "$name" "$server_idx" "$ep_name"
    movie_log "▶ $title"
    # m3u8 links expire: offer to refetch when the user says nothing appeared.
    if [[ ${ROFI_MOVIE_VERIFY:-0} -eq 1 ]]; then
        local ans
        ans=$(printf '%s\n' "✅ Phim đang chạy bình thường" "🔄 Không mở — lấy link mới" |
            movie_pick "Kiểm tra phát" "Link KKPhim hết hạn sau vài phút · $title" 2 -no-custom)
        case "$ans" in
            🔄*) movie_replay_fresh "$slug" "$name" "$server_idx" "$ep_name" ;;
            *) ;;
        esac
    fi
    return 0
}

# ── Lists ─────────────────────────────────────────────────────────────────────
# Row that explains a problem; the whole message is also copied to the log.
movie_notice_row() {
    local msg="$1"
    movie_log "⚠️ $msg"
    printf '⚠️ %s|Chi tiết|none|none|notice\n' "$(printf '%s' "$msg" | movie_clean)"
}

# movie_show_rows <rows> <prompt> <mesg> → the chosen movie row
movie_show_rows() {
    local rows="${1:-}" prompt="${2:-Chọn phim}" mesg="${3:-}" sel
    [[ -z $rows ]] && return 0
    movie_prefetch_posters "$rows"
    sel=$(printf '%s\n' "$rows" | movie_rows_with_icons | movie_pick "$prompt" "$mesg" 12 -no-custom)
    [[ -z $sel ]] && return 0
    # A notice row is a dead end: show the detail on a dismissable screen.
    if [[ $(printf '%s' "$sel" | awk -F'|' '{print $5}') == "notice" ]]; then
        movie_info "$(printf '%s' "$sel" | awk -F'|' '{print $1}' | movie_markup)" "Thông báo"
        return 0
    fi
    printf '%s' "$sel"
}

movie_search() {
    local keyword="${1:-}" json rows sel total pages
    movie_need curl jq >/dev/null 2>&1 || return 1
    [[ -z $keyword ]] && keyword=$(movie_ask "🔎 Tìm phim trên KKPhim" "$(movie_last_query)")
    [[ -z $keyword ]] && return 0
    [[ ${#keyword} -lt 2 ]] && {
        movie_log "Cần ít nhất 2 ký tự để tìm kiếm."
        return 1
    }
    movie_save_query "$keyword"
    movie_progress "Tìm \"$keyword\"…"
    if ! json=$(movie_search_json "$keyword" 1); then
        movie_show_rows "$(movie_notice_row "Không gọi được KKPhim (HTTP $MOVIE_HTTP_STATUS). Kiểm tra mạng, DNS, proxy hoặc đổi API trong Cài đặt.")" \
            "🔎 $keyword" "" >/dev/null
        return 1
    fi
    rows=$(movie_rows <<<"$json")
    if [[ -z $rows ]]; then
        movie_show_rows "$(movie_notice_row "Không tìm thấy phim nào cho \"$keyword\".")" "🔎 $keyword" "" >/dev/null
        return 0
    fi
    total=$(printf '%s\n' "$rows" | grep -c .)
    pages=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_TOTAL" 2>/dev/null)
    [[ $pages =~ ^[0-9]+$ ]] || pages=1
    sel=$(movie_show_rows "$rows" "🔎 $keyword" "$total kết quả · trang 1/$pages · $MOVIE_HOST")
    [[ -z $sel ]] && return 0
    movie_watch "$(printf '%s' "$sel" | awk -F'|' '{print $1}')" \
        "$(printf '%s' "$sel" | awk -F'|' '{print $3}')"
}

movie_categories() {
    cat <<'EOF'
🆕 Phim mới cập nhật|phim-moi-cap-nhat
📺 Phim bộ|phim-bo
🎬 Phim lẻ|phim-le
🧚 Hoạt hình|hoat-hinh
🎥 Phim chiếu rạp|phim-chieu-rap
📼 TV Shows|tv-shows
EOF
}

movie_genres() {
    cat <<'EOF'
💥 Hành động|hanh-dong
😂 Hài hước|hai-huoc
💕 Tình cảm|tinh-cam
👻 Kinh dị|kinh-di
🕵️ Hình sự|hinh-su
🎭 Chính kịch|chinh-kich
🌀 Viễn tưởng|vien-tuong
🚀 Khoa học|khoa-hoc
🧠 Tâm lý|tam-ly
⚔️ Võ thuật|vo-thuat
🗡️ Cổ trang|co-trang
🧙 Thần thoại|than-thoai
🗺️ Phiêu lưu|phieu-luu
🎓 Học đường|hoc-duong
👪 Gia đình|gia-dinh
🏛️ Lịch sử|lich-su
🎵 Âm nhạc|am-nhac
🏆 Thể thao|the-thao
🔞 Phim 18+|phim-18
EOF
}

# Country names without flag emoji: flag glyphs are regional-indicator pairs
# that no Linux font ships, so on Rofi they show up as two boxes.
movie_countries() {
    cat <<'EOF'
Việt Nam|viet-nam
Hàn Quốc|han-quoc
Trung Quốc|trung-quoc
Nhật Bản|nhat-ban
Thái Lan|thai-lan
Âu Mỹ|au-my
Hồng Kông|hong-kong
Đài Loan|dai-loan
Ấn Độ|an-do
Anh|anh
Pháp|phap
Đức|duc
Canada|canada
Úc|uc
Tây Ban Nha|tay-ban-nha
EOF
}

# Catalog browser: category → optional genre/country filter → paged list.
movie_catalog() {
    local sel facet cat genre="" country=""
    sel=$(movie_categories | movie_pick "🍿 Danh mục phim" "Chọn loại phim · Enter để mở danh sách" 10 -no-custom -display-columns 1)
    [[ -z $sel ]] && return 0
    cat=$(printf '%s' "$sel" | awk -F'|' '{print $2}')

    facet=$(printf '%s\n' \
        "▶ Xem tất cả|" \
        "🌍 Lọc theo thể loại|genre" \
        "🗺️ Lọc theo quốc gia|country" |
        movie_pick "$(printf '%s' "$sel" | awk -F'|' '{print $1}')" "Bộ lọc tuỳ chọn cho danh mục này" 3 -no-custom -display-columns 1)
    [[ -z $facet ]] && return 0
    case "$(printf '%s' "$facet" | awk -F'|' '{print $2}')" in
        genre)
            sel=$(movie_genres | movie_pick "🌍 Thể loại" "Lọc phim theo thể loại" 12 -no-custom -display-columns 1)
            [[ -z $sel ]] && return 0
            genre=$(printf '%s' "$sel" | awk -F'|' '{print $2}')
            ;;
        country)
            sel=$(movie_countries | movie_pick "🗺️ Quốc gia" "Lọc phim theo quốc gia" 12 -no-custom -display-columns 1)
            [[ -z $sel ]] && return 0
            country=$(printf '%s' "$sel" | awk -F'|' '{print $2}')
            ;;
        *) ;;
    esac
    movie_browse "$cat" "$genre" "$country"
}

movie_browse() {
    local cat="${1:-}" genre="${2:-}" country="${3:-}" page=1
    local json rows pages cur sel label filters
    movie_need curl jq >/dev/null 2>&1 || return 1
    if [[ -z $cat ]]; then
        movie_catalog
        return
    fi
    label=$({ movie_categories; movie_genres; } | awk -F'|' -v c="$cat" '$2 == c { print $1; exit }')
    label="${label:-$cat}"

    while :; do
        movie_progress "Đang tải $label · trang $page…"
        if ! json=$(movie_list_json "$cat" "$page" "$genre" "$country"); then
            movie_show_rows "$(movie_notice_row "Không tải được danh mục (HTTP $MOVIE_HTTP_STATUS).")" \
                "$label" "" >/dev/null
            return 1
        fi
        rows=$(movie_rows <<<"$json")
        if [[ -z $rows ]]; then
            movie_show_rows "$(movie_notice_row "Danh mục trả về 0 phim (trang $page).")" \
                "$label" "" >/dev/null
            return 0
        fi
        pages=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_TOTAL" 2>/dev/null)
        cur=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_PAGE" 2>/dev/null)
        [[ $pages =~ ^[0-9]+$ ]] || pages=1
        [[ $cur =~ ^[0-9]+$ ]] || cur=$page

        local -a nav=()
        ((cur > 1)) && nav+=("⏮  Trang trước ($cur/$pages)|page|$((cur - 1))|none|nav")
        ((cur < pages)) && nav+=("⏭  Trang sau ($cur/$pages)|page|$((cur + 1))|none|nav")
        nav+=("🏠 Danh mục khác|category|home|none|nav")

        filters=""
        [[ -n $genre ]] && filters+=" · thể loại: $genre"
        [[ -n $country ]] && filters+=" · quốc gia: $country"
        movie_prefetch_posters "$rows"
        sel=$({ printf '%s\n' "$rows"; printf '%s\n' "${nav[@]}"; } | movie_rows_with_icons |
            movie_pick "$label" "Trang $cur/$pages$filters · $MOVIE_HOST · gõ để lọc trang này" 12 -no-custom)
        [[ -z $sel ]] && return 0
        case "$(printf '%s' "$sel" | awk -F'|' '{print $5}')" in
            nav)
                case "$(printf '%s' "$sel" | awk -F'|' '{print $2}')" in
                    page)
                        page=$(printf '%s' "$sel" | awk -F'|' '{print $3}')
                        [[ $page =~ ^[0-9]+$ ]] || page=1
                        ;;
                    *)
                        movie_catalog
                        return 0
                        ;;
                esac
                continue
                ;;
            notice)
                movie_info "$(printf '%s' "$sel" | awk -F'|' '{print $1}' | movie_markup)" "Thông báo"
                return 1
                ;;
            *) ;;
        esac
        movie_watch "$(printf '%s' "$sel" | awk -F'|' '{print $1}')" \
            "$(printf '%s' "$sel" | awk -F'|' '{print $3}')"
        return 0
    done
}

movie_recent() {
    movie_browse "phim-moi-cap-nhat"
}

movie_history_menu() {
    local rows="" ts slug name server episode ago sel
    while IFS=$'\t' read -r ts slug name server episode; do
        [[ -z $slug ]] && continue
        ago=$((($(date +%s) - ts) / 60))
        if ((ago < 60)); then
            ago="${ago} phút trước"
        elif ((ago < 1440)); then
            ago="$((ago / 60)) giờ trước"
        else
            ago="$((ago / 1440)) ngày trước"
        fi
        rows+="$(printf '%s|%s · %s|%s|none|history' "$(printf '%s' "$name" | movie_clean)" \
            "$(printf '%s' "$episode" | movie_clean)" "$ago" "$slug")"$'\n'
    done < <(movie_history_lines)

    if [[ -z $rows ]]; then
        movie_show_rows "$(movie_notice_row "Chưa có phim nào trong lịch sử xem.")" "📜 Tiếp tục xem" "" >/dev/null
        return 0
    fi
    sel=$(printf '%s' "$rows" |
        movie_pick "📜 Tiếp tục xem" "Chọn phim để xem tiếp · lịch sử lưu trên máy" 12 -no-custom)
    [[ -z $sel ]] && return 0
    movie_watch "$(printf '%s' "$sel" | awk -F'|' '{print $1}')" \
        "$(printf '%s' "$sel" | awk -F'|' '{print $4}')"
}

# ── Settings ──────────────────────────────────────────────────────────────────
# Persist a [rofi.movie] key in ~/.config/hyde/config.toml; falls back to the
# HyDE state rc (ROFI_MOVIE_*) when the user has no config.toml yet.
movie_set_config() {
    local key="${1:-}" value="${2:-}" config_file="${XDG_CONFIG_HOME}/hyde/config.toml" tmp toml_value
    # TOML literals: numbers/booleans bare, everything else quoted.
    if [[ $value =~ ^(true|false)$ || $value =~ ^-?[0-9]+$ ]]; then
        toml_value=$value
    else
        toml_value="\"${value//\"/\\\"}\""
    fi
    if [[ -f $config_file ]]; then
        tmp=$(movie_tmp)
        if grep -q '^\[rofi\.movie\]' "$config_file" 2>/dev/null; then
            # Replace the key in place, or append it at the end of the section
            # (before any blank/comment lines that follow it).
            awk -v k="$key" -v v="$toml_value" '
                function flush_held() {
                    if (held != "") { printf "%s", held; held = "" }
                }
                function emit_if_pending() {
                    if (pending && !done) { print k " = " v; done = 1 }
                }
                /^\[/ {
                    emit_if_pending()
                    flush_held()
                    pending = 0
                    sec = $0
                    if (sec == "[rofi.movie]") pending = 1
                    print
                    next
                }
                sec == "[rofi.movie]" && $0 ~ "^[ \t]*" k "[ \t]*=" {
                    flush_held()
                    print k " = " v
                    done = 1
                    next
                }
                # Trailing blank/comment run: hold it back so a missing key can
                # still be appended directly under the last real value.
                sec == "[rofi.movie]" && pending && !done && $0 ~ /^[ \t]*(#.*)?$/ {
                    held = held $0 "\n"
                    next
                }
                {
                    flush_held()
                    print
                }
                END { emit_if_pending(); flush_held() }
            ' "$config_file" >"$tmp" 2>/dev/null && [[ -s $tmp ]] &&
                mv -f "$tmp" "$config_file" 2>/dev/null && return 0
        else
            printf '\n[rofi.movie]\n%s = %s\n' "$key" "$toml_value" >>"$config_file" 2>/dev/null && return 0
        fi
        rm -f "$tmp"
    fi
    if declare -F set_conf >/dev/null 2>&1; then
        set_conf "ROFI_MOVIE_${key^^}" "$value"
        return 0
    fi
    mkdir -p "$XDG_STATE_HOME/hyde" 2>/dev/null
    printf 'ROFI_MOVIE_%s="%s"\n' "${key^^}" "$value" >>"$XDG_STATE_HOME/hyde/staterc"
    return 0
}

movie_choose_style() {
    local theme_file names="" sel
    for theme_file in "$SHARE_DIR"/hyde/rofi/themes/*.rasi; do
        [[ -f $theme_file ]] || continue
        names+="$(basename -- "$theme_file" .rasi)"$'\n'
    done
    if [[ -z $names ]]; then
        movie_ask "🎨 Tên theme Rofi" "$MOVIE_ROFI_STYLE"
        return
    fi
    # The AniSub layout first: it is the one that draws the -mesg line.
    names=$(printf 'movie\n%s\n' "$(printf '%s' "$names" | sed '/^$/d' | sort | grep -vx movie)")
    sel=$(printf '%s\n' "$names" | sed '/^$/d' |
        movie_pick "🎨 Kiểu Rofi" "Theme trong $SHARE_DIR/hyde/rofi/themes" 12 -no-custom)
    printf '%s' "$sel"
}

# Fonts that are installed, so a menu can replace a font that lacks Vietnamese
# glyphs instead of asking the user to type the exact family name.
movie_choose_font() {
    local current="${ROFI_MOVIE_FONT:-${MOVIE_FONT_NAME:-JetBrainsMono Nerd Font}}" fonts="" sel
    fonts=$(printf '%s\n' "$current")
    if command -v fc-list >/dev/null 2>&1; then
        fonts+=$'\n'$(fc-list : family 2>/dev/null |
            tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
            sed '/^$/d' | sort -uf | head -n 240)
    fi
    fonts=$(printf '%s' "$fonts" | awk '!seen[tolower($0)]++ && length($0) > 1')
    if [[ -z $fonts ]]; then
        movie_ask "🔤 Tên font Rofi" "$current"
        return
    fi
    sel=$(printf '%s\n' "$fonts" |
        movie_pick "🔤 Font chữ" "Chọn font có dấu tiếng Việt · dòng đầu là font đang dùng" 14 -no-custom)
    printf '%s' "$sel"
}

movie_settings() {
    local choice value player
    while :; do
        player=$(movie_player 2>/dev/null)
        choice=$(printf '%s\n' \
            "▶ Trình phát|${player:-chưa có}|player" \
            "🎨 Kiểu Rofi|${MOVIE_ROFI_STYLE:-movie}|style" \
            "🔤 Cỡ chữ|${ROFI_MOVIE_SCALE:-${ROFI_SCALE:-10}}|scale" \
            "🔠 Font chữ|${MOVIE_FONT_NAME:-JetBrainsMono Nerd Font}|font" \
            "🔉 Nguồn ưu tiên|$(movie_server_pref_label "$MOVIE_SERVER_PREF")|server" \
            "🖼 Poster trong danh sách|$(if [[ $MOVIE_POSTER == "false" ]]; then echo "Tắt"; else echo "Bật"; fi)|poster" \
            "🔎 Số kết quả mỗi trang|${MOVIE_LIMIT}|limit" \
            "🌐 Tên miền API|${MOVIE_API_URL}|api" \
            "🧹 Xóa cache phim và poster||cache" \
            "🩺 Chẩn đoán kết nối||diagnose" \
            "🔙 Đóng||close" |
            movie_pick "⚙️ Cài đặt phim" "Lưu vào ~/.config/hyde/config.toml mục [rofi.movie]" 12 -no-custom)
        [[ -z $choice ]] && return 0
        case "$(printf '%s' "$choice" | awk -F'|' '{print $3}')" in
            player)
                value=$(printf '%s\n' "mpv|mpv" "vlc|vlc" "celluloid|celluloid" "haruna|haruna" |
                    movie_pick "▶ Trình phát" "Trình phát dùng để xem phim" 4 -no-custom -display-columns 1)
                [[ -z $value ]] && continue
                ROFI_MOVIE_PLAYER=$(printf '%s' "$value" | awk -F'|' '{print $2}')
                movie_set_config "player" "$ROFI_MOVIE_PLAYER"
                ;;
            style)
                value=$(movie_choose_style)
                [[ -z $value ]] && continue
                ROFI_MOVIE_STYLE="$value"
                movie_set_config "style" "$value"
                ;;
            scale)
                value=$(movie_ask "🔤 Cỡ chữ Rofi (8-24)" "${ROFI_MOVIE_SCALE:-10}")
                if ! [[ $value =~ ^[0-9]+$ ]] || ((value < 8 || value > 24)); then
                    continue
                fi
                ROFI_MOVIE_SCALE="$value"
                movie_set_config "scale" "$value"
                ;;
            font)
                value=$(movie_choose_font)
                [[ -z $value ]] && continue
                ROFI_MOVIE_FONT="$value"
                movie_set_config "font" "$value"
                ;;
            server)
                value=$(printf '%s\n' "Tự động|auto" "Vietsub|vietsub" "Lồng tiếng|long-tieng" "Thuyết minh|thuyet-minh" |
                    movie_pick "🔉 Nguồn ưu tiên" "Nguồn được chọn sẵn khi phim có nhiều server" 4 -no-custom -display-columns 1)
                [[ -z $value ]] && continue
                MOVIE_SERVER_PREF=$(printf '%s' "$value" | awk -F'|' '{print $2}')
                movie_set_config "server_pref" "$MOVIE_SERVER_PREF"
                ;;
            poster)
                if [[ $MOVIE_POSTER == "false" ]]; then
                    MOVIE_POSTER=true
                else
                    MOVIE_POSTER=false
                fi
                movie_set_config "poster" "$MOVIE_POSTER"
                ;;
            limit)
                value=$(movie_ask "🔎 Số kết quả mỗi trang (1-64)" "$MOVIE_LIMIT")
                if ! [[ $value =~ ^[0-9]+$ ]] || ((value < 1 || value > 64)); then
                    continue
                fi
                MOVIE_LIMIT="$value"
                movie_set_config "limit" "$value"
                ;;
            api)
                value=$(movie_ask "🌐 Tên miền API" "$MOVIE_API_URL")
                [[ -z $value ]] && continue
                MOVIE_API_URL="${value%/}"
                movie_set_config "api_url" "$MOVIE_API_URL"
                ;;
            cache)
                rm -rf "${MOVIE_CACHE_DIR:?}" 2>/dev/null
                movie_info "🧹 Đã xóa cache phim và poster." "Đã xóa"
                ;;
            diagnose)
                movie_diagnose | movie_pick "🩺 Chẩn đoán" "Kết quả kiểm tra" 16 -no-custom >/dev/null
                ;;
            *) return 0 ;;
        esac
    done
}

# ── Diagnostics ───────────────────────────────────────────────────────────────
# Print "<version>" for a tool, tolerating tools that reject --version.
movie_dep_version() {
    local tool="$1" out
    out=$("$tool" --version 2>/dev/null | head -n 1)
    if [[ -z $out || $out == *"not an option"* ]]; then
        out=$(command -v "$tool" 2>/dev/null)
    fi
    printf '%s' "${out:-?}"
}

movie_diagnose() {
    local dep fail=0 body code count player
    echo "🩺 Chẩn đoán rofi.movie"
    echo "───────────────────────────────────────────────"
    for dep in rofi curl jq awk sed; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf '  ✅ %-8s %s\n' "$dep" "$(movie_dep_version "$dep")"
        else
            printf '  ❌ %-8s chưa cài (sudo pacman -S %s)\n' "$dep" "$dep"
            fail=$((fail + 1))
        fi
    done
    if player=$(movie_player); then
        printf '  ✅ %-8s %s\n' "$player" "$(movie_dep_version "$player")"
    else
        printf '  ❌ %-8s chưa cài (sudo pacman -S mpv)\n' "player"
        fail=$((fail + 1))
    fi
    command -v notify-send >/dev/null 2>&1 || printf '  ⚠️  notify-send: không có thông báo lỗi\n'
    if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
        printf '  ⚠️  imagemagick: poster .webp có thể không hiển thị\n'
    fi
    printf '  ⚙️  api=%s site=%s cdn=%s\n' "$MOVIE_API_URL" "$MOVIE_SITE_URL" "$MOVIE_CDN_URL"
    printf '  ⚙️  limit=%s ttl=%ss server_pref=%s poster=%s\n' \
        "$MOVIE_LIMIT" "$MOVIE_DETAIL_TTL" "$MOVIE_SERVER_PREF" \
        "$(if [[ $MOVIE_POSTER == "false" ]]; then echo off; else echo on; fi)"
    printf '  ⚙️  config=%s\n' "${XDG_CONFIG_HOME}/hyde/config.toml"
    printf '  ⚙️  cache=%s\n' "$MOVIE_CACHE_DIR"
    printf '  → Gọi thử API tìm kiếm…\n'
    body=$(movie_tmp)
    code=$(curl -sS -G -L --compressed --max-time 15 -A "$MOVIE_UA" \
        -H 'accept: application/json' -e "$MOVIE_REFERER" \
        -o "$body" -w '%{http_code}' \
        --data-urlencode "keyword=naruto" --data-urlencode "limit=1" \
        "${MOVIE_API_URL}/v1/api/tim-kiem" 2>/dev/null)
    code="${code:-000}"
    case "$code" in
        2??)
            count=$(jq -r '((.data // .).items // []) | length' "$body" 2>/dev/null)
            count="${count:-0}"
            if ((count > 0)); then
                printf '     ✅ HTTP %s · đọc được danh sách phim\n' "$code"
            else
                printf '     ⚠️  HTTP %s nhưng không đọc được items — API có thể đã đổi\n' "$code"
                head -c 200 "$body" 2>/dev/null
                echo
                fail=$((fail + 1))
            fi
            ;;
        000)
            printf '     ❌ Không kết nối được — kiểm tra mạng/DNS/proxy\n'
            fail=$((fail + 1))
            ;;
        *)
            printf '     ❌ HTTP %s — API trả lỗi hoặc chặn khu vực\n' "$code"
            fail=$((fail + 1))
            ;;
    esac
    rm -f "$body"
    echo "───────────────────────────────────────────────"
    if [[ $fail -eq 0 ]]; then
        echo "✅ Mọi bước đều OK"
    else
        echo "❌ Có $fail bước lỗi"
    fi
}

# ── Rofi script mode (4th tab in SUPER+A / rofilaunch) ────────────────────────
# When registered in `modi: "drun,filebrowser,window,anisub:rofi.movie.sh --rofi-script"`,
# Rofi calls this script with ROFI_RETV (0 = initial list, 1 = selected row,
# 2 = custom input), ROFI_INFO (row payload), ROFI_DATA (persisted state) and
# ROFI_INPUT (typed filter text).
#
# Important script-mode invariants:
#   1. ROFI_RETV=0 runs at Rofi startup even when the user opens `drun`, so the
#      initial home menu must return immediately with zero network I/O.
#   2. Never emit `\0prompt\x1f…`: Rofi overwrites `sw->display_name` with the
#      prompt string, which would replace the `` icon in `mode-switcher`.
#   3. Rofi 1.7.x / rofi-wayland only passes the user's typed text (`*input`) as
#      `$1` when `ROFI_RETV=2` (`MENU_CUSTOM_INPUT`, which requires
#      `state->filtered_lines == 0`); it does NOT export `ROFI_INPUT`. Since
#      `script_token_match` matches typed tokens against `entry.entry` (and
#      `entry.meta`) rather than `entry.display`, `movie_script_row` sets
#      `entry.entry` to `\t` (which `textbox_append_text` never produces because
#      it normalizes typed whitespace to `0x20`) and places the visible label in
#      `\x1fdisplay\x1f<label>`. When `state->text` is empty, Rofi shows all
#      rows with their `display` text; as soon as the user types any search
#      keyword, `filtered_lines` becomes `0` so pressing Enter triggers
#      `ROFI_RETV=2` with `$1 = <typed keyword>`.
#   4. Movie, history, resume and episode rows attach `\x1ficon\x1f<poster>` so
#      `icon-current-entry` inside the launcher's preview panel renders the
#      selected movie's poster.
movie_reload_settings() {
    local config_file="${XDG_CONFIG_HOME}/hyde/config.toml" k v
    if [[ -f "$XDG_STATE_HOME/hyde/staterc" ]]; then
        # shellcheck disable=SC1091
        source "$XDG_STATE_HOME/hyde/staterc" 2>/dev/null || true
    fi
    if [[ -f "$XDG_STATE_HOME/hyde/config" ]]; then
        # shellcheck disable=SC1091
        source "$XDG_STATE_HOME/hyde/config" 2>/dev/null || true
    fi
    if [[ -f $config_file ]]; then
        while IFS='=' read -r k v; do
            [[ -z $k ]] && continue
            case "$k" in
                player) ROFI_MOVIE_PLAYER="$v" ;;
                server_pref) MOVIE_SERVER_PREF="$v" ;;
                poster) MOVIE_POSTER="$v" ;;
                limit)
                    if [[ $v =~ ^[0-9]+$ ]] && ((v >= 1 && v <= 64)); then
                        MOVIE_LIMIT="$v"
                    fi
                    ;;
                api_url) [[ -n $v ]] && MOVIE_API_URL="${v%/}" ;;
                site_url)
                    if [[ -n $v ]]; then
                        MOVIE_SITE_URL="${v%/}"
                        MOVIE_REFERER="${MOVIE_SITE_URL}/"
                        MOVIE_HOST="${MOVIE_SITE_URL#*://}"
                    fi
                    ;;
                cdn_url) [[ -n $v ]] && MOVIE_CDN_URL="${v%/}" ;;
            esac
        done < <(awk '
            /^\[/ { sec = $0; next }
            sec == "[rofi.movie]" && $0 ~ /^[ \t]*[A-Za-z0-9_]+[ \t]*=/ {
                line = $0
                sub(/^[ \t]+/, "", line)
                key = line
                sub(/[ \t]*=.*/, "", key)
                val = line
                sub(/^[^=]*=[ \t]*/, "", val)
                sub(/[ \t]*#.*$/, "", val)
                sub(/[ \t]+$/, "", val)
                gsub(/^"|"$/, "", val)
                gsub(/^'\''|'\''$/, "", val)
                print key "=" val
            }
        ' "$config_file" 2>/dev/null)
    fi
}

movie_script_headers() {
    local data="${1:-menu}" mesg="${2:-}"
    printf '\0no-custom\x1ffalse\n'
    printf '\0markup-rows\x1ffalse\n'
    [[ -n $data ]] && printf '\0data\x1f%s\n' "$data"
    [[ -n $mesg ]] && printf '\0message\x1f%s\n' "$mesg"
}

movie_script_row() {
    local label="$1" info="$2" icon="${3:-}"
    printf '\t\0info\x1f%s\x1fdisplay\x1f%s' "$info" "$label"
    [[ -n $icon ]] && printf '\x1ficon\x1f%s' "$icon"
    printf '\n'
}

movie_script_home() {
    local last slug name ep poster_icon="" last_query
    movie_script_headers "menu" "🎬 AniSub · KKPhim ($MOVIE_HOST)"
    last=$(movie_history_lines | head -n 1)
    if [[ -n $last ]]; then
        slug=$(printf '%s' "$last" | cut -f2 | movie_clean)
        name=$(printf '%s' "$last" | cut -f3 | movie_clean)
        ep=$(printf '%s' "$last" | cut -f5 | movie_clean)
        poster_icon=$(movie_cached_slug_poster "$slug" 2>/dev/null || true)
    fi
    movie_script_row "🔎 Tìm phim (gõ tên phim rồi Enter)…" "search_input" \
        "$poster_icon" "true" "tim phim search"
    if [[ -n ${slug:-} && -n ${name:-} ]]; then
        movie_script_row "▶ Tiếp tục: ${name}${ep:+ · $ep}" "movie|${slug}|${name}||" \
            "$poster_icon" "" "tiep tuc xem resume ${slug//-/ }"
    fi
    last_query=$(movie_last_query | movie_clean)
    if [[ -n $last_query ]]; then
        movie_script_row "🕘 Tìm lại: ${last_query}" "search|${last_query}|1" \
            "" "" "tim lai recent search ${last_query}"
    fi
    movie_script_row "🆕 Phim mới cập nhật" "list|phim-moi-cap-nhat|1||" \
        "" "" "phim moi cap nhat recent"
    movie_script_row "📺 Phim bộ" "list|phim-bo|1||" \
        "" "" "phim bo series"
    movie_script_row "🎬 Phim lẻ" "list|phim-le|1||" \
        "" "" "phim le movie single"
    movie_script_row "🧚 Hoạt hình (Anime)" "list|hoat-hinh|1||" \
        "" "" "hoat hinh anime"
    movie_script_row "🎥 Phim chiếu rạp" "list|phim-chieu-rap|1||" \
        "" "" "phim chieu rap cinema"
    movie_script_row "📼 TV Shows" "list|tv-shows|1||" \
        "" "" "tv shows"
    movie_script_row "🎭 Duyệt theo thể loại…" "genres" \
        "" "" "the loai genre"
    movie_script_row "🌏 Duyệt theo quốc gia…" "countries" \
        "" "" "quoc gia country"
    if [[ -n $last ]]; then
        movie_script_row "📜 Lịch sử xem" "history" \
            "" "" "lich su history"
    fi
    movie_script_row "⚙️ Cài đặt AniSub" "settings" \
        "" "" "cai dat settings"
}

movie_script_search_prompt() {
    local notice="${1:-🔎 Gõ tên phim vào ô tìm kiếm bên trái rồi nhấn Enter}"
    local last_query ts slug name server episode poster_icon
    movie_script_headers "search_prompt" "$notice"
    movie_script_row "🔎 Gõ tên phim vào ô tìm kiếm rồi nhấn Enter…" "search_input" "" "true"
    last_query=$(movie_last_query | movie_clean)
    if [[ -n $last_query ]]; then
        movie_script_row "🕘 Tìm lại gần đây: ${last_query}" "search|${last_query}|1"
    fi
    while IFS=$'\t' read -r ts slug name server episode; do
        [[ -z $slug || -z $name ]] && continue
        name=$(printf '%s' "$name" | movie_clean)
        episode=$(printf '%s' "$episode" | movie_clean)
        poster_icon=$(movie_cached_slug_poster "$slug" 2>/dev/null || true)
        movie_script_row "▶ Xem gần đây: ${name}${episode:+ · $episode}" \
            "movie|${slug}|${name}|${server}|" "$poster_icon"
    done < <(movie_history_lines | head -n 5)
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_emit_movies() {
    local rows="${1:-}" name meta slug poster kind label icon path
    [[ -z $rows ]] && return 0
    movie_prefetch_posters "$rows"
    while IFS='|' read -r name meta slug poster kind; do
        [[ -z $name || $kind == "notice" ]] && continue
        if [[ -n $meta ]]; then
            label="${name} · ${meta}"
        else
            label="$name"
        fi
        icon=""
        if [[ $MOVIE_POSTER != "false" && $MOVIE_POSTER != "0" && -n $poster ]]; then
            path=$(movie_poster_path "$poster" 2>/dev/null)
            [[ -n $path && -s $path ]] && icon="$path"
        fi
        movie_script_row "$label" "movie|${slug}|${name}||${poster}" "$icon" "" "${slug//-/ }"
    done <<<"$rows"
}

movie_script_list() {
    local cat="${1:-phim-moi-cap-nhat}" page="${2:-1}" genre="${3:-}" country="${4:-}"
    local json rows pages cur label state
    [[ $page =~ ^[0-9]+$ ]] || page=1
    label=$({ movie_categories; movie_genres; movie_countries; } | awk -F'|' -v c="$cat" '$2 == c { print $1; exit }')
    label="${label:-$cat}"
    state="list|${cat}|${page}|${genre}|${country}"

    if ! json=$(movie_list_json "$cat" "$page" "$genre" "$country"); then
        movie_script_headers "menu" "⚠️ Không tải được $label"
        movie_script_row "⚠️ Không tải được danh mục (HTTP $MOVIE_HTTP_STATUS)" "menu"
        movie_script_row "🏠 Menu chính AniSub" "menu"
        return 0
    fi
    rows=$(movie_rows <<<"$json")
    if [[ -z $rows ]]; then
        movie_script_headers "menu" "$label"
        movie_script_row "⚠️ Danh mục chưa có phim ở trang $page" "menu"
        movie_script_row "🏠 Menu chính AniSub" "menu"
        return 0
    fi
    pages=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_TOTAL" 2>/dev/null)
    cur=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_PAGE" 2>/dev/null)
    [[ $pages =~ ^[0-9]+$ ]] || pages=1
    [[ $cur =~ ^[0-9]+$ ]] || cur=$page
    state="list|${cat}|${cur}|${genre}|${country}"

    movie_script_headers "$state" "$(printf '%s · Trang %s/%s' "$label" "$cur" "$pages" | movie_markup)"
    movie_script_emit_movies "$rows"
    ((cur < pages)) &&
        movie_script_row "⏭ Trang sau ($((cur + 1))/$pages) — $label" \
            "list|${cat}|$((cur + 1))|${genre}|${country}"
    ((cur > 1)) &&
        movie_script_row "⏮ Trang trước ($((cur - 1))/$pages) — $label" \
            "list|${cat}|$((cur - 1))|${genre}|${country}"
    [[ -n $genre ]] && movie_script_row "🎭 Chọn thể loại khác…" "genres"
    [[ -n $country ]] && movie_script_row "🌏 Chọn quốc gia khác…" "countries"
    movie_script_row "🔎 Tìm phim khác (gõ tên phim rồi Enter)…" "search_input" "" "true"
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_search() {
    local keyword="${1:-}" page="${2:-1}" json rows pages cur state
    keyword=$(printf '%s' "$keyword" | movie_clean)
    [[ $page =~ ^[0-9]+$ ]] || page=1
    if [[ ${#keyword} -lt 2 ]]; then
        movie_script_search_prompt "⚠️ Nhập ít nhất 2 ký tự để tìm phim"
        return 0
    fi
    movie_save_query "$keyword"
    if ! json=$(movie_search_json "$keyword" "$page"); then
        movie_script_headers "menu" "⚠️ Lỗi tìm kiếm"
        movie_script_row "⚠️ Không gọi được KKPhim (HTTP $MOVIE_HTTP_STATUS)" "menu"
        movie_script_row "🔎 Thử tìm lại…" "search_input" "" "true"
        movie_script_row "🏠 Menu chính AniSub" "menu"
        return 0
    fi
    rows=$(movie_rows <<<"$json")
    if [[ -z $rows ]]; then
        movie_script_headers "search_prompt" "🔎 $(printf '%s' "$keyword" | movie_markup)"
        movie_script_row "⚠️ Không tìm thấy phim nào cho \"$keyword\"" "search_input"
        movie_script_row "🔎 Tìm từ khóa khác (gõ tên phim rồi Enter)…" "search_input" "" "true"
        movie_script_row "🏠 Menu chính AniSub" "menu"
        return 0
    fi
    pages=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_TOTAL" 2>/dev/null)
    cur=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_PAGE" 2>/dev/null)
    [[ $pages =~ ^[0-9]+$ ]] || pages=1
    [[ $cur =~ ^[0-9]+$ ]] || cur=$page
    state="search|${keyword}|${cur}"

    movie_script_headers "$state" "🔎 $(printf '%s · Trang %s/%s' "$keyword" "$cur" "$pages" | movie_markup)"
    movie_script_emit_movies "$rows"
    ((cur < pages)) &&
        movie_script_row "⏭ Trang sau ($((cur + 1))/$pages) — 🔎 $keyword" \
            "search|${keyword}|$((cur + 1))"
    ((cur > 1)) &&
        movie_script_row "⏮ Trang trước ($((cur - 1))/$pages) — 🔎 $keyword" \
            "search|${keyword}|$((cur - 1))"
    movie_script_row "🔎 Tìm từ khóa khác (gõ tên phim rồi Enter)…" "search_input" "" "true"
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_genres() {
    local label slug
    movie_script_headers "genres" "🎭 Chọn thể loại phim"
    movie_script_row "🔎 Tìm phim (gõ tên phim rồi Enter)…" "search_input" "" "true"
    while IFS='|' read -r label slug; do
        [[ -z $slug ]] && continue
        movie_script_row "$label" "list|phim-bo|1|${slug}|" "" "" "${slug//-/ }"
    done < <(movie_genres)
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_countries() {
    local label slug
    movie_script_headers "countries" "🌏 Chọn quốc gia"
    movie_script_row "🔎 Tìm phim (gõ tên phim rồi Enter)…" "search_input" "" "true"
    while IFS='|' read -r label slug; do
        [[ -z $slug ]] && continue
        movie_script_row "🌏 $label" "list|phim-bo|1||${slug}" "" "" "${slug//-/ }"
    done < <(movie_countries)
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_history() {
    local ts slug name server episode ago count=0 poster_icon
    movie_script_headers "history" "📜 Lịch sử xem gần đây"
    while IFS=$'\t' read -r ts slug name server episode; do
        [[ -z $slug ]] && continue
        count=$((count + 1))
        ago=$((($(date +%s) - ts) / 60))
        if ((ago < 60)); then
            ago="${ago} phút trước"
        elif ((ago < 1440)); then
            ago="$((ago / 60)) giờ trước"
        else
            ago="$((ago / 1440)) ngày trước"
        fi
        name=$(printf '%s' "$name" | movie_clean)
        episode=$(printf '%s' "$episode" | movie_clean)
        poster_icon=$(movie_cached_slug_poster "$slug" 2>/dev/null || true)
        movie_script_row "${name}${episode:+ · $episode} (${ago})" \
            "movie|${slug}|${name}|${server}|" "$poster_icon" "" "${slug//-/ }"
    done < <(movie_history_lines)
    if ((count == 0)); then
        movie_script_row "⚠️ Chưa có phim nào trong lịch sử xem" "menu"
    else
        movie_script_row "🗑 Xóa toàn bộ lịch sử xem" "history_clear"
    fi
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_settings() {
    local notice="${1:-⚙️ Cài đặt AniSub · lưu vào ~/.config/hyde/config.toml}"
    local cur_player="${ROFI_MOVIE_PLAYER:-$(movie_player || echo mpv)}"
    local cur_srv poster_label
    cur_srv=$(movie_server_pref_label "$MOVIE_SERVER_PREF")
    if [[ $MOVIE_POSTER == "false" || $MOVIE_POSTER == "0" ]]; then
        poster_label="Đang tắt (nhấn để bật)"
    else
        poster_label="Đang bật (nhấn để tắt)"
    fi
    movie_script_headers "settings" "$notice"
    [[ $notice != "⚙️"* ]] && movie_script_row "ℹ️ $notice" "settings"
    movie_script_row "▶ Trình phát video: ${cur_player}" "settings_player"
    movie_script_row "🔉 Nguồn ưu tiên: ${cur_srv}" "settings_server"
    movie_script_row "🖼 Ảnh preview poster: ${poster_label}" "settings_poster_toggle"
    movie_script_row "📄 Số phim mỗi trang: ${MOVIE_LIMIT}" "settings_limit"
    movie_script_row "🧹 Xóa cache phim và poster" "settings_clear_cache"
    movie_script_row "🗑 Xóa lịch sử xem phim" "history_clear"
    movie_script_row "🩺 Chẩn đoán kết nối & hệ thống" "settings_diagnose"
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_settings_player() {
    local p cur="${ROFI_MOVIE_PLAYER:-$(movie_player || echo mpv)}" mark
    movie_script_headers "settings" "▶ Chọn trình phát video"
    for p in mpv vlc celluloid haruna; do
        mark=""
        [[ $p == "$cur" ]] && mark=" (đang dùng)"
        movie_script_row "▶ ${p}${mark}" "settings_set|player|${p}"
    done
    movie_script_row "🔙 Quay lại cài đặt" "settings"
}

movie_script_settings_server() {
    local cur="${MOVIE_SERVER_PREF:-auto}"
    movie_script_headers "settings" "🔉 Chọn nguồn phát ưu tiên"
    movie_script_row "🔉 Tự động$([[ $cur == auto ]] && printf ' (đang dùng)')" "settings_set|server_pref|auto"
    movie_script_row "🔉 Vietsub$([[ $cur == vietsub ]] && printf ' (đang dùng)')" "settings_set|server_pref|vietsub"
    movie_script_row "🔉 Lồng tiếng$([[ $cur == long-tieng ]] && printf ' (đang dùng)')" "settings_set|server_pref|long-tieng"
    movie_script_row "🔉 Thuyết minh$([[ $cur == thuyet-minh ]] && printf ' (đang dùng)')" "settings_set|server_pref|thuyet-minh"
    movie_script_row "🔙 Quay lại cài đặt" "settings"
}

movie_script_settings_limit() {
    local n
    movie_script_headers "settings" "📄 Chọn số phim mỗi trang"
    for n in 12 24 36 48; do
        movie_script_row "📄 ${n} phim / trang$([[ $n == "$MOVIE_LIMIT" ]] && printf ' (đang dùng)')" "settings_set|limit|${n}"
    done
    movie_script_row "🔙 Quay lại cài đặt" "settings"
}

movie_script_diagnose() {
    local line
    movie_script_headers "settings" "🩺 Kết quả chẩn đoán AniSub"
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        movie_script_row "$line" "settings"
    done < <(movie_diagnose)
    movie_script_row "🔙 Quay lại cài đặt" "settings"
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_movie() {
    local slug="${1:-}" name="${2:-Phim}" server_idx="${3:-}" poster_hint="${4:-}" back_state="${5:-menu}"
    local json servers server_name episodes last_ep ep_name poster poster_icon="" path
    [[ -z $back_state || $back_state == movie* ]] && back_state="menu"
    if [[ -z $slug ]] || ! json=$(movie_detail_json "$slug") || [[ -z $json ]]; then
        movie_script_headers "$back_state" "⚠️ Không tải được phim"
        movie_script_row "⚠️ Không lấy được thông tin phim '$name' (HTTP $MOVIE_HTTP_STATUS)" "$back_state"
        movie_script_row "🔙 Quay lại" "$back_state"
        movie_script_row "🏠 Menu chính AniSub" "menu"
        return 0
    fi
    if [[ -z $name || $name == "$slug" ]]; then
        name=$(movie_detail_field "$json" name)
        name="${name:-$slug}"
    fi
    name=$(printf '%s' "$name" | movie_clean)
    poster=$(printf '%s' "$json" | jq -r "$MOVIE_JQ_MOVIE | (.poster_url // .thumb_url // \"\")" 2>/dev/null)
    poster=$(movie_poster_url "$poster" 2>/dev/null || movie_poster_url "$poster_hint" 2>/dev/null || true)
    if [[ $MOVIE_POSTER != "false" && $MOVIE_POSTER != "0" && -n $poster ]]; then
        movie_poster_fetch "$poster" >/dev/null 2>&1 || true
        path=$(movie_poster_path "$poster" 2>/dev/null)
        [[ -n $path && -s $path ]] && poster_icon="$path"
    fi

    servers=$(movie_servers <<<"$json")
    [[ -z $server_idx ]] && server_idx=$(movie_pref_server "$json")
    episodes=$(movie_episodes "$json" "$server_idx")
    if [[ -z $episodes && -n $servers ]]; then
        server_idx=$(printf '%s\n' "$servers" | awk -F'|' '$3 + 0 > 0 { print $1; exit }')
        [[ -z $server_idx ]] && server_idx=0
        episodes=$(movie_episodes "$json" "$server_idx")
    fi
    server_name=$(printf '%s\n' "$servers" | awk -F'|' -v i="$server_idx" '$1 == i { print $2; exit }')

    movie_script_headers "$back_state" "$(movie_summary "$json")"
    if [[ -z $episodes ]]; then
        movie_script_row "⚠️ $name chưa có nguồn phát trên KKPhim" "$back_state" "$poster_icon"
        movie_script_row "🔙 Quay lại" "$back_state" "$poster_icon"
        movie_script_row "🏠 Menu chính AniSub" "menu"
        return 0
    fi

    last_ep=$(movie_history_episode "$slug")
    if [[ -n $last_ep ]] && printf '%s\n' "$episodes" | awk -F'|' -v n="$last_ep" '$1 == n { found=1 } END { exit !found }'; then
        movie_script_row "▶ Xem tiếp ${last_ep} · ${name}${server_name:+ ($server_name)}" \
            "play|${slug}|${name}|${server_idx}|${last_ep}" "$poster_icon"
    fi
    while IFS='|' read -r ep_name _ _; do
        [[ -z $ep_name ]] && continue
        movie_script_row "🎬 ${ep_name} · ${name}${server_name:+ ($server_name)}" \
            "play|${slug}|${name}|${server_idx}|${ep_name}" "$poster_icon"
    done <<<"$episodes"

    local srv_idx srv_name srv_count
    while IFS='|' read -r srv_idx srv_name srv_count; do
        [[ -z $srv_idx || $srv_idx == "$server_idx" ]] && continue
        ((srv_count > 0)) || continue
        movie_script_row "🔉 Đổi nguồn: ${srv_name} (${srv_count} tập)" \
            "movie|${slug}|${name}|${srv_idx}|${poster}" "$poster_icon"
    done <<<"$servers"

    [[ $back_state != "menu" ]] &&
        movie_script_row "🔙 Quay lại danh sách" "$back_state" "$poster_icon"
    movie_script_row "🔎 Tìm phim khác (gõ tên phim rồi Enter)…" "search_input" "$poster_icon" "true"
    movie_script_row "🏠 Menu chính AniSub" "menu"
}

movie_script_play() {
    local slug="${1:-}" name="${2:-Phim}" server_idx="${3:-0}" ep_name="${4:-}"
    local json episodes ep_row stream embed
    [[ -z $slug ]] && return 0
    json=$(movie_detail_json "$slug") || return 1
    if [[ -z $name || $name == "$slug" ]]; then
        name=$(movie_detail_field "$json" name)
        name="${name:-$slug}"
    fi
    episodes=$(movie_episodes "$json" "$server_idx")
    [[ -z $episodes ]] && return 1
    if [[ -n $ep_name ]]; then
        ep_row=$(printf '%s\n' "$episodes" | awk -F'|' -v n="$ep_name" '$1 == n { print; exit }')
    fi
    [[ -z $ep_row ]] && ep_row=$(printf '%s\n' "$episodes" | head -n 1)
    [[ -z $ep_row ]] && return 1
    ep_name=$(printf '%s' "$ep_row" | awk -F'|' '{print $1}')
    if stream=$(movie_stream_url "$ep_row"); then
        movie_play_url "$stream" "${name} - ${ep_name}" </dev/null >/dev/null 2>&1 || return 1
        movie_history_add "$slug" "$name" "$server_idx" "$ep_name"
    else
        embed=$(printf '%s' "$ep_row" | awk -F'|' '{print $3}')
        [[ -n $embed ]] && movie_open_url "$embed"
    fi
    return 0
}

movie_script_mode() {
    local retv="${ROFI_RETV:-0}" info="${ROFI_INFO:-}" data="${ROFI_DATA:-menu}"
    local input="${ROFI_INPUT:-}" sel="${1:-}"
    input=$(printf '%s' "$input" | movie_clean)
    sel=$(printf '%s' "$sel" | movie_clean)
    movie_reload_settings
    if [[ $retv -eq 0 ]]; then
        movie_script_home
        return 0
    fi
    if [[ $retv -eq 2 || -z $info ]]; then
        local query="${input:-$sel}"
        if [[ -n $query ]]; then
            movie_script_search "$query" 1
        else
            movie_script_home
        fi
        return 0
    fi
    if [[ -n $input ]]; then
        movie_script_search "$input" 1
        return 0
    fi
    local action a1 a2 a3 a4
    IFS='|' read -r action a1 a2 a3 a4 <<<"$info"
    case "$action" in
        menu)
            movie_script_home
            ;;
        search_input)
            if [[ -n $input ]]; then
                movie_script_search "$input" 1
            else
                movie_script_search_prompt
            fi
            ;;
        list)
            movie_script_list "${a1:-phim-moi-cap-nhat}" "${a2:-1}" "${a3:-}" "${a4:-}"
            ;;
        search)
            movie_script_search "${a1:-}" "${a2:-1}"
            ;;
        genres)
            movie_script_genres
            ;;
        countries)
            movie_script_countries
            ;;
        history)
            movie_script_history
            ;;
        history_clear)
            rm -f "${MOVIE_HISTORY_FILE:?}" 2>/dev/null || true
            movie_script_settings "✅ Đã xóa lịch sử xem phim"
            ;;
        movie)
            movie_script_movie "${a1:-}" "${a2:-}" "${a3:-}" "${a4:-}" "$data"
            ;;
        play)
            movie_script_play "${a1:-}" "${a2:-}" "${a3:-0}" "${a4:-}"
            ;;
        settings)
            movie_script_settings
            ;;
        settings_player)
            movie_script_settings_player
            ;;
        settings_server)
            movie_script_settings_server
            ;;
        settings_limit)
            movie_script_settings_limit
            ;;
        settings_poster_toggle)
            if [[ $MOVIE_POSTER == "false" || $MOVIE_POSTER == "0" ]]; then
                MOVIE_POSTER="true"
            else
                MOVIE_POSTER="false"
            fi
            movie_set_config "poster" "$MOVIE_POSTER"
            movie_script_settings "✅ Đã cập nhật hiển thị poster: ${MOVIE_POSTER}"
            ;;
        settings_clear_cache)
            rm -rf "${MOVIE_CACHE_DIR:?}" 2>/dev/null || true
            movie_script_settings "✅ Đã xóa cache phim và poster"
            ;;
        settings_diagnose)
            movie_script_diagnose
            ;;
        settings_set)
            if [[ -n $a1 && -n $a2 ]]; then
                movie_set_config "$a1" "$a2"
                movie_reload_settings
            fi
            movie_script_settings "✅ Đã lưu ${a1} = ${a2}"
            ;;
        *)
            movie_script_home
            ;;
    esac
}

# ── Main menu ─────────────────────────────────────────────────────────────────
movie_main_menu() {
    local choice last name slug
    movie_need curl jq >/dev/null 2>&1 || return 1
    while :; do
        local items=("🔎 Tìm phim||search" "🍿 Duyệt danh mục||browse" "🆕 Phim mới cập nhật||recent")
        last=$(movie_history_lines | head -n 1)
        if [[ -n $last ]]; then
            name=$(printf '%s' "$last" | cut -f3 | movie_clean)
            items+=("▶ Tiếp tục xem|$name|resume")
            items+=("📜 Lịch sử xem||history")
        fi
        items+=("⚙️ Cài đặt||settings" "🩺 Chẩn đoán||diagnose")

        # Rofi only hands back a listed row here (-no-custom): typing a title and
        # pressing Enter is handled by the "🔎 Tìm phim" entry, so a custom string
        # can no longer be mistaken for a movie slug.
        choice=$(printf '%s\n' "${items[@]}" |
            movie_pick "🎬 Phim · KKPhim" "Chọn mục bên dưới · $MOVIE_HOST" 9 -no-custom)
        [[ -z $choice ]] && return 0
        case "$(printf '%s' "$choice" | awk -F'|' '{print $3}')" in
            search) movie_search "" ;;
            browse) movie_catalog ;;
            recent) movie_recent ;;
            resume)
                slug=$(printf '%s' "$last" | cut -f2)
                movie_watch "$(printf '%s' "$last" | cut -f3)" "$slug"
                ;;
            history) movie_history_menu ;;
            settings) movie_settings ;;
            diagnose) movie_diagnose | movie_pick "🩺 Chẩn đoán" "Kết quả kiểm tra" 16 -no-custom >/dev/null ;;
            *) movie_search "$(printf '%s' "$choice" | awk -F'|' '{print $1}')" ;;
        esac
    done
}

usage() {
    cat <<'EOF'
Usage: hyde-shell rofi.movie [command] [args]

Commands:
  search [keyword]        Search KKPhim and play the selection
  browse [category]       Browse categories, genres and countries by page
  recent                  Latest updates on KKPhim
  history                 Continue watching (local history)
  play <slug>             Play a movie slug
  link <slug> [episode]   Print the HLS link of an episode instead of playing
  open <slug>             Open the movie page in the browser
  settings                Player, Rofi style, language, cache
  diagnose                Check dependencies and API reachability
  --rofi-script           Rofi script-mode backend for the SUPER+A anisub tab
  (no command)            Open the main menu

Settings in ~/.config/hyde/config.toml under [rofi.movie], or as ROFI_MOVIE_*:
  player        mpv (default), vlc, celluloid, haruna…
  style         Rofi theme name (default: movie — the AniSub layout)
  scale         Rofi font scale (default: ROFI_SCALE or 10)
  font          Rofi font name (default: MENU_FONT)
  server_pref   auto | vietsub | long-tieng | thuyet-minh
  poster        true | false — load posters as row icons
  limit         1-64 results per page (default: 24)
  detail_ttl    seconds to cache movie details (default: 600)
  site_url      default https://kkphim.com
  api_url       default https://phimapi.com
  cdn_url       default https://phimimg.com

Environment only:
  ROFI_MOVIE_PROMPT=1   Use a numbered terminal prompt instead of Rofi
  ROFI_MOVIE_VERIFY=1   Ask after playback whether the stream actually opened
EOF
}

main() {
    local cmd="${1:-menu}"
    shift 2>/dev/null || true
    case "$cmd" in
        -h | --help | help) usage ;;
        menu) movie_main_menu ;;
        search | s) movie_search "${1:-}" ;;
        browse | b) movie_browse "${1:-}" "${2:-}" "${3:-}" ;;
        recent | r) movie_recent ;;
        history) movie_history_menu ;;
        play)
            if [[ -z ${1:-} ]]; then
                printf 'Usage: hyde-shell rofi.movie play <slug>\n' >&2
                exit 1
            fi
            movie_watch "$1" "$1"
            ;;
        link)
            if [[ -z ${1:-} ]]; then
                printf 'Usage: hyde-shell rofi.movie link <slug> [episode]\n' >&2
                exit 1
            fi
            local json idx row="" ep="${2:-}"
            json=$(movie_detail_json "$1") || exit 1
            idx=$(movie_choose_server "$json")
            [[ -z $idx ]] && exit 0
            if [[ -n $ep ]]; then
                # Accept either 1-based episode numbers or the episode name.
                if [[ $ep =~ ^[0-9]+$ ]]; then
                    row=$(movie_episodes "$json" "$idx" | sed -n "${ep}p")
                fi
                [[ -z $row ]] &&
                    row=$(movie_episodes "$json" "$idx" | awk -F'|' -v n="$ep" '$1 == n { print; exit }')
                if [[ -z $row ]]; then
                    printf '❌ Không tìm thấy tập %s trong phim này.\n' "$ep" >&2
                    exit 1
                fi
            fi
            [[ -z $row ]] && row=$(movie_pick_episode "$json" "$idx" "$ep")
            [[ -z $row ]] && exit 0
            movie_stream_url "$row"
            printf '\n'
            ;;
        open)
            if [[ -z ${1:-} ]]; then
                printf 'Usage: hyde-shell rofi.movie open <slug>\n' >&2
                exit 1
            fi
            movie_open_url "$(movie_movie_url "$1")"
            ;;
        settings) movie_settings ;;
        diagnose) movie_diagnose ;;
        --rofi-script | script) movie_script_mode "${1:-}" ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
