#!/usr/bin/env python3
"""
AniTails — i3 configuration linter.

`i3` re-parses its configuration on every start and on `$mod+Shift+c reload`.
Anything it does not understand is logged and, for grammar errors, raised in an
`i3-nagbar` ("You have an error in your i3 config file!"), while invalid *binding
commands* fail silently at keypress time. Both classes are invisible to a boot
test that only checks that `i3` is running, so this linter walks the config
against the grammar i3 itself ships in `parser-specs/config.spec` and
`parser-specs/commands.spec` and fails the build on any deviation.

Checked here:
  * every top-level directive is a real `config.spec` keyword;
  * every `bar { … }` sub-directive is a real `BAR` state keyword;
  * every colour class has the exact number of colours i3 parses;
  * every `bindsym` has valid modifiers and a unique (mode, key) pair;
  * every binding command matches a `commands.spec` production (kill modes,
    `layout toggle` tokens, resize/floating/fullscreen arguments, …);
  * combinations i3 silently ignores are rejected (e.g. `smart_borders` next to
    `hide_edge_borders`).

Usage:
  python3 scripts/lint-i3-config.py [--config PATH] [--quiet]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = REPO_ROOT / "archiso/airootfs/usr/share/anitails/i3/Configs/.config/i3/config"

# --- grammar tables (transcribed from i3 parser-specs/config.spec) -------------

#: `state INITIAL:` keywords that take a value (or a `{ … }` block).
TOPLEVEL_DIRECTIVES = {
    "set", "set_from_resource", "include", "bindsym", "bindcode", "bind", "bar",
    "font", "mode", "gaps", "smart_borders", "smart_gaps", "floating_minimum_size",
    "floating_maximum_size", "floating_modifier", "default_orientation",
    "workspace_layout", "default_border", "new_window", "default_floating_border",
    "new_float", "hide_edge_borders", "for_window", "assign", "no_focus",
    "focus_follows_mouse", "mouse_warping", "focus_wrapping", "force_focus_wrapping",
    "force_xinerama", "force-xinerama", "disable_randr15", "disable-randr15",
    "workspace_auto_back_and_forth", "fake_outputs", "fake-outputs",
    "force_display_urgency_hint", "focus_on_window_activation", "title_align",
    "show_marks", "workspace", "ipc_socket", "ipc-socket", "ipc_kill_timeout",
    "restart_state", "popup_during_fullscreen", "tiling_drag",
    "exec", "exec_always",
    # colour classes (`state COLOR_SINGLE` / `COLOR_BORDER`)
    "client.background", "client.focused", "client.focused_inactive",
    "client.focused_tab_title", "client.unfocused", "client.urgent",
    "client.placeholder",
}

#: colour classes that take 5 values: border background text indicator child_border
FIVE_COLOUR_CLASSES = {
    "client.focused", "client.focused_inactive", "client.focused_tab_title",
    "client.unfocused", "client.urgent", "client.placeholder",
}

#: `state BAR:` keywords.
BAR_DIRECTIVES = {
    "i3bar_command", "status_command", "workspace_command", "socket_path", "mode",
    "hidden_state", "id", "modifier", "wheel_up_cmd", "wheel_down_cmd", "bindsym",
    "position", "output", "tray_output", "tray_padding", "font", "separator_symbol",
    "binding_mode_indicator", "workspace_buttons", "workspace_min_width",
    "strip_workspace_numbers", "strip_workspace_name", "verbose", "height",
    "padding", "colors",
}

#: `state BAR_COLORS:` keywords that take exactly one colour (the rest take
#: `border background text`).
BAR_SINGLE_COLOUR_CLASSES = {
    "background", "statusline", "separator", "focused_background",
    "focused_statusline", "focused_separator",
}

#: `state BAR_COLORS:` keywords.
BAR_COLOR_CLASSES = {
    "background", "statusline", "separator", "focused_background",
    "focused_statusline", "focused_separator", "focused_workspace",
    "active_workspace", "inactive_workspace", "urgent_workspace", "binding_mode",
}

#: `state BINDING:` modifiers.
MODIFIERS = {
    "Mod1", "Mod2", "Mod3", "Mod4", "Mod5", "Shift", "Control", "Ctrl",
    "Mode_switch", "Group1", "Group2", "Group3", "Group4", "mod", "$mod",
}

#: enumerated values of the directives whose bare keyword is not enough.
ENUM_VALUES = {
    "workspace_layout": {"default", "stacking", "stacked", "tabbed"},
    "hide_edge_borders": {"none", "vertical", "horizontal", "both", "smart",
                          "smart_no_gaps", "1", "yes", "true", "on", "enable", "active"},
    "smart_borders": {"1", "yes", "true", "on", "enable", "active", "no_gaps"},
    "smart_gaps": {"1", "yes", "true", "on", "enable", "active", "0", "no", "false",
                   "off", "disable", "inactive", "inverse_outer"},
    "default_orientation": {"horizontal", "vertical", "auto"},
    "focus_follows_mouse": {"yes", "no", "always", "1", "0", "true", "false"},
    "title_align": {"left", "center", "right"},
    "popup_during_fullscreen": {"smart", "ignore", "leave_fullscreen"},
    "tiling_drag": {"enable", "disable", "toggle", "modifier"},
    "show_marks": {"yes", "no", "1", "0"},
}
BASIC_BOOLEANS = {"yes", "no", "1", "0", "true", "false", "on", "off", "enable",
                  "disable", "active", "inactive"}

BAR_MODE_VALUES = {"dock", "hide", "invisible"}

#: `(pattern, description)` for the command productions AniTails uses or may use.
#: Anything not matched here is reported so nobody silently ships a dead binding.
COMMAND_RULES: tuple[tuple[str, str], ...] = (
    (r"^exec(?: (?:--no-startup-id )?)?\S.*$", "exec [--no-startup-id] <command>"),
    (r"^workspace (?:--no-auto-back-and-forth )?(?:number )?\S+$", "workspace [number] <name>"),
    (r"^move container to workspace (?:number )?\S+$", "move container to workspace [number] <name>"),
    (r"^move to output \S+$", "move to output <output>"),
    (r"^move (?:left|right|up|down)(?: \d+ px)?$", "move <direction> [<px> px]"),
    (r"^focus (?:left|right|up|down)$", "focus <direction>"),
    (r"^focus (?:parent|child|next|prev|floating|tiling)$", "focus <target>"),
    (r"^focus output \S+$", "focus output <output>"),
    (r"^focus mode_toggle$", "focus mode_toggle"),
    (r"^kill(?: (?:window|client))?$", "kill [window|client]"),
    (r"^layout (?:default|splitv|splith|stacking|stacked|tabbed)$", "layout <layout>"),
    (r"^layout toggle(?: \S+)*$", "layout toggle [<layout> …]"),
    (r"^fullscreen (?:enable|disable|toggle)(?: global)?$", "fullscreen <action> [global]"),
    (r"^floating (?:enable|disable|toggle)$", "floating <action>"),
    (r"^mode \S.*$", "mode <name>"),
    (r"^reload$", "reload"),
    (r"^restart$", "restart"),
    (r"^exit$", "exit"),
    (r"^resize (?:grow|shrink) (?:width|height) \d+ px$",
     "resize <grow|shrink> <width|height> <px> px"),
    (r"^split (?:vertical|horizontal|toggle)$", "split <axis|toggle>"),
    (r"^border (?:normal|pixel|none|toggle)(?: -?\d+)?$", "border <style> [<px>]"),
    (r"^sticky (?:enable|disable|toggle)$", "sticky <action>"),
    (r"^scratchpad show$", "scratchpad show"),
    (r"^bar mode (?:dock|hide|invisible|toggle)$", "bar mode <mode>"),
    (r"^move scratchpad$", "move scratchpad"),
    (r"^nop(?: .*)?$", "nop [<comment>]"),
)

#: `layout toggle` accepts these tokens (`con_toggle_layout()` in src/con.c).
LAYOUT_TOGGLE_TOKENS = {"split", "splitv", "splith", "stacking", "stacked", "tabbed",
                        "all", "default"}

COMMENT_RE = re.compile(r"^\s*#")


def _split_bindings(line: str) -> tuple[str, str]:
    """Split `bindsym <keys> <command>` into its key part and command part."""
    rest = line.split(None, 1)[1]
    options = ("--release", "--border", "--whole-window", "--exclude-titlebar")
    while True:
        token = rest.split(None, 1)[0] if rest else ""
        if token in options:
            rest = rest.split(None, 1)[1] if len(rest.split(None, 1)) > 1 else ""
            continue
        if token != "--border" and rest.split(None, 1)[0].startswith("--"):
            rest = rest.split(None, 1)[1] if len(rest.split(None, 1)) > 1 else ""
            continue
        break
    parts = rest.split(None, 1)
    if len(parts) != 2:
        return rest, ""
    return parts[0], parts[1]


def lint(text: str) -> list[str]:
    """Return a list of human-readable problems; empty means the config is valid."""
    problems: list[str] = []
    variables: dict[str, str] = {}

    block: list[str] = []          # [] | ["bar"] | ["bar", "colors"] | ["mode"]
    mode_key = "<default>"         # binding namespace for duplicate detection
    seen_bindings: dict[tuple[str, str], int] = {}
    seen_directives: dict[str, int] = {}
    has_hide_edge_borders = False
    has_smart_borders = False

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or COMMENT_RE.match(raw):
            continue

        # `set $var value`
        if line.startswith("set "):
            _, name, *value = line.split(None, 2)
            if not name.startswith("$"):
                problems.append(f"line {lineno}: `set` expects a $variable name, got {name!r}")
            else:
                variables[name] = (value[0] if value else "").strip()
            continue

        if line == "}":
            if not block:
                problems.append(f"line {lineno}: unexpected closing brace")
            else:
                block_pop = block.pop()
                if block_pop == "colors" and block:
                    pass
                elif block_pop not in {"bar", "colors", "mode"}:
                    problems.append(f"line {lineno}: unexpected closing brace for {block_pop!r}")
            continue

        if not block:
            keyword = line.split(None, 1)[0]
            argument = line.split(None, 1)[1].strip() if len(line.split(None, 1)) > 1 else ""

            if keyword in {"bindsym", "bindcode", "bind"}:
                keys, command = _split_bindings(line)
                keys = _expand(keys, variables)
                command = _expand(command, variables)
                problems.extend(_lint_binding(lineno, keys, command, "<default>",
                                              seen_bindings))
                problems.extend(_lint_command(lineno, command))
                continue

            if keyword in {"exec", "exec_always"}:
                argument = re.sub(r"^--no-startup-id\s+", "", argument).strip()
                if not argument:
                    problems.append(f"line {lineno}: `{keyword}` without a command")
                continue

            if keyword == "mode":
                name = argument.split("{")[0].strip()
                if not name:
                    problems.append(f"line {lineno}: `mode` without a name")
                block.append("mode")
                mode_key = name
                continue

            if keyword == "bar":
                if argument and argument != "{":
                    problems.append(f"line {lineno}: `bar` takes only a `{{` block")
                block.append("bar")
                continue

            if keyword not in TOPLEVEL_DIRECTIVES:
                problems.append(
                    f"line {lineno}: unknown i3 directive {keyword!r} "
                    "(i3 raises a config-error nagbar for this)"
                )
                continue

            seen_directives[keyword] = seen_directives.get(keyword, 0) + 1
            if keyword == "hide_edge_borders":
                has_hide_edge_borders = True
                argument = re.sub(r"^--no-.*$", "", argument).strip()
            if keyword == "smart_borders":
                has_smart_borders = True

            problems.extend(_lint_directive(lineno, keyword, argument, variables))
            continue

        # --- inside a block -------------------------------------------------
        container = block[-1]
        if container == "bar":
            keyword = line.split(None, 1)[0]
            argument = line.split(None, 1)[1].strip() if len(line.split(None, 1)) > 1 else ""
            if keyword == "colors" and argument in {"", "{"}:
                block.append("colors")
                continue
            if keyword not in BAR_DIRECTIVES:
                problems.append(f"line {lineno}: unknown i3bar directive {keyword!r}")
                continue
            if keyword == "mode" and argument not in BAR_MODE_VALUES:
                problems.append(
                    f"line {lineno}: bar mode {argument!r} is not one of "
                    f"{sorted(BAR_MODE_VALUES)}"
                )
            if keyword in {"status_command", "i3bar_command", "workspace_command",
                           "font", "output", "tray_output"} and not argument:
                problems.append(f"line {lineno}: `{keyword}` needs a value")
            continue

        if container == "colors":
            keyword = line.split(None, 1)[0]
            values = line.split()[1:]
            if keyword not in BAR_COLOR_CLASSES:
                problems.append(f"line {lineno}: unknown bar colour class {keyword!r}")
            elif keyword in BAR_SINGLE_COLOUR_CLASSES and len(values) != 1:
                problems.append(
                    f"line {lineno}: bar colour `{keyword}` takes exactly one colour, "
                    f"got {len(values)}"
                )
            elif keyword not in BAR_SINGLE_COLOUR_CLASSES and len(values) != 3:
                problems.append(
                    f"line {lineno}: bar colour `{keyword}` takes 3 colours "
                    f"(border background text), got {len(values)}"
                )
            continue

        if container == "mode":
            keyword = line.split(None, 1)[0]
            if keyword in {"bindsym", "bindcode", "bind"}:
                keys, command = _split_bindings(line)
                keys = _expand(keys, variables)
                command = _expand(command, variables)
                problems.extend(_lint_binding(lineno, keys, command, mode_key,
                                              seen_bindings))
                problems.extend(_lint_command(lineno, command))
            elif keyword not in TOPLEVEL_DIRECTIVES:
                problems.append(f"line {lineno}: unknown directive {keyword!r} in mode block")
            continue

    if block:
        problems.append(f"unclosed block(s) at end of file: {block}")

    if has_smart_borders and has_hide_edge_borders:
        problems.append(
            "`smart_borders` is combined with `hide_edge_borders`: i3 logs "
            "\"Both hide_edge_borders and smart_borders was used. Ignoring "
            "smart_borders as it is deprecated.\" and drops smart_borders — use "
            "`hide_edge_borders smart` (or `smart_no_gaps`) instead"
        )

    return problems


def _expand(text: str, variables: dict[str, str]) -> str:
    """Substitute `$variables` the way i3's parser does before validation."""
    for name, value in variables.items():
        text = text.replace(name, value)
    return text


def _lint_binding(lineno: int, keys: str, command: str, mode_name: str,
                  seen: dict[tuple[str, str], int]) -> list[str]:
    problems: list[str] = []
    if not keys:
        return [f"line {lineno}: binding without a key"]
    if not command:
        problems.append(f"line {lineno}: binding `{keys}` without a command")
        return problems

    if "$" in keys:
        problems.append(
            f"line {lineno}: binding `{keys}` uses a variable that is never `set` — "
            "i3 cannot translate the keysym and raises a config-error nagbar"
        )
        return problems

    tokens = [t for t in keys.split("+") if t != ""]
    if not tokens:
        return [f"line {lineno}: binding `{keys}` has no key"]
    modifiers, key = tokens[:-1], tokens[-1]
    for modifier in modifiers:
        if modifier not in MODIFIERS:
            problems.append(
                f"line {lineno}: unknown modifier {modifier!r} in `{keys}` "
                f"(i3 knows {sorted(MODIFIERS)})"
            )
    if not key:
        return problems + [f"line {lineno}: binding `{keys}` has no key"]

    normalized = "+".join(sorted(modifiers) + [key])
    seen_key = (mode_name, normalized)
    if seen_key in seen:
        problems.append(
            f"line {lineno}: duplicate binding `{keys}` "
            f"(already bound on line {seen[seen_key]}; the later one wins and the "
            f"first becomes dead)"
        )
    else:
        seen[seen_key] = lineno
    return problems


def _lint_command(lineno: int, command: str) -> list[str]:
    problems: list[str] = []
    command = command.strip()
    if not command:
        return [f"line {lineno}: empty binding command"]

    if command.startswith("layout toggle"):
        tokens = command.split()[2:]
        for token in tokens:
            if token not in LAYOUT_TOGGLE_TOKENS:
                problems.append(
                    f"line {lineno}: `layout toggle` token {token!r} is not one of "
                    f"{sorted(LAYOUT_TOGGLE_TOKENS)} (i3 logs \"The token … was not "
                    "recognized and has been skipped\")"
                )
        return problems

    if not any(re.match(pattern, command) for pattern, _ in COMMAND_RULES):
        problems.append(
            f"line {lineno}: binding command {command!r} does not match any i3 "
            "command production (see parser-specs/commands.spec)"
        )
    return problems


def _lint_directive(lineno: int, keyword: str, argument: str,
                    variables: dict[str, str]) -> list[str]:
    problems: list[str] = []

    if keyword in FIVE_COLOUR_CLASSES:
        colours = argument.split()
        if len(colours) != 5:
            problems.append(
                f"line {lineno}: `{keyword}` needs 5 colours "
                "(border background text indicator child_border); the 4- and 3-colour "
                "forms are only accepted for bar colours"
            )
        for colour in colours:
            if colour != "#":
                continue
        return problems

    if keyword == "client.background":
        if len(argument.split()) != 1:
            problems.append(f"line {lineno}: `client.background` takes exactly one colour")
        return problems

    if not argument:
        problems.append(f"line {lineno}: `{keyword}` needs a value")
        return problems

    expanded = argument
    for name, value in variables.items():
        expanded = expanded.replace(name, value)

    if keyword in ENUM_VALUES:
        value = expanded.split()[0]
        if value not in ENUM_VALUES[keyword]:
            problems.append(
                f"line {lineno}: `{keyword}` value {value!r} is not one of "
                f"{sorted(ENUM_VALUES[keyword])}"
            )
        return problems

    if keyword == "gaps":
        parts = expanded.split()
        if parts[0] not in {"inner", "outer", "horizontal", "vertical", "top",
                            "right", "bottom", "left"}:
            problems.append(f"line {lineno}: `gaps` scope {parts[0]!r} is invalid")
        elif len(parts) < 2 or not parts[1].isdigit():
            problems.append(f"line {lineno}: `gaps` needs a pixel value")
        return problems

    if keyword in {"default_border", "new_window", "default_floating_border", "new_float"}:
        parts = expanded.split()
        if parts[0] not in {"normal", "pixel", "1pixel", "none"}:
            problems.append(f"line {lineno}: `{keyword}` style {parts[0]!r} is invalid")
        elif parts[0] == "pixel" and (len(parts) < 2 or not parts[1].lstrip("-").isdigit()):
            problems.append(f"line {lineno}: `{keyword} pixel` needs a pixel width")
        return problems

    if keyword in {"focus_follows_mouse", "mouse_warping", "focus_wrapping",
                   "workspace_auto_back_and_forth", "show_marks", "tiling_drag"}:
        value = expanded.split()[0]
        allowed = BASIC_BOOLEANS | {"output", "none", "no_focus", "force", "yes"}
        if keyword == "focus_wrapping" and value not in {"yes", "no", "force", "workspace",
                                                          "1", "0"}:
            problems.append(f"line {lineno}: `focus_wrapping` value {value!r} is invalid")
        elif keyword == "mouse_warping" and value not in {"none", "output", "yes", "no"}:
            problems.append(f"line {lineno}: `mouse_warping` value {value!r} is invalid")
        elif keyword not in {"focus_wrapping", "mouse_warping"} and value not in allowed:
            problems.append(f"line {lineno}: `{keyword}` value {value!r} is not a boolean")
        return problems

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description="Lint the AniTails i3 configuration")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                        help="path to the i3 config (default: the vendored AniTails config)")
    parser.add_argument("--quiet", action="store_true", help="only print problems")
    args = parser.parse_args()

    if not args.config.is_file():
        print(f"error: i3 config not found: {args.config}", file=sys.stderr)
        return 2

    problems = lint(args.config.read_text(encoding="utf-8"))
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        print(f"FAIL: {len(problems)} i3 config problem(s) in {args.config}", file=sys.stderr)
        return 1

    if not args.quiet:
        lines = len(args.config.read_text(encoding="utf-8").splitlines())
        print(f"PASS: i3 config is valid ({lines} lines, 0 problems): {args.config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
