#!/bin/bash
# =============================================================================
# setup_migrate_user.sh
# Creates and configures the 'migrate' service account on a Proxmox VE node.
#
# Purpose:
#   The 'migrate' user is a system-level SSH service account used to perform
#   manual offline VM migrations between Proxmox nodes. It authenticates
#   exclusively via SSH key (no password login), and holds the Proxmox
#   permissions required to manage disks and create/restore VMs.
#
# Run this script on EVERY Proxmox node in your cluster.
# Each node generates its own unique SSH key pair for this account.
#
# Usage:
#   chmod +x setup_migrate_user.sh
#   sudo ./setup_migrate_user.sh
#
# After running on all nodes, exchange public keys manually — see the
# "Key Exchange" section printed at the end of this script.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MIGRATE_USER="migrate"
MIGRATE_GROUP="migrate"
MIGRATE_HOME="/home/${MIGRATE_USER}"
MIGRATE_SHELL="/bin/bash"
SSH_KEY_TYPE="ed25519"
SSH_KEY_COMMENT="${MIGRATE_USER}@$(hostname -f)"

# Proxmox role and permission settings
PVE_ROLE="MigrateRole"
PVE_USER="${MIGRATE_USER}@pam"   # PAM = local Linux user
PVE_PATH="/"                      # Grant at root so it applies to all nodes/storage

# Disk groups the migrate user needs access to
DISK_GROUPS=("disk" "cdrom" "tape" "kvm")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
    [[ "${EUID}" -eq 0 ]] || error "This script must be run as root (sudo)."
}

require_proxmox() {
    command -v pveum &>/dev/null || error "pveum not found — is this a Proxmox VE node?"
    command -v pvesm &>/dev/null || error "pvesm not found — is this a Proxmox VE node?"
}

# ---------------------------------------------------------------------------
# 1. Create the Linux system account
# ---------------------------------------------------------------------------
create_linux_user() {
    info "Creating Linux user '${MIGRATE_USER}'..."

    if id "${MIGRATE_USER}" &>/dev/null; then
        warn "User '${MIGRATE_USER}' already exists — skipping creation."
    else
        # Create group first (idempotent)
        if ! getent group "${MIGRATE_GROUP}" &>/dev/null; then
            groupadd --system "${MIGRATE_GROUP}"
            success "Group '${MIGRATE_GROUP}' created."
        fi

        useradd \
            --create-home \
            --home-dir   "${MIGRATE_HOME}" \
            --shell      "${MIGRATE_SHELL}" \
            --gid        "${MIGRATE_GROUP}" \
            --comment    "VM migration service account" \
            "${MIGRATE_USER}"

        success "Linux user '${MIGRATE_USER}' created."
    fi

    # Lock password — key-only authentication
    passwd --lock "${MIGRATE_USER}" &>/dev/null
    success "Password login locked for '${MIGRATE_USER}'."
}

# ---------------------------------------------------------------------------
# 2. Add user to required system groups (disk management)
# ---------------------------------------------------------------------------
add_to_groups() {
    info "Adding '${MIGRATE_USER}' to required system groups..."

    for grp in "${DISK_GROUPS[@]}"; do
        if getent group "${grp}" &>/dev/null; then
            usermod -aG "${grp}" "${MIGRATE_USER}"
            success "Added to group: ${grp}"
        else
            warn "Group '${grp}' not found on this system — skipping."
        fi
    done
}

# ---------------------------------------------------------------------------
# 3. Configure sudo for storage/VM operations (without full root)
# ---------------------------------------------------------------------------
configure_sudo() {
    info "Configuring sudoers for '${MIGRATE_USER}'..."

    local sudoers_file="/etc/sudoers.d/migrate"

    cat > "${sudoers_file}" << 'EOF'
# Sudoers rules for the 'migrate' VM migration service account.
# Allows disk and VM management without a full root shell.
Defaults:migrate !requiretty

# Disk / storage management
migrate ALL=(root) NOPASSWD: /sbin/fdisk, \
                              /sbin/parted, \
                              /sbin/lvcreate, \
                              /sbin/lvremove, \
                              /sbin/lvresize, \
                              /sbin/lvdisplay, \
                              /sbin/vgdisplay, \
                              /sbin/pvdisplay, \
                              /usr/sbin/lvm, \
                              /sbin/mkfs, \
                              /bin/mount, \
                              /bin/umount, \
                              /usr/bin/rsync, \
                              /bin/cp, \
                              /bin/mv, \
                              /bin/dd, \
                              /bin/mkdir, \
                              /usr/bin/sed, \
                              /sbin/blockdev

# ZFS management
migrate ALL=(root) NOPASSWD: /sbin/zfs, \
                              /sbin/zpool


# Proxmox VM / restore tooling
migrate ALL=(root) NOPASSWD: /usr/bin/qmrestore, \
                              /usr/bin/qm, \
                              /usr/bin/vzdump, \
                              /usr/sbin/qemu-img, \
                              /usr/bin/pvesm, \
                              /usr/bin/pct

# SSH agent forwarding helpers
migrate ALL=(root) NOPASSWD: /usr/bin/ssh-keyscan, \
migrate ALL=(root) NOPASSWD: /usr/bin/ssh, \
migrate ALL=(root) NOPASSWD: /usr/bin/scp, \
migrate ALL=(root) NOPASSWD: /user/bin/rsync
EOF

    chmod 440 "${sudoers_file}"
    visudo -cf "${sudoers_file}" || error "Sudoers syntax check failed — review ${sudoers_file}"
    success "Sudoers file written to ${sudoers_file}"
}

# ---------------------------------------------------------------------------
# 4. Generate SSH key pair (unique per node)
# ---------------------------------------------------------------------------
generate_ssh_key() {
    info "Setting up SSH key pair for '${MIGRATE_USER}'..."

    local ssh_dir="${MIGRATE_HOME}/.ssh"
    local key_file="${ssh_dir}/id_${SSH_KEY_TYPE}"

    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    chown "${MIGRATE_USER}:${MIGRATE_GROUP}" "${ssh_dir}"

    if [[ -f "${key_file}" ]]; then
        warn "SSH key already exists at ${key_file} — not regenerating."
        warn "Delete it manually and re-run if you need a fresh key."
    else
        # Generate with no passphrase (service account / automated use)
        sudo -u "${MIGRATE_USER}" ssh-keygen \
            -t "${SSH_KEY_TYPE}" \
            -C "${SSH_KEY_COMMENT}" \
            -f "${key_file}" \
            -N ""
        success "SSH key pair generated: ${key_file}"
    fi

    # Ensure authorized_keys exists with correct permissions
    touch "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${MIGRATE_USER}:${MIGRATE_GROUP}" "${ssh_dir}"
}

# ---------------------------------------------------------------------------
# 5. Harden SSH for this account via sshd_config drop-in
# ---------------------------------------------------------------------------
configure_sshd() {
    info "Applying SSH hardening for '${MIGRATE_USER}'..."

    local sshd_dropin="/etc/ssh/sshd_config.d/migrate.conf"

    # sshd_config.d drop-ins require OpenSSH >= 8.2; Proxmox 7/8 ships >= 8.4
    cat > "${sshd_dropin}" << EOF
# SSH restrictions for the 'migrate' service account.
# Key-based auth only; no passwords, no interactive shell forwarding.
Match User ${MIGRATE_USER}
    PasswordAuthentication  no
    PubkeyAuthentication    yes
    PermitEmptyPasswords    no
    X11Forwarding           no
    AllowTcpForwarding      yes
    PermitTTY               yes
    ForceCommand            none
EOF

    chmod 644 "${sshd_dropin}"

    # Validate and reload sshd
    if sshd -t; then
        systemctl reload sshd
        success "sshd configuration updated and reloaded."
    else
        error "sshd config test failed — review ${sshd_dropin}"
    fi
}

# ---------------------------------------------------------------------------
# 6. Create the Proxmox RBAC role and assign it to the PAM user
# ---------------------------------------------------------------------------
configure_proxmox_rbac() {
    info "Configuring Proxmox RBAC role '${PVE_ROLE}'..."

    # Create or update the custom role with the required privileges
    # VM.* covers creation, config, migration, snapshots, etc.
    # Datastore.* covers reading/writing storage for backups and disk images
    pveum role add "${PVE_ROLE}" \
        --privs "VM.Allocate,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,\
VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Console,VM.Migrate,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback,\
VM.Audit,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,\
Datastore.Audit,SDN.Use,Sys.Audit" \
        2>/dev/null \
    || pveum role modify "${PVE_ROLE}" \
        --privs "VM.Allocate,VM.Clone,VM.Config.CDROM,VM.Config.CPU,VM.Config.Cloudinit,\
VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,\
VM.Console,VM.Migrate,VM.PowerMgmt,VM.Snapshot,VM.Snapshot.Rollback,\
VM.Audit,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,\
Datastore.Audit,SDN.Use,Sys.Audit"

    success "Proxmox role '${PVE_ROLE}' configured."

    info "Ensuring PAM user '${PVE_USER}' exists in Proxmox..."
    # pveum user add is idempotent with || true
    pveum user add "${PVE_USER}" \
        --comment "VM migration service account" \
        --enable 1 \
        2>/dev/null || true

    info "Assigning role '${PVE_ROLE}' to '${PVE_USER}' on path '${PVE_PATH}'..."
    pveum aclmod "${PVE_PATH}" \
        --users "${PVE_USER}" \
        --roles "${PVE_ROLE}"

    success "Proxmox RBAC: ${PVE_USER} → ${PVE_ROLE} on ${PVE_PATH}"
}

# ---------------------------------------------------------------------------
# 7. Print post-install instructions
# ---------------------------------------------------------------------------
print_summary() {
    local pub_key_file="${MIGRATE_HOME}/.ssh/id_${SSH_KEY_TYPE}.pub"
    local pub_key=""
    [[ -f "${pub_key_file}" ]] && pub_key=$(cat "${pub_key_file}")

    echo ""
    echo "=============================================================="
    echo "  setup_migrate_user.sh — COMPLETE on $(hostname -f)"
    echo "=============================================================="
    echo ""
    echo "  Linux user : ${MIGRATE_USER}  (password login LOCKED)"
    echo "  Home dir   : ${MIGRATE_HOME}"
    echo "  SSH key    : ${MIGRATE_HOME}/.ssh/id_${SSH_KEY_TYPE}"
    echo "  Proxmox    : ${PVE_USER} with role ${PVE_ROLE}"
    echo ""
    echo "  Public key for THIS node:"
    echo ""
    echo "  ${pub_key}"
    echo ""
    echo "--------------------------------------------------------------"
    echo "  KEY EXCHANGE — do this after running on ALL nodes:"
    echo "--------------------------------------------------------------"
    echo ""
    echo "  On each TARGET node, append the SOURCE node's public key to:"
    echo "  ${MIGRATE_HOME}/.ssh/authorized_keys"
    echo ""
    echo "  Quick command (run as root on target node):"
    echo ""
    echo "  echo '<source-node-public-key>' \\"
    echo "    >> ${MIGRATE_HOME}/.ssh/authorized_keys"
    echo ""
    echo "  Then test from the source node:"
    echo ""
    echo "  sudo -u ${MIGRATE_USER} ssh ${MIGRATE_USER}@<target-node-ip>"
    echo ""
    echo "  If prompted to accept a host key, type 'yes'."
    echo "  You should NOT be asked for a password."
    echo ""
    echo "--------------------------------------------------------------"
    echo "  MIGRATION WORKFLOW (offline VM)"
    echo "--------------------------------------------------------------"
    echo ""
    echo "  1. On source node — stop the VM:"
    echo "     sudo qm stop <vmid>"
    echo ""
    echo "  2. On source node — copy disk image to target:"
    echo "     sudo rsync -avz --progress \\"
    echo "       /var/lib/vz/images/<vmid>/<disk>.qcow2 \\"
    echo "       ${MIGRATE_USER}@<target>:/var/lib/vz/images/<vmid>/"
    echo ""
    echo "  3. On source node — copy VM config to target:"
    echo "     sudo rsync -avz \\"
    echo "       /etc/pve/nodes/$(hostname)/qemu-server/<vmid>.conf \\"
    echo "       ${MIGRATE_USER}@<target>:/etc/pve/nodes/<target-hostname>/qemu-server/"
    echo ""
    echo "  4. On target node — start the VM:"
    echo "     sudo qm start <vmid>"
    echo ""
    echo "=============================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    require_root
    require_proxmox

    echo ""
    echo "======================================================"
    echo "  Proxmox 'migrate' user setup — $(hostname -f)"
    echo "======================================================"
    echo ""

    create_linux_user
    add_to_groups
    configure_sudo
    generate_ssh_key
    configure_sshd
    configure_proxmox_rbac
    print_summary
}

main "$@"
