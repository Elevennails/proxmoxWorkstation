-- Master config: only declares the focus-event list.
-- devilspie2 defaults all .lua files in this folder to window_open, so
-- proxmox-routing.lua already fires on window_open without an explicit
-- entry. Adding it to scripts_window_focus here gives it a second pass
-- once Openbox's <focus>yes</focus> on the Chromium class hands focus
-- to a newly-mapped popout, in case the title was still a placeholder
-- at window_open time.
--
-- Don't set scripts_window_open explicitly: in devilspie2 0.43, declaring
-- both _open and _focus for the same script appears to clobber the open
-- list (debug confirmed with the prior config).

scripts_window_focus = { "proxmox-routing.lua" }
