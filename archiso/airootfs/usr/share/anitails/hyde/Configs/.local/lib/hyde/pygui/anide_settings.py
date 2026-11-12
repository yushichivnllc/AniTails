#!/usr/bin/env python3
"""AniDE Settings: a lightweight front door to the existing desktop tools.

Original implementation inspired by the settings UX of SekaiPop and
end-4/dots-hyprland. GPL-3.0-or-later; see CREDITS.md.
"""
import os
from pathlib import Path
import re
import shutil
import sys

from PyQt6 import QtCore, QtGui, QtWidgets

# Commands are fixed argv lists: no shell evaluation or interpolation of user input.
SECTIONS = (
    ("Appearance", "◈", "Make the desktop yours", (
        ("Curated themes", "Choose a theme and apply its Wallbash colors across your desktop.", ("hyde-shell", "app", "-t", "scope", "--", "theme.select.sh"), ("hyde-shell", "rofi")),
        ("Wallpaper", "Pick a wallpaper using the existing HyDE selector.", ("hyde-shell", "wallpaper", "--select", "--global"), ("hyde-shell", "rofi")),
        ("GTK appearance", "Change GTK themes, icons and fonts with nwg-look.", ("nwg-look",), ("nwg-look",)),
        ("Qt appearance", "Open the Qt 6 appearance tool.", ("qt6ct",), ("qt6ct",)),
    )),
    ("Bar & menus", "▤", "Shape your workspace", (
        ("Quickshell reload", "Reload the Quickshell top bar and refresh Wallbash colors.", ("hyde-shell", "quickshell", "--reload"), ("hyde-shell",)),
        ("Quickshell toggle", "Show or hide the Quickshell top bar.", ("hyde-shell", "quickshell", "--hide"), ("hyde-shell",)),
        ("Keyboard shortcuts", "See the current keybind hints.", ("hyde-shell", "keybinds_hint"), ("hyde-shell", "rofi")),
    )),
    ("Motion & effects", "✦", "Tune the atmosphere", (
        ("Workflows", "Choose a workflow preset for your session.", ("hyde-shell", "workflows", "--select"), ("hyde-shell", "rofi")),
        ("Shaders", "Choose a screen shader, or disable it in the selector.", ("hyde-shell", "shaders", "--select"), ("hyde-shell", "rofi")),
        ("Night light", "Toggle the existing Hyprsunset night-light control.", ("hyde-shell", "hyprsunset", "--toggle"), ("hyde-shell", "hyprctl")),
    )),
    ("Media", "▶", "Watch something tonight", (
        ("Movies (KKPhim)", "Search, browse and play movies from KKPhim without leaving Rofi.", ("hyde-shell", "rofi.movie"), ("hyde-shell", "rofi", "mpv", "curl", "jq")),
        ("Movie history", "Continue a movie you watched before, or clear the local history.", ("hyde-shell", "rofi.movie", "history"), ("hyde-shell", "rofi", "mpv")),
        ("Movie settings", "Pick the player, Rofi style, subtitle preference and cache options.", ("hyde-shell", "rofi.movie", "settings"), ("hyde-shell", "rofi")),
    )),
    ("System", "⚙", "Your desktop essentials", (
        ("Lock screen", "Choose an existing Hyprlock preset.", ("hyde-shell", "lockscreen", "--select"), ("hyde-shell", "rofi")),
        ("Vietnamese input", "Unikey is registered for you at login; change engines, Telex/VNI and the switch key here.", ("ibus-setup",), ("ibus-setup",)),
        ("Register Unikey again", "Add the Vietnamese engine back to IBus, for example after removing it or installing ibus-unikey later.", ("hyde-shell", "ibus-start", "--seed", "--force"), ("hyde-shell",)),
        ("Audio", "Open the system audio mixer.", ("pavucontrol",), ("pavucontrol",)),
        ("Network", "Open NetworkManager connection settings.", ("nm-connection-editor",), ("nm-connection-editor",)),
        ("Bluetooth", "Open Bluetooth Manager.", ("blueman-manager",), ("blueman-manager",)),
    )),
)


def xdg_config_home():
    """Return the XDG config directory; ignore invalid relative XDG paths."""
    path = os.environ.get("XDG_CONFIG_HOME", "")
    return Path(path) if path and os.path.isabs(path) else Path.home() / ".config"


def theme_colors(path):
    """Read only simple hex colors; never execute or interpolate theme contents."""
    colors = {}
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return colors
    for name, value in re.findall(r"(?m)^\s*@define-color\s+(main-bg|main-fg|wb-act-bg|wb-act-fg)\s+(#[0-9a-fA-F]{6}|#[0-9a-fA-F]{3})\s*;", text):
        colors[name] = value
    json_map = {"mainBg": "main-bg", "mainFg": "main-fg", "actBg": "wb-act-bg", "actFg": "wb-act-fg"}
    for key, value in re.findall(r'"(mainBg|mainFg|actBg|actFg)"\s*:\s*"(#[0-9a-fA-F]{6}|#[0-9a-fA-F]{3})"', text):
        colors[json_map[key]] = value
    return colors


def apply_theme(app):
    palette = app.palette()
    colors = theme_colors(xdg_config_home() / "quickshell" / "theme.json")
    # Keep the platform palette when no compatible theme colors are available.
    bg = colors.get("main-bg", palette.color(QtGui.QPalette.ColorRole.Window).name())
    fg = colors.get("main-fg", palette.color(QtGui.QPalette.ColorRole.WindowText).name())
    accent = colors.get("wb-act-bg", palette.color(QtGui.QPalette.ColorRole.Highlight).name())
    accent_fg = colors.get("wb-act-fg", palette.color(QtGui.QPalette.ColorRole.HighlightedText).name())
    app.setStyleSheet(f"""
        QMainWindow, QWidget#root {{ background: {bg}; color: {fg}; }}
        QWidget {{ color: {fg}; font-size: 13px; }}
        QFrame#sidebar {{ background: rgba(128, 128, 128, 18); border-right: 1px solid rgba(160, 160, 160, 55); }}
        QLabel#brand {{ font-size: 24px; font-weight: 700; }}
        QLabel#eyebrow {{ color: {accent}; font-size: 11px; font-weight: 700; }}
        QLabel#heading {{ font-size: 28px; font-weight: 700; }}
        QLabel#subtitle, QLabel#description, QLabel#hint {{ color: {fg}; }}
        QLabel#description {{ font-size: 12px; }}
        QLabel#cardTitle {{ font-size: 15px; font-weight: 600; }}
        QFrame#card {{ background: rgba(128, 128, 128, 18); border: 1px solid rgba(160, 160, 160, 60); border-radius: 15px; }}
        QPushButton {{ background: rgba(128, 128, 128, 28); border: 1px solid rgba(160, 160, 160, 65); border-radius: 10px; padding: 8px 14px; }}
        QPushButton:hover {{ border-color: {accent}; }}
        QPushButton:disabled {{ color: gray; }}
        QPushButton#nav {{ text-align: left; border: none; padding: 11px; }}
        QPushButton#nav:checked {{ background: {accent}; color: {accent_fg}; font-weight: 600; }}
        QLineEdit {{ background: rgba(128, 128, 128, 25); border: 1px solid rgba(160, 160, 160, 65); border-radius: 10px; padding: 9px; }}
        QLineEdit:focus {{ border-color: {accent}; }}
        QScrollArea {{ border: none; background: transparent; }}
    """)


class SettingsWindow(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("AniDE Settings")
        self.resize(960, 680)
        self.setMinimumSize(680, 460)
        self.cards = []
        root = QtWidgets.QWidget(objectName="root")
        self.setCentralWidget(root)
        outer = QtWidgets.QHBoxLayout(root)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)
        sidebar = QtWidgets.QFrame(objectName="sidebar")
        sidebar.setFixedWidth(210)
        nav = QtWidgets.QVBoxLayout(sidebar)
        nav.setContentsMargins(20, 30, 20, 20)
        brand = QtWidgets.QLabel("AniDE", objectName="brand")
        nav.addWidget(brand)
        nav.addWidget(QtWidgets.QLabel("DESKTOP SETTINGS", objectName="eyebrow"))
        nav.addSpacing(28)
        self.buttons = QtWidgets.QButtonGroup(self)
        self.buttons.setExclusive(True)
        self.stack = QtWidgets.QStackedWidget()
        for index, (title, icon, subtitle, actions) in enumerate(SECTIONS):
            button = QtWidgets.QPushButton(f"{icon}   {title}", objectName="nav")
            button.setCheckable(True)
            self.buttons.addButton(button, index)
            nav.addWidget(button)
            self.stack.addWidget(self.make_page(title, subtitle, actions))
        self.buttons.idClicked.connect(self.select_section)
        self.buttons.button(0).setChecked(True)
        nav.addStretch()
        hint = QtWidgets.QLabel("Powered by your existing\nAniDE / HyDE tools", objectName="hint")
        nav.addWidget(hint)
        outer.addWidget(sidebar)
        content = QtWidgets.QWidget()
        content_layout = QtWidgets.QVBoxLayout(content)
        content_layout.setContentsMargins(28, 24, 28, 24)
        self.search = QtWidgets.QLineEdit()
        self.search.setPlaceholderText("Search this section…")
        self.search.textChanged.connect(self.filter_cards)
        content_layout.addWidget(self.search)
        content_layout.addWidget(self.stack, 1)
        self.status = QtWidgets.QLabel("Changes are made by the selected desktop tool.", objectName="hint")
        self.status.setWordWrap(True)
        content_layout.addWidget(self.status)
        outer.addWidget(content, 1)

    def make_page(self, title, subtitle, actions):
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        page = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(page)
        layout.setContentsMargins(2, 22, 10, 4)
        layout.setSpacing(12)
        layout.addWidget(QtWidgets.QLabel(title, objectName="heading"))
        layout.addWidget(QtWidgets.QLabel(subtitle, objectName="subtitle"))
        layout.addSpacing(12)
        for name, description, command, dependencies in actions:
            card = QtWidgets.QFrame(objectName="card")
            row = QtWidgets.QHBoxLayout(card)
            row.setContentsMargins(18, 15, 18, 15)
            text = QtWidgets.QVBoxLayout()
            text.addWidget(QtWidgets.QLabel(name, objectName="cardTitle"))
            desc = QtWidgets.QLabel(description, objectName="description")
            desc.setWordWrap(True)
            text.addWidget(desc)
            row.addLayout(text, 1)
            button = QtWidgets.QPushButton("Open  ↗")
            missing = [dep for dep in dependencies if not shutil.which(dep)]
            if missing:
                button.setEnabled(False)
                button.setToolTip("Missing: " + ", ".join(missing))
                desc.setText(description + "\nMissing: " + ", ".join(missing))
            else:
                button.clicked.connect(lambda checked=False, argv=command, label=name: self.launch(argv, label))
            row.addWidget(button)
            layout.addWidget(card)
            self.cards.append((card, (name + " " + description).casefold()))
        layout.addStretch()
        scroll.setWidget(page)
        return scroll

    def select_section(self, index):
        self.stack.setCurrentIndex(index)
        self.search.clear()

    def filter_cards(self, text):
        query = text.strip().casefold()
        for card, words in self.cards:
            card.setVisible(not query or query in words)

    def launch(self, command, label):
        started, _pid = QtCore.QProcess.startDetached(command[0], list(command[1:]))
        if started:
            self.status.setText(f"Opened {label}. The selected tool manages its own changes.")
        else:
            self.status.setText(f"Could not start {label}. Check that {command[0]} is installed.")


def main():
    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName("AniDE Settings")
    apply_theme(app)
    window = SettingsWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
