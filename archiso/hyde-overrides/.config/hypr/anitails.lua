-- AniTails integration layer for the AniDE/HyDE dotfiles.
--
-- This file is seeded by `anitails-hyde-seed` from
-- /usr/share/anitails/hyde/overrides/ and is loaded last by
-- ~/.config/hypr/hyprland.lua. It only overrides what AniTails must change;
-- every other HyDE keybind, animation and window rule is untouched.
--
-- Why these overrides exist:
--   * AniTails blocks every clearnet destination at the nftables layer, so the
--     HyDE default `firefox` browser would only ever show a connection error.
--     Tor Browser is the one browser the system can actually reach.
--   * The live user `amnesia` has a locked password (`!*` in /etc/shadow) and
--     AniTails forbids passwordless sudo, so a compositor lock screen could
--     never be unlocked. Tails disables screen locking for the same reason.

if not hl then
	return
end

local function have(binary)
	local handle = io.popen("command -v " .. binary .. " 2>/dev/null")
	if not handle then
		return false
	end
	local out = handle:read("*a")
	handle:close()
	return out ~= nil and #out > 0
end

-- Same flag set as HyDE's bind ({description} only), otherwise both binds stay
-- live and the default `firefox` bind would win the race.
hl.bind("SUPER + B", hl.dsp.exec_cmd("/usr/local/bin/anitails-tor-browser"), {
	description = "[AniTails] Tor Browser (all clearnet traffic is dropped)",
})

hl.bind("SUPER + L", hl.dsp.exec_cmd("/usr/local/lib/anitails-hyde-desktop/lockscreen-disabled.sh"), {
	description = "[AniTails] screen locking is disabled on the live system",
})

-- HyDE's status bar is Quickshell, which AniTails does not ship (AUR-only).
-- `bar.sh` already fell back to Waybar at session start; this bind gives the
-- same fallback when the user asks for the bar explicitly.
hl.bind("SUPER + CTRL + B", hl.dsp.exec_cmd("/usr/local/lib/anitails-hyde-desktop/bar.sh --toggle"), {
	description = "[AniTails] show/hide status bar",
})

-- Which HyDE components are present on this ISO, and which were left out for
-- supply-chain reasons (Quickshell bar, hydectl IPC, hyprquery theming).
if have("kitty") then
	hl.bind("SUPER + SHIFT + I", hl.dsp.exec_cmd("kitty --single-instance -e /usr/local/bin/anitails-hyde-doctor"), {
		description = "[AniTails] desktop component status",
	})
end
