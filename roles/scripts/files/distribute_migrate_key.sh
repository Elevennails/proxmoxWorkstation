#!/bin/bash
# =============================================================================
# distribute_migrate_key.sh
# Distributes the local 'migrate' user's public SSH key to one or more remote
# Proxmox nodes, using your personal sudo-enabled account on both ends.
#
# Prerequisites:
#   - The 'migrate' user and its SSH key must already exist locally
#     (run setup_migrate_user.sh first)
#   - Your user account must have sudo rights on both local and remote nodes
#   - Your user account must be able to SSH into each remote node
#
# Usage:
#   chmod +x distribute_migrate_key.sh
#   ./distribute_migrate_key.sh <target1> [target2] [target3] ...
#
# Examples:
#   ./distribute_migrate_key.sh 192.168.1.101
#   ./distribute_migrate_key.sh pve-node2 pve-node3 pve-node4
#   ./distribute_migrate_key.sh 192.168.1.101 192.168.1.102 192.168.1.103
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MIGRATE_USER="migrate"
MIGRATE_KEY="/home/${MIGRATE_USER}/.ssh/id_ed25519.pub"
REMOTE_AUTHORIZED_KEYS="/home/${MIGRATE_USER}/.ssh/authorized_keys"
REMOTE_SSH_DIR="/home/${MIGRATE_USER}/.ssh"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
error()   { echo "[ERROR] $*" >&2; }

print_usage() {
    echo "Usage: $0 <target-host> [target-host2] ..."
    echo ""
    echo "  target-host  Hostname or IP address of a remote Proxmox node"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.101"
    echo "  $0 pve-node2 pve-node3"
    exit 1
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
    [[ $# -gt 0 ]] || print_usage

    # Check ssh is available
    command -v ssh &>/dev/null || { error "ssh not found."; exit 1; }

    # Check the migrate key exists — sudo needed as it's in migrate's home
    if ! sudo test -f "${MIGRATE_KEY}"; then
        error "Public key not found at ${MIGRATE_KEY}"
        error "Have you run setup_migrate_user.sh on this node yet?"
        exit 1
    fi

    # Read the public key once (single sudo prompt for local access)
    PUB_KEY=$(sudo cat "${MIGRATE_KEY}")
    [[ -n "${PUB_KEY}" ]] || { error "Public key file is empty."; exit 1; }

    success "Local public key read from ${MIGRATE_KEY}"
}

# ---------------------------------------------------------------------------
# Distribute key to a single remote host
# ---------------------------------------------------------------------------
distribute_to_host() {
    local target="$1"

    echo ""
    echo "--------------------------------------------------------------"
    info "Target: ${target}"
    echo "--------------------------------------------------------------"

    # Test SSH connectivity first
    info "Testing SSH connection to ${target}..."
    if ! ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" "echo connected" &>/dev/null; then
        error "Cannot connect to ${target} — skipping."
        FAILED_HOSTS+=("${target}")
        return
    fi
    success "SSH connection OK"

    # Ensure the .ssh directory exists on the remote with correct permissions
    info "Ensuring ${REMOTE_SSH_DIR} exists on ${target}..."
    ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" \
        "sudo mkdir -p ${REMOTE_SSH_DIR} && \
         sudo touch ${REMOTE_AUTHORIZED_KEYS} && \
         sudo chmod 700 ${REMOTE_SSH_DIR} && \
         sudo chmod 600 ${REMOTE_AUTHORIZED_KEYS} && \
         sudo chown -R ${MIGRATE_USER}:${MIGRATE_USER} ${REMOTE_SSH_DIR}"
    success "Remote .ssh directory ready"

    # Check if key is already present to avoid duplicates
    info "Checking for duplicate key..."
    local key_fingerprint
    key_fingerprint=$(echo "${PUB_KEY}" | awk '{print $2}')

    if ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" \
        "sudo grep -qF '${key_fingerprint}' ${REMOTE_AUTHORIZED_KEYS} 2>/dev/null"; then
        warn "Key already present in ${REMOTE_AUTHORIZED_KEYS} on ${target} — skipping."
        SUCCESS_HOSTS+=("${target} (already present)")
        return
    fi

    # Append the public key using sudo tee on the remote
    info "Installing public key on ${target}..."
    echo "${PUB_KEY}" | ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" \
        "sudo tee -a ${REMOTE_AUTHORIZED_KEYS} > /dev/null"
    success "Public key installed on ${target}"

    # Verify it landed
    info "Verifying key on ${target}..."
    if ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" \
        "sudo grep -qF '${key_fingerprint}' ${REMOTE_AUTHORIZED_KEYS}"; then
        success "Key verified in ${REMOTE_AUTHORIZED_KEYS} on ${target}"
    else
        error "Key verification failed on ${target}"
        FAILED_HOSTS+=("${target}")
        return
    fi

    # Test the migrate user can actually SSH using the key
    info "Testing migrate user SSH login to ${target}..."
    if sudo -u "${MIGRATE_USER}" ssh ${SSH_OPTS} \
        -i "/home/${MIGRATE_USER}/.ssh/id_ed25519" \
        "${MIGRATE_USER}@${target}" "echo migrate-login-ok" &>/dev/null; then
        success "migrate@${target} SSH login confirmed"
        SUCCESS_HOSTS+=("${target}")
    else
        warn "Key installed but migrate SSH login test failed on ${target}"
        warn "This may be normal if the remote sshd hasn't reloaded yet."
        warn "Test manually: sudo -u migrate ssh migrate@${target}"
        SUCCESS_HOSTS+=("${target} (key installed, login test inconclusive)")
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "=============================================================="
    echo "  distribute_migrate_key.sh — SUMMARY"
    echo "=============================================================="

    if [[ ${#SUCCESS_HOSTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Succeeded:"
        for h in "${SUCCESS_HOSTS[@]}"; do
            echo "    ✓  ${h}"
        done
    fi

    if [[ ${#FAILED_HOSTS[@]} -gt 0 ]]; then
        echo ""
        echo "  Failed:"
        for h in "${FAILED_HOSTS[@]}"; do
            echo "    ✗  ${h}"
        done
        echo ""
        echo "  For failed hosts, copy the key manually:"
        echo ""
        echo "  sudo cat ${MIGRATE_KEY} | ssh ${REMOTE_USER}@<host> \\"
        echo "    \"sudo tee -a ${REMOTE_AUTHORIZED_KEYS} > /dev/null\""
    fi

    echo ""
    echo "  To verify any connection manually:"
    echo "  sudo -u ${MIGRATE_USER} ssh ${MIGRATE_USER}@<target>"
    echo ""
    echo "=============================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    [[ $# -gt 0 ]] || print_usage

    # Determine the remote username — default to current user
    REMOTE_USER="${SUDO_USER:-$USER}"
    info "Using SSH account: ${REMOTE_USER}"

    # Tracking arrays
    SUCCESS_HOSTS=()
    FAILED_HOSTS=()

    # Single sudo prompt for the local key read (preflight)
    echo ""
    echo "======================================================"
    echo "  distribute_migrate_key.sh"
    echo "  Targets: $*"
    echo "======================================================"
    echo ""
    info "You may be prompted for your local sudo password now,"
    info "then your remote sudo password for each target node."
    echo ""

    preflight "$@"

    for target in "$@"; do
        distribute_to_host "${target}"
    done

    print_summary
}

main "$@"
