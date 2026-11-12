# AniTails environment for the Hyprland (uwsm) session.
# Sourced by uwsm after HyDE's own env.d fragments (00-hyde.sh, 01-gpu.sh).

# The only browser that can reach the network: Tor Browser, launched inside its
# own network namespace with an onion-grater filtered ControlPort.
export BROWSER=/usr/local/bin/anitails-tor-browser

# Marker used by /etc/profile.d/99-anitails-session.sh and by AniTails tooling.
export ANITAILS_SESSION=1
export ANITAILS_DESKTOP=hyprland
export ANITAILS_DOTFILES=AniDE

# GTK/Qt are left on their automatic backend selection on purpose: Tor Browser
# and a few Electron helpers still prefer Xwayland, and both xorg-xwayland and
# the Qt/GTK Wayland plugins are installed, so either path works.
