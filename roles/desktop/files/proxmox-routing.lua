-- Routes Proxmox Chromium popouts to dedicated desktops.
-- Lives here (not in openbox rc.xml) because Openbox's <application>
-- block can't match by window title, and title is the only signal that
-- distinguishes popouts: WM_CLASS is "127.0.0.1, Chromium" for every
-- Proxmox-served window. devilspie2 also catches the case where Chromium
-- maps a window before its title is finalised, via the
-- --apply-to-window-name-changes flag in the autostart launch.

if get_window_class() == "Chromium" then
    local title = get_window_name()
    if string.find(title, "noVNC") then
        set_window_workspace(4)
    elseif string.find(title, "Proxmox Console") then
        set_window_workspace(5)
    end
end
