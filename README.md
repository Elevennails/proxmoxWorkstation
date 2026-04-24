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
   the Openbox `rc.xml` / `autostart` that define the three-desktop layout.
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

Openbox is configured with **three** desktops, each dedicated to one task:

| Desktop | Contents |
|---------|----------|
| 1 | Fullscreen xterm running `tmux` |
| 2 | Chromium, fullscreen, pointed at `https://127.0.0.1:8006` (PVE web UI) |
| 3 | `virt-viewer` / `remote-viewer` sessions (guest consoles) |

The Openbox `autostart` launches desktops 1 and 2 on login; virt-viewer
windows are routed to desktop 3 automatically via an `application` rule in
`rc.xml`. When Chromium, xterm, and all viewer processes have exited,
Openbox exits and you return to the login prompt.

## Key bindings

Defined in `roles/desktop/files/rc.xml`.

### Switch desktop / terminal

| Keys | Action |
|------|--------|
| `Ctrl + Alt + 1` | Go to desktop 1 (tmux) |
| `Ctrl + Alt + 2` | Go to desktop 2 (Chromium / PVE UI) |
| `Ctrl + Alt + 3` | Go to desktop 3 (virt-viewer) |
| `Super + 1` / `Super + 2` / `Super + 3` | Same as above (Super = Windows key) |
| `Alt + Tab` | Cycle to next window |
| `Alt + Shift + Tab` | Cycle to previous window |

### Lock the screen

| Keys | Action |
|------|--------|
| `Super + L` | Lock the screen with `slock` |

### Re-open the tmux terminal

| Keys | Action |
|------|--------|
| `Super + T` | Launch a fullscreen xterm that re-attaches to the tmux session on desktop 1 (creates it if missing) |

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
