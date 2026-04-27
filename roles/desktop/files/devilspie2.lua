-- Master config: tells devilspie2 which scripts handle which events.
-- We register proxmox-routing.lua for both window_open AND window_focus
-- because devilspie2 0.43 (Ubuntu's version) has no name-changed event,
-- and Chromium often maps a popout before the page sets its real title.
-- Re-running the rule on focus gives a second chance once Openbox's
-- <focus>yes</focus> on the Chromium class hands focus to the new popout.

scripts_window_open  = { "proxmox-routing.lua" }
scripts_window_focus = { "proxmox-routing.lua" }
