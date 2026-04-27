-- Routes Proxmox Chromium popouts to dedicated desktops.
-- Lives here (not in openbox rc.xml) because Openbox's <application>
-- block can't match by window title, and title is the only signal that
-- distinguishes popouts: WM_CLASS is "127.0.0.1, Chromium" for every
-- Proxmox-served window. devilspie2 also catches the case where Chromium
-- maps a window before its title is finalised, via the
-- --apply-to-window-name-changes flag in the autostart launch.
--
-- Match on title alone (not class). Chromium has a startup race where a
-- newly-mapped window briefly has no WM_CLASS, and gating on class would
-- silently skip those frames; nothing else on this workstation has
-- "noVNC" or "Proxmox Console" in its title.

local title = get_window_name() or ""
local class = get_window_class() or ""

debug_print("rule fired: class=[" .. class .. "] title=[" .. title .. "]")

if string.find(title, "noVNC") then
    debug_print("  -> set_window_workspace(4)")
    set_window_workspace(4)
elseif string.find(title, "Proxmox Console") then
    debug_print("  -> set_window_workspace(5)")
    set_window_workspace(5)
end
