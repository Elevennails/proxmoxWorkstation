# proxmoxWorkstation

Ansible playbook that turns a fresh Proxmox VE install into a single-seat
workstation: console user, Xorg + Openbox, tmux, Chromium pointed at the PVE
web UI, and virt-viewer for guest consoles. The root account is locked at
the end of the run (Ubuntu-style: no password auth anywhere, use `sudo`).

## What the playbook does

Roles are executed in the order listed in `site.yml`:

1. **user** — installs `sudo`, creates the admin account (username is
   prompted for at the start of the run), fetches SSH public keys from
   `https://github.com/<workstation_github_user>.keys`, grants `%sudo`
   password-required sudo, and creates a matching `<user>@pam` PVE user with
   the `Administrator` role.
2. **packages** — installs the apt packages listed in
   `group_vars/all.yml` (Xorg, Openbox, xterm, tmux, slock, Chromium,
   virt-viewer, fontconfig, etc.).
3. **neovim** — installs Neovim from the upstream tarball.
4. **nerdfonts** — installs the JetBrainsMono Nerd Font system-wide.
5. **dotfiles** — clones tmux and Neovim dotfile repos into the user's
   home.
6. **desktop** — writes `Xwrapper.config`, the user's `~/.xinitrc`, and
   the Openbox `rc.xml` / `autostart` that define the five-desktop
   layout. Also drops a `systemd-logind` override so the laptop lid is
   ignored and the power button triggers a clean shutdown, and a
   Chromium managed policy that auto-opens downloaded `.vv` SPICE files
   in `virt-viewer` without prompting.
7. **network** — rewrites the `vmbr0` stanza in
   `/etc/network/interfaces` from `inet static` to `inet dhcp`, removing
   any `address` / `gateway` / `netmask` / `dns-*` lines, and reloads
   networking with `ifreload -a`. DNS is then supplied by the DHCP lease
   (dhclient's default `make_resolv_conf` hook writes `/etc/resolv.conf`).
   The original file is saved as `/etc/network/interfaces.pre-dhcp`.
8. **harden** — locks the root account (`passwd -l root`, i.e. no valid
   password hash in `/etc/shadow`) and disables `PermitRootLogin` in
   `sshd_config`. With the account locked, every password-based auth path
   (TTY login, `su`, password SSH, PVE `root@pam`) fails automatically;
   root is reachable only via `sudo` from the admin user.

## Running it

On a freshly installed PVE host, as root:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Elevennails/proxmoxWorkstation/main/bootstrap.sh)"
```

`bootstrap.sh` runs the community-scripts PVE post-install helper, installs
git and ansible, clones this repo to `/opt/proxmoxWorkstation`, and runs
`ansible-playbook site.yml`. The playbook prompts for the admin username.

When the playbook finishes, set a password for the admin user so sudo and
the PVE web UI work:

```sh
passwd <username>   # set the admin user's password (unlocks sudo + PVE UI)
```

Log out of root, log in as the admin user on tty1, and run `startx`.

## First-login plugin activation

The playbook clones the tmux and Neovim configs and pre-fetches plugins, but
each plugin manager still needs a one-time activation inside its host
program before the plugins are usable.

### tmux (TPM)

The `dotfiles` role clones [TPM](https://github.com/tmux-plugins/tpm) to
`~/.tmux/plugins/tpm` and runs its headless `install_plugins` script, so
the plugin trees are already on disk. To load them into your running tmux
session:

1. Start tmux on desktop 1 (xterm autostarts it, or press `Super + T`).
2. Reload the config so TPM picks up the plugin list:
   `prefix + r` if the keybind is defined, otherwise
   `: source-file ~/.tmux.conf` from the tmux command prompt
   (`prefix + :`).
3. Force-install / refresh plugins inside tmux: **`prefix + I`** (capital
   I). TPM will fetch any missing plugins and report when done.

### Neovim (lazy.nvim via kickstart.nvim)

The cloned `~/.config/nvim` is [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim),
which uses [lazy.nvim](https://github.com/folke/lazy.nvim) as its plugin
manager. lazy bootstraps itself on first launch:

1. Run `nvim` once. lazy.nvim will clone itself and the plugins listed in
   the config — let the install screen finish before quitting.
2. After it returns to the editor, run `:Lazy sync` to make sure
   everything is at the pinned version, and `:checkhealth` to confirm
   parsers/LSPs/treesitter compiled cleanly (this is what the new `gcc`
   apt package is for — Treesitter parsers and `telescope-fzf-native`
   need a C compiler).
3. LSP servers and tools are managed by `:Mason`; open it once to install
   any servers kickstart enables by default.

## Root account

After a successful run:

- SSH remote root login: disabled (`PermitRootLogin no`).
- Root password auth: **locked** on every service (TTY, `su`, password SSH,
  PVE `root@pam`). The password field in `/etc/shadow` is `!<hash>`, so no
  password matches.
- To get a root shell, log in as the admin user and run `sudo -i`.
- For the PVE web UI, log in as `<username>@pam` — the playbook already
  grants that account the `Administrator` role.

If you ever need to set a real root password back (e.g. for disaster
recovery), boot to a rescue/single-user shell and run `passwd root`, or
from the admin user run `sudo passwd root` followed by
`sudo passwd -u root`.

## Desktop layout

Openbox is configured with **five** desktops, each dedicated to one task:

| Desktop | Contents |
|---------|----------|
| 1 | Fullscreen xterm running `tmux` |
| 2 | Chromium, fullscreen, pointed at `https://127.0.0.1:8006` (PVE web UI) |
| 3 | `virt-viewer` / `remote-viewer` sessions (SPICE guest consoles) |
| 4 | Proxmox **noVNC** popouts (any window with `noVNC` in the title) |
| 5 | Proxmox **xterm.js** shell popouts (window title contains `Proxmox Console`) |

The Openbox `autostart` launches desktops 1 and 2 on login. virt-viewer
windows are routed to desktop 3 automatically via an `application` rule in
`rc.xml`. Desktops 4 and 5 are populated by a small `wmctrl` poll loop
also started from `autostart`: it ticks every 4 seconds, finds any
Chromium popout whose title matches the noVNC / Proxmox Console patterns,
moves it to the correct desktop, and switches the active workspace so the
popout is in front of you. Each move is appended to
`~/.cache/proxmox-routing.log` for inspection.

When Chromium, xterm, and all viewer processes have exited, Openbox exits
and you return to the login prompt.

## System policies

Set up by the **desktop** role for laptop-as-workstation use:

- **Lid switch ignored** on AC, battery, and dock — the lid never
  triggers suspend (`/etc/systemd/logind.conf.d/10-workstation-power.conf`).
- **Power button = poweroff** — pressing the laptop power button performs
  a clean shutdown via systemd-logind.
- **No screen blanking** — `xset s off / s noblank / -dpms` runs at
  session start, so the display never blanks while you're logged in.
- **Auto-open `.vv` SPICE files** — a Chromium managed policy at
  `/etc/chromium/policies/managed/proxmox-spice.json` lists `vv` in
  `AutoOpenFileTypes`, so clicking the Proxmox "Console (SPICE)" button
  hands the download straight to `virt-viewer` without a save prompt.

## Key bindings

Defined in `roles/desktop/files/rc.xml`.

### Switch desktop / cycle windows

| Keys | Action |
|------|--------|
| `Ctrl + Alt + 1…5` | Go to desktop 1–5 |
| `Super + 1…5` | Same as above (Super = Windows key) |
| `Alt + Tab` | Cycle to next window on the current desktop |
| `Alt + Shift + Tab` | Cycle to previous window |
| `Super + Tab` | Show the combined window list across all desktops (navigate to a lost window) |

### Lock the screen

| Keys | Action |
|------|--------|
| `Super + L` | Lock the screen with `slock` |

### Respawn closed sessions

| Keys | Action |
|------|--------|
| `Super + T` | Launch a fullscreen xterm that re-attaches to the tmux session on desktop 1 (creates it if missing) |
| `Super + C` | Re-launch the Chromium / PVE UI session on desktop 2 (uses the same `--user-data-dir`, so cookies and login persist) |

### Close / panic-kill windows

| Keys | Action |
|------|--------|
| `Alt + F4` | Close the focused window (graceful WM_DELETE) |
| `Super + Shift + C` | Kill **every** Chromium process (panic close) |
| `Super + Shift + T` | Kill **every** xterm process (panic close) |

The autostart watchdog only exits Openbox when **all** of
chromium / xterm / virt-viewer are gone, so killing one app is safe — use
the matching `Super + T` / `Super + C` to bring it back.

`slock` blanks every output and waits for your **user** password. Type it
and press Enter to unlock (the screen stays black while you type — there is
no prompt). Root cannot unlock because the root account is locked.

## Configuration

Edit `group_vars/all.yml` to change:

- `workstation_github_user` — GitHub account whose public keys become
  `authorized_keys` for the new user.
- `workstation_user_groups` — supplementary groups for the new user.
- `workstation_apt_packages` — the apt package list.
- `tmux_repo`, `nvim_repo` — dotfile sources.
- `neovim_release`, `nerdfonts_version`, `nerdfonts_list`.
