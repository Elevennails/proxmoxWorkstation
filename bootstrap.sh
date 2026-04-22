#!/usr/bin/env bash
# Entry point for a fresh Proxmox VE install.
# Usage (on the PVE host, as root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Elevennails/proxmoxWorkstation/main/bootstrap.sh)"

set -euo pipefail

REPO_URL="https://github.com/Elevennails/proxmoxWorkstation.git"
CLONE_DIR="/opt/proxmoxWorkstation"
POST_INSTALL_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh"

if [[ $EUID -ne 0 ]]; then
  echo "This bootstrap must run as root." >&2
  exit 1
fi

echo "==> [1/4] Running Proxmox VE post-install helper (community-scripts)"
echo "    You'll be prompted via whiptail for a few choices."
bash -c "$(curl -fsSL "$POST_INSTALL_URL")"

echo "==> [2/4] Installing git and ansible"
apt-get update
apt-get install -y --no-install-recommends git ansible ca-certificates

echo "==> [3/4] Cloning $REPO_URL"
if [[ -d "$CLONE_DIR/.git" ]]; then
  git -C "$CLONE_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$CLONE_DIR"
fi

echo "==> [4/4] Running Ansible playbook"
cd "$CLONE_DIR"
ansible-playbook -i inventory.yml site.yml "$@"

cat <<'EOF'

============================================================
 Build complete.

 Next steps:
   1. Log out of root.
   2. Log in on tty1 as 'simon' (password was set during PVE install;
      if not, run 'passwd simon' as root first).
   3. Run 'startx' to launch openbox.
   4. PVE web UI: https://<host>:8006  (log in as simon@pam)
============================================================
EOF
