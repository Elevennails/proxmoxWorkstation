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
# Run a remote sudo command, feeding the password via stdin (-S flag)
# Usage: remote_sudo <host> <password> <command>
# ---------------------------------------------------------------------------
remote_sudo() {
    local host="$1"
    local pass="$2"
    local cmd="$3"
    echo "${pass}" | ssh ${SSH_OPTS} "${REMOTE_USER}@${host}" \
        "sudo -S -p '' bash -c '${cmd}'" 2>/dev/null
}

# Same but preserves stdin so we can pipe data into the remote command
# Usage: <data> | remote_sudo_pipe <host> <password> <command>
remote_sudo_pipe() {
    local host="$1"
    local pass="$2"
    local cmd="$3"
    # Write password to a temp fd so stdin remains free for the pipe
    ssh ${SSH_OPTS} "${REMOTE_USER}@${host}" \
        "echo '${pass}' | sudo -S -p '' bash -c '${cmd}'" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Prompt for passwords once upfront
# ---------------------------------------------------------------------------
collect_passwords() {
    echo ""
    # Local sudo password
    read -rsp "[sudo] Enter YOUR LOCAL sudo password: " LOCAL_SUDO_PASS
    echo ""

    # Validate local sudo works
    if ! echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' true 2>/dev/null; then
        echo ""
        error "Local sudo authentication failed. Check your password."
        exit 1
    fi
    success "Local sudo authenticated."
    echo ""

    # Remote sudo password (may be the same or different per environment)
    read -rsp "[sudo] Enter YOUR REMOTE sudo password (leave blank if same as local): " REMOTE_SUDO_PASS
    echo ""

    # If blank, use the same as local
    if [[ -z "${REMOTE_SUDO_PASS}" ]]; then
        REMOTE_SUDO_PASS="${LOCAL_SUDO_PASS}"
        info "Using local password for remote sudo."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Pre-flight: read the local public key
# ---------------------------------------------------------------------------
preflight() {
    command -v ssh &>/dev/null || { error "ssh not found."; exit 1; }

    if ! echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' test -f "${MIGRATE_KEY}" 2>/dev/null; then
        error "Public key not found at ${MIGRATE_KEY}"
        error "Have you run setup_migrate_user.sh on this node yet?"
        exit 1
    fi

    PUB_KEY=$(echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' cat "${MIGRATE_KEY}" 2>/dev/null)
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

    # Test basic SSH connectivity
    info "Testing SSH connection to ${target}..."
    if ! ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" "echo connected" &>/dev/null; then
        error "Cannot connect to ${target} — skipping."
        FAILED_HOSTS+=("${target}")
        return
    fi
    success "SSH connection OK"

    # Validate remote sudo works before proceeding
    info "Validating remote sudo on ${target}..."
    if ! echo "${REMOTE_SUDO_PASS}" | ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" \
        "sudo -S -p '' true" 2>/dev/null; then
        error "Remote sudo authentication failed on ${target} — skipping."
        FAILED_HOSTS+=("${target}")
        return
    fi
    success "Remote sudo authenticated"

    # Ensure .ssh dir and authorized_keys exist with correct permissions
    info "Preparing ${REMOTE_SSH_DIR} on ${target}..."
    remote_sudo "${target}" "${REMOTE_SUDO_PASS}" \
        "mkdir -p ${REMOTE_SSH_DIR} && \
         touch ${REMOTE_AUTHORIZED_KEYS} && \
         chmod 700 ${REMOTE_SSH_DIR} && \
         chmod 600 ${REMOTE_AUTHORIZED_KEYS} && \
         chown -R ${MIGRATE_USER}:${MIGRATE_USER} ${REMOTE_SSH_DIR}"
    success "Remote .ssh directory ready"

    # Check for duplicate key
    local key_fingerprint
    key_fingerprint=$(echo "${PUB_KEY}" | awk '{print $2}')

    info "Checking for duplicate key on ${target}..."
    if remote_sudo "${target}" "${REMOTE_SUDO_PASS}" \
        "grep -qF '${key_fingerprint}' ${REMOTE_AUTHORIZED_KEYS}" 2>/dev/null; then
        warn "Key already present on ${target} — skipping."
        SUCCESS_HOSTS+=("${target} (already present)")
        return
    fi

    # Append the public key — pipe it in alongside the sudo password
    info "Installing public key on ${target}..."
    ssh ${SSH_OPTS} "${REMOTE_USER}@${target}" \
        "echo '${REMOTE_SUDO_PASS}' | sudo -S -p '' tee -a ${REMOTE_AUTHORIZED_KEYS} > /dev/null" \
        <<< "${PUB_KEY}"
    success "Public key installed"

    # Verify it landed
    info "Verifying key on ${target}..."
    if remote_sudo "${target}" "${REMOTE_SUDO_PASS}" \
        "grep -qF '${key_fingerprint}' ${REMOTE_AUTHORIZED_KEYS}"; then
        success "Key verified in ${REMOTE_AUTHORIZED_KEYS} on ${target}"
    else
        error "Key verification failed on ${target}"
        FAILED_HOSTS+=("${target}")
        return
    fi

    # Test migrate user SSH login end-to-end
    info "Testing migrate user SSH login to ${target}..."
    if echo "${LOCAL_SUDO_PASS}" | sudo -S -p '' -u "${MIGRATE_USER}" \
        ssh ${SSH_OPTS} \
        -i "/home/${MIGRATE_USER}/.ssh/id_ed25519" \
        "${MIGRATE_USER}@${target}" "echo migrate-login-ok" &>/dev/null; then
        success "migrate@${target} SSH login confirmed ✓"
        SUCCESS_HOSTS+=("${target}")
    else
        warn "Key installed but migrate SSH login test inconclusive on ${target}"
        warn "Test manually: sudo -u migrate ssh migrate@${target}"
        SUCCESS_HOSTS+=("${target} (key installed — verify login manually)")
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
        echo "  For failed hosts, retry or copy manually:"
        echo "  sudo cat ${MIGRATE_KEY} | ssh ${REMOTE_USER}@<host> \\"
        echo "    \"sudo tee -a ${REMOTE_AUTHORIZED_KEYS} > /dev/null\""
    fi

    echo ""
    echo "  To verify a connection manually:"
    echo "  sudo -u ${MIGRATE_USER} ssh ${MIGRATE_USER}@<target>"
    echo ""
    echo "=============================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    [[ $# -gt 0 ]] || print_usage

    REMOTE_USER="${SUDO_USER:-$USER}"

    SUCCESS_HOSTS=()
    FAILED_HOSTS=()

    echo ""
    echo "======================================================"
    echo "  distribute_migrate_key.sh"
    echo "  SSH account : ${REMOTE_USER}"
    echo "  Targets     : $*"
    echo "======================================================"

    collect_passwords
    preflight

    for target in "$@"; do
        distribute_to_host "${target}"
    done

    LOCAL_SUDO_PASS=""
    REMOTE_SUDO_PASS=""
    unset LOCAL_SUDO_PASS
    unset REMOTE_SUDO_PASS

    print_summary
}

main "$@"
